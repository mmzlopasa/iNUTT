import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'core/downloads.dart';
import 'core/extras.dart';
import 'core/feed_engine.dart';
import 'core/image_cache.dart';
import 'core/models.dart';
import 'core/security.dart';
import 'core/stores.dart';
import 'core/sync.dart';
import 'core/vault.dart';
import 'screens/home.dart';
import 'screens/library.dart';
import 'screens/lock.dart';
import 'screens/onboarding.dart';
import 'screens/reels.dart';
import 'screens/search.dart';
import 'screens/sites.dart';
import 'screens/viewer.dart';
import 'ui/media_widgets.dart';
import 'ui/router.dart';
import 'ui/theme.dart';

Future<void> main(List<String> args) async {
  // A failure while starting must never leave the app without a window: every step is guarded,
  // anything that goes wrong is written to startup.log, and a broken start shows what failed.
  runZonedGuarded(() => _start(args), (e, s) => _log('uncaught', e, s));
}

final List<String> _startupErrors = [];

void _log(String step, Object e, [StackTrace? s]) {
  final line = '${DateTime.now().toIso8601String()} $step: $e\n${s ?? ''}\n';
  debugPrint(line);
  try {
    File('${Disk.dir.path}${Platform.pathSeparator}startup.log').writeAsStringSync(line, mode: FileMode.append);
  } catch (_) {}
}

/// Runs one start-up step; a step that fails or hangs is logged and skipped instead of stopping the app.
Future<void> _step(String name, FutureOr<void> Function() run) async {
  try {
    await Future.sync(run).timeout(const Duration(seconds: 8));
  } catch (e, s) {
    _startupErrors.add('$name: $e');
    _log(name, e, s);
  }
}

Future<void> _start(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    MediaKit.ensureInitialized();
    await Disk.init();
  } catch (e, s) {
    _log('core', e, s);
    runApp(StartupErrorApp(message: '$e'));
    return;
  }
  // Windows "Open in new window": a second copy of the app that only shows the viewer.
  List<MediaItem>? windowItems;
  final w = args.indexOf('--window');
  if (Platform.isWindows && w >= 0 && w + 1 < args.length) {
    try {
      final f = File(args[w + 1]);
      windowItems = (jsonDecode(f.readAsStringSync()) as List).map((e) => MediaItem.fromJson(e as Map<String, dynamic>)).toList();
      f.deleteSync();
      Disk.readOnly = true;
    } catch (_) {}
  }
  await _step('settings', AppSettings.shared.load);
  await _step('images', ImagePipeline.shared.init);
  // Room for a few screens of decoded thumbnails, so scrolling back never decodes again.
  PaintingBinding.instance.imageCache
    ..maximumSize = 1500
    ..maximumSizeBytes = 280 << 20;
  await _step('sites', SiteStore.shared.load);
  await _step('library', Library.shared.load);
  await _step('collections', CollectionStore.shared.load);
  await _step('vault', Vault.shared.load);
  await _step('resume', ResumeStore.shared.load);
  await _step('watch later', WatchLater.shared.load);
  await _step('taste', Taste.shared.load);
  await _step('sync', SyncManager.shared.load);
  await _step('cookies', CookieJar.load);
  await _step('offline', OfflineStore.shared.load);
  if (Platform.isWindows) await _step('window', windowManager.ensureInitialized);
  AppSettings.shared.blocklistVersion.addListener(FeedEngine.shared.filtersChanged);
  await _step('feeds', FeedEngine.shared.load);
  await _step('lock', LockManager.shared.load);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  WindowInbox.start();
  openInNewWindow = WindowViewer.open;
  final items = windowItems;
  if (items != null) {
    await _step('window title', () async {
      await windowManager.setTitle('iNUTT');
      await windowManager.setSize(const Size(900, 1000));
    });
  }
  runApp(INuttApp(windowItems: items));
}

/// Shown only when the app could not even reach its storage, so a broken start is never a silent one.
class StartupErrorApp extends StatelessWidget {
  final String message;
  const StartupErrorApp({super.key, required this.message});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFF0D0F14),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: SelectableText(
            'iNUTT could not start.\n\n$message',
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ),
    ),
  );
}

class INuttApp extends StatelessWidget {
  final List<MediaItem>? windowItems;
  const INuttApp({super.key, this.windowItems});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'iNUTT',
    debugShowCheckedModeBanner: false,
    theme: T.theme(),
    navigatorKey: AppRouter.shared.rootKey,
    scrollBehavior: const _Scroll(),
    // Lock, privacy cover, onboarding and toasts sit above every route, the viewer included.
    builder: (context, child) => AppShell(child: child ?? const SizedBox.shrink()),
    home: windowItems == null ? const RootView() : WindowViewer(items: windowItems!),
  );
}

/// Lets mouse and trackpad drag lists on Windows, like touch.
class _Scroll extends MaterialScrollBehavior {
  const _Scroll();
  @override
  Set<PointerDeviceKind> get dragDevices => PointerDeviceKind.values.toSet();
}

class RootView extends StatefulWidget {
  const RootView({super.key});

  @override
  State<RootView> createState() => _RootViewState();
}

class _RootViewState extends State<RootView> {
  @override
  void initState() {
    super.initState();
    if (FeedEngine.shared.isStale) unawaited(FeedEngine.shared.refreshAll());
    DownloadManager.shared.resumeQueue();
    unawaited(NewContentWatcher.start());
    SyncManager.shared.syncIfNeeded();
  }

  Widget _tab(AppTab t, Widget root) => Navigator(
    key: AppRouter.shared.keys[t],
    onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => root),
  );

  Future<void> _back() async {
    final r = AppRouter.shared;
    final nav = r.keys[r.tab]?.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
    } else if (r.tab != AppTab.home) {
      r.select(AppTab.home);
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: ListenableBuilder(
      listenable: AppRouter.shared,
      builder: (context, _) {
        final router = AppRouter.shared;
        return Stack(
          children: [
            const Positioned.fill(child: NightSky()),
            IndexedStack(
              index: router.tab.index,
              children: [
                _tab(AppTab.home, const HomeView()),
                _tab(AppTab.reels, const ReelsView()),
                _tab(AppTab.sites, const SitesView()),
                _tab(AppTab.search, const SearchView()),
                _tab(AppTab.favorites, const FavoritesView()),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(top: false, child: FloatingTabBar(router: router)),
            ),
          ],
        );
      },
    ),
  );
}

/// Everything that must cover the whole app, above the navigator and any open viewer or sheet.
class AppShell extends StatefulWidget {
  final Widget child;
  const AppShell({super.key, required this.child});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  AppLifecycleState _life = AppLifecycleState.resumed;
  StreamSubscription<UserAccelerometerEvent>? _shake;
  DateTime _lastShake = DateTime(2000);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Shake to lock: phones only.
    if (Platform.isAndroid) {
      _shake = userAccelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen((e) {
        if (!AppSettings.shared.shakeToLock) return;
        final g = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
        final now = DateTime.now();
        if (g < 22 || now.difference(_lastShake) < const Duration(seconds: 2)) return;
        _lastShake = now;
        if (!LockManager.shared.hasLock || LockManager.shared.isLocked) return;
        HapticFeedback.heavyImpact();
        AppRouter.shared.rootKey.currentState?.popUntil((r) => r.isFirst);
        LockManager.shared.lockNow();
      }, onError: (_) {});
    }
    if (Platform.isWindows) HardwareKeyboard.instance.addHandler(_quickHide);
  }

  /// Windows: one key closes what is open, locks and minimizes the app.
  bool _quickHide(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey.keyLabel != AppSettings.shared.hideKey) return false;
    AppRouter.shared.rootKey.currentState?.popUntil((r) => r.isFirst);
    if (LockManager.shared.hasLock) LockManager.shared.lockNow();
    unawaited(windowManager.minimize());
    return true;
  }

  @override
  void dispose() {
    _shake?.cancel();
    if (Platform.isWindows) HardwareKeyboard.instance.removeHandler(_quickHide);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _life = state);
    appResumed.value = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      LockManager.shared.lockIfNeeded();
      Vault.shared.closeOpenFiles();
      FeedEngine.shared.saveNow();
      // Changes made just now reach your other devices.
      if (state == AppLifecycleState.paused) unawaited(SyncManager.shared.sync());
    } else if (state == AppLifecycleState.resumed) {
      if (FeedEngine.shared.isStale) unawaited(FeedEngine.shared.refreshAll());
      OfflineStore.shared.sync();
      SyncManager.shared.syncIfNeeded();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([LockManager.shared, DownloadManager.shared, AppSettings.shared]),
    builder: (context, _) {
      final toast = DownloadManager.shared.toast;
      final locked = LockManager.shared.isLocked;
      return Stack(
        children: [
          Positioned.fill(child: widget.child),
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            left: 16,
            right: 16,
            child: IgnorePointer(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: toast == null
                    ? const SizedBox.shrink()
                    : Center(
                        key: ValueKey(toast.id),
                        child: ToastView(toast: toast),
                      ),
              ),
            ),
          ),
          if (AppSettings.shared.hideInSwitcher && _life != AppLifecycleState.resumed && !locked)
            const Positioned.fill(child: _PrivacyCover()),
          if (!AppSettings.shared.onboarded) Positioned.fill(child: OnboardingView(onDone: () => AppSettings.shared.onboarded = true)),
          if (!locked && LockManager.shared.decoy) const Positioned.fill(child: _DecoyView()),
          if (locked) const Positioned.fill(child: LockView()),
        ],
      );
    },
  );
}

/// What the decoy PIN opens: iNUTT as if it had never been set up.
class _DecoyView extends StatefulWidget {
  const _DecoyView();
  @override
  State<_DecoyView> createState() => _DecoyViewState();
}

class _DecoyViewState extends State<_DecoyView> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Stack(
      children: [
        const Positioned.fill(child: NightSky()),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Wordmark(size: 28),
                    Spacer(),
                    Icon(Icons.settings_rounded, color: T.ink),
                  ],
                ),
                const SizedBox(height: 24),
                _tab == 0
                    ? const EmptyState(
                        icon: Icons.auto_awesome_rounded,
                        title: 'Welcome to iNUTT',
                        message: 'Add sites with images, GIFs and videos to see them here.',
                      )
                    : const EmptyState(
                        icon: Icons.favorite_border_rounded,
                        title: 'No favorites yet',
                        message: 'Tap the heart in the viewer or long-press a card.',
                      ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 14,
          right: 14,
          bottom: MediaQuery.paddingOf(context).bottom + 6,
          child: Frosted(
            radius: 26,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  for (final (i, icon) in [(0, Icons.home_rounded), (1, Icons.favorite_rounded)])
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _tab = i),
                        child: Container(
                          height: 54,
                          decoration: BoxDecoration(gradient: _tab == i ? T.goldGradient : null, borderRadius: BorderRadius.circular(20)),
                          child: Icon(icon, color: _tab == i ? T.onGold : T.muted),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _PrivacyCover extends StatelessWidget {
  const _PrivacyCover();
  @override
  Widget build(BuildContext context) => const Stack(
    children: [
      Positioned.fill(child: NightSky()),
      Center(child: Wordmark(size: 34)),
    ],
  );
}

class FloatingTabBar extends StatelessWidget {
  final AppRouter router;
  const FloatingTabBar({super.key, required this.router});

  /// Long-press (or right-click) on Home: jump straight to Images, Videos or GIFs.
  Future<void> _homeMenu(BuildContext ctx) async {
    HapticFeedback.mediumImpact();
    final box = ctx.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    const height = 4 * 48.0 + 16;
    final rect = RelativeRect.fromLTRB(topLeft.dx, topLeft.dy - height - 8, overlay.size.width - topLeft.dx - box.size.width, 0);
    PopupMenuItem<int> item(int v, IconData icon, String title) => PopupMenuItem<int>(
      value: v,
      child: Row(
        children: [
          Icon(icon, size: 20, color: T.gold),
          const SizedBox(width: 12),
          Text(title, style: T.text(15, color: T.ink)),
        ],
      ),
    );
    final picked = await showMenu<int>(
      context: ctx,
      position: rect,
      color: T.navy,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: T.edge),
      ),
      items: [
        item(-1, Icons.auto_awesome_rounded, 'All'),
        item(MediaKind.image.index, Icons.photo_rounded, 'Images'),
        item(MediaKind.video.index, Icons.play_circle_rounded, 'Videos'),
        item(MediaKind.gif.index, Icons.gif_box_rounded, 'GIFs'),
      ],
    );
    if (picked == null) return;
    router.showHomeKind(picked < 0 ? null : MediaKind.values[picked]);
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.all(Radius.circular(26)),
            boxShadow: [BoxShadow(color: Color(0x8C000000), blurRadius: 24, offset: Offset(0, 12))],
          ),
          child: Frosted(
            radius: 26,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  for (final t in AppTab.values)
                    Expanded(
                      child: Builder(
                        builder: (ctx) {
                          void menu() => t == AppTab.home ? _homeMenu(ctx) : null;
                          return GestureDetector(
                            onSecondaryTap: menu,
                            child: Pressable(
                              onTap: () {
                                HapticFeedback.lightImpact();
                                router.select(t);
                              },
                              onLongPress: t == AppTab.home ? menu : null,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 280),
                                curve: Curves.easeOutCubic,
                                height: 54,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  gradient: router.tab == t ? T.goldGradient : null,
                                  boxShadow: router.tab == t
                                      ? [BoxShadow(color: T.gold.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 4))]
                                      : null,
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(t.icon, size: 21, color: router.tab == t ? T.onGold : T.muted),
                                    const SizedBox(height: 3),
                                    Text(
                                      t.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.fade,
                                      style: T.text(10, weight: FontWeight.w500, color: router.tab == t ? T.onGold : T.muted),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The only screen of a second window: the viewer, and closing it closes the window.
class WindowViewer extends StatefulWidget {
  final List<MediaItem> items;
  const WindowViewer({super.key, required this.items});

  /// Opens the items in a new window of their own, next to this one.
  static Future<void> open(List<MediaItem> items, int index) async {
    final ordered = [...items.skip(index), ...items.take(index)].take(200).toList();
    final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}inutt-window-${DateTime.now().microsecondsSinceEpoch}.json');
    await f.writeAsString(jsonEncode(ordered.map((e) => e.toJson()).toList()));
    await Process.start(Platform.resolvedExecutable, ['--window', f.path], mode: ProcessStartMode.detached);
  }

  @override
  State<WindowViewer> createState() => _WindowViewerState();
}

class _WindowViewerState extends State<WindowViewer> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await AppRouter.shared.rootKey.currentState?.push(
        PageRouteBuilder<void>(
          opaque: false,
          pageBuilder: (_, _, _) => MediaViewer(items: widget.items, startIndex: 0),
        ),
      );
      await windowManager.close();
      exit(0);
    });
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}
