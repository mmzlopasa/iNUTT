import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'core/downloads.dart';
import 'core/feed_engine.dart';
import 'core/image_cache.dart';
import 'core/security.dart';
import 'core/stores.dart';
import 'screens/home.dart';
import 'screens/library.dart';
import 'screens/lock.dart';
import 'screens/search.dart';
import 'screens/settings.dart';
import 'screens/sites.dart';
import 'ui/media_widgets.dart';
import 'ui/router.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Disk.init();
  await AppSettings.shared.load();
  await ImagePipeline.shared.init();
  SiteStore.shared.load();
  Library.shared.load();
  FeedEngine.shared.load();
  await LockManager.shared.load();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const INuttApp());
}

class INuttApp extends StatelessWidget {
  const INuttApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'iNUTT',
        debugShowCheckedModeBanner: false,
        theme: T.theme(),
        navigatorKey: AppRouter.shared.rootKey,
        scrollBehavior: const _Scroll(),
        home: const RootView(),
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

class _RootViewState extends State<RootView> with WidgetsBindingObserver {
  AppLifecycleState _life = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (FeedEngine.shared.isStale) unawaited(FeedEngine.shared.refreshAll());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _life = state);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      LockManager.shared.lockIfNeeded();
      FeedEngine.shared.saveNow();
    } else if (state == AppLifecycleState.resumed && FeedEngine.shared.isStale) {
      unawaited(FeedEngine.shared.refreshAll());
    }
  }

  Widget _tab(AppTab t, Widget root) => Navigator(
        key: AppRouter.shared.keys[t],
        onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => root),
      );

  void _back() {
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
          listenable: Listenable.merge([AppRouter.shared, LockManager.shared, DownloadManager.shared, AppSettings.shared]),
          builder: (context, _) {
            final router = AppRouter.shared;
            final toast = DownloadManager.shared.toast;
            return Stack(children: [
              const Positioned.fill(child: NightSky()),
              IndexedStack(index: router.tab.index, children: [
                _tab(AppTab.home, const HomeView()),
                _tab(AppTab.sites, const SitesView()),
                _tab(AppTab.search, const SearchView()),
                _tab(AppTab.favorites, const FavoritesView()),
                _tab(AppTab.settings, const SettingsView()),
              ]),
              Positioned(left: 0, right: 0, bottom: 0, child: SafeArea(top: false, child: FloatingTabBar(router: router))),
              Positioned(
                top: MediaQuery.paddingOf(context).top + 8,
                left: 16,
                right: 16,
                child: IgnorePointer(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: toast == null ? const SizedBox.shrink() : Center(key: ValueKey(toast.id), child: ToastView(toast: toast)),
                  ),
                ),
              ),
              if (AppSettings.shared.hideInSwitcher && _life != AppLifecycleState.resumed && !LockManager.shared.isLocked)
                const Positioned.fill(child: _PrivacyCover()),
              if (LockManager.shared.isLocked) const Positioned.fill(child: LockView()),
            ]);
          },
        ),
      );
}

class _PrivacyCover extends StatelessWidget {
  const _PrivacyCover();
  @override
  Widget build(BuildContext context) => const Stack(children: [Positioned.fill(child: NightSky()), Center(child: Wordmark(size: 34))]);
}

class FloatingTabBar extends StatelessWidget {
  final AppRouter router;
  const FloatingTabBar({super.key, required this.router});

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
                  child: Row(children: [
                    for (final t in AppTab.values)
                      Expanded(
                        child: Pressable(
                          onTap: () {
                            HapticFeedback.lightImpact();
                            router.select(t);
                          },
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
                            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                              Icon(t.icon, size: 21, color: router.tab == t ? T.onGold : T.muted),
                              const SizedBox(height: 3),
                              Text(t.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.fade,
                                  style: T.text(10, weight: FontWeight.w500, color: router.tab == t ? T.onGold : T.muted)),
                            ]),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}
