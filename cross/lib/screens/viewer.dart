import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:android_intent_plus/android_intent.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/downloads.dart';
import '../core/extras.dart';
import '../core/feed_engine.dart';
import '../core/image_cache.dart';
import '../core/models.dart';
import '../core/net.dart';
import '../core/stores.dart';
import '../ui/media_widgets.dart';
import '../ui/remote_image.dart';
import '../ui/router.dart';
import '../ui/theme.dart';
import 'forums.dart';

/// Full-screen pager for images, GIFs and videos. Swipe sideways to browse, drag down to close.
class MediaViewer extends StatefulWidget {
  final List<MediaItem> items;
  final int startIndex;
  const MediaViewer({super.key, required this.items, required this.startIndex});

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

/// Players of the pages on screen, so the viewer's controls can reach the active one.
final Map<String, Player> _players = {};

class _MediaViewerState extends State<MediaViewer> {
  bool _slideshow = false;
  Timer? _slideTimer;
  StreamSubscription<bool>? _ended;
  double _rate = 1;
  Duration? _loopA;
  Duration? _loopB;
  StreamSubscription<Duration>? _loopSub;
  late final PageController _page = PageController(initialPage: widget.startIndex);
  late int _index = widget.startIndex;
  bool _chrome = true;
  bool _zoomed = false;
  double _dragY = 0;
  final _focus = FocusNode();

  /// Pictures looked at here; they leave Watch later when the viewer closes.
  final Set<String> _looked = {};

  MediaItem get _current => widget.items[_index.clamp(0, widget.items.length - 1)];

  @override
  void initState() {
    super.initState();
    Library.shared.holdUpdates();
    Library.shared.record(_current);
    _markLooked();
    _preload(_index);
  }

  void _markLooked() {
    if (!_isVideo && WatchLater.shared.contains(_current)) _looked.add(_current.id);
  }

  /// More like this; opens on top, so closing it brings you back here.
  Future<void> _similar() async {
    final item = _current;
    final picked = await showModalBottomSheet<(List<MediaItem>, int)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: T.navy,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SimilarSheet(item: item),
    );
    if (picked == null || !mounted) return;
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        pageBuilder: (_, __, ___) => MediaViewer(items: picked.$1, startIndex: picked.$2),
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _slideTimer?.cancel();
    _ended?.cancel();
    _loopSub?.cancel();
    WatchLater.shared.removeIds(_looked);
    Library.shared.releaseUpdates();
    _page.dispose();
    _focus.dispose();
    super.dispose();
  }

  Player? get _player => _players[_current.id];
  bool get _isVideo => _current.kind == MediaKind.video || FeedEngine.shared.cachedResolution(_current)?.kind == MediaKind.video;

  void _seek(int seconds) {
    final p = _player;
    if (p == null) return;
    final t = p.state.position + Duration(seconds: seconds);
    p.seek(t < Duration.zero ? Duration.zero : t);
    HapticFeedback.selectionClick();
  }

  void _cycleRate() {
    const steps = [1.0, 1.25, 1.5, 2.0, 0.5, 0.75];
    final i = steps.indexOf(_rate);
    setState(() => _rate = steps[(i + 1) % steps.length]);
    _player?.setRate(_rate);
  }

  /// First tap marks A, second marks B and loops between them, third clears.
  void _tapLoop() {
    final p = _player;
    if (p == null) return;
    final now = p.state.position;
    if (_loopB != null || (_loopA != null && now <= _loopA! + const Duration(milliseconds: 300))) {
      _clearLoop();
    } else if (_loopA != null) {
      setState(() => _loopB = now);
      p.seek(_loopA!);
      _loopSub = p.stream.position.listen((pos) {
        if (_loopA != null && _loopB != null && pos >= _loopB!) p.seek(_loopA!);
      });
    } else {
      setState(() => _loopA = now);
    }
    HapticFeedback.selectionClick();
  }

  void _clearLoop() {
    _loopSub?.cancel();
    _loopSub = null;
    if (mounted) {
      setState(() {
        _loopA = null;
        _loopB = null;
      });
    }
  }

  /// Opens the video in another app: VLC, MX Player, or a casting app for Chromecast and smart TVs.
  Future<void> _external() async {
    final r = await FeedEngine.shared.resolve(_current);
    final u = r?.url ?? _current.mediaUrl;
    if (u == null) return;
    if (Platform.isAndroid) {
      try {
        await AndroidIntent(action: 'action_view', data: u.toString(), type: _isVideo ? 'video/*' : 'image/*').launchChooser('Play on…');
      } catch (_) {
        DownloadManager.shared.show('No app found to play this', success: false);
      }
    } else {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    }
  }

  // Slideshow

  void _toggleSlideshow() {
    setState(() {
      _slideshow = !_slideshow;
      if (_slideshow) _chrome = false;
    });
    _scheduleSlide();
  }

  /// Pictures stay for the chosen time; a video moves on when it ends (or after three minutes).
  void _scheduleSlide() {
    _slideTimer?.cancel();
    _ended?.cancel();
    if (!_slideshow) return;
    final secs = AppSettings.shared.slideshowSeconds;
    if (_isVideo) {
      _slideTimer = Timer(const Duration(minutes: 3), _advance);
      void watch() {
        final p = _player;
        if (p == null) {
          _slideTimer = Timer(const Duration(milliseconds: 500), () {
            if (_slideshow) watch();
          });
          return;
        }
        _ended = p.stream.completed.listen((done) {
          if (done) _advance();
        });
      }

      Timer(Duration(seconds: secs), () {
        if (_slideshow) watch();
      });
    } else {
      _slideTimer = Timer(Duration(seconds: secs), _advance);
    }
  }

  void _advance() {
    if (!_slideshow || !mounted || widget.items.length < 2) return;
    var next = _index + 1;
    if (AppSettings.shared.slideshowRandom) {
      final r = Random();
      do {
        next = r.nextInt(widget.items.length);
      } while (next == _index);
    }
    _page.animateToPage(next % widget.items.length, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
  }

  Future<void> _pickCollection(MediaItem item) async {
    final store = CollectionStore.shared;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: T.navy,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(18),
              child: Text('Add to collection', style: T.display(18)),
            ),
            for (final c in store.collections)
              ListTile(
                leading: Icon(store.contains(item, c.id) ? Icons.check_circle_rounded : Icons.folder_rounded, color: T.gold),
                title: Text(c.name, style: T.text(15, color: T.ink)),
                trailing: Text('${c.items.length}', style: T.mono(12)),
                onTap: () => Navigator.pop(ctx, c.id),
              ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_rounded, color: T.gold),
              title: Text('New collection…', style: T.text(15, color: T.ink)),
              onTap: () => Navigator.pop(ctx, ''),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked.isEmpty) {
      final name = await askName(context, 'New collection');
      final c = name == null ? null : store.create(name, item);
      if (c != null) DownloadManager.shared.show('Added to ${c.name}');
    } else {
      final added = store.toggle(item, picked);
      final c = store.collections.firstWhere((c) => c.id == picked);
      DownloadManager.shared.show(added ? 'Added to ${c.name}' : 'Removed from ${c.name}');
    }
    if (mounted) setState(() {});
  }

  /// Resolve and warm the neighbours so swiping feels instant.
  void _preload(int i) {
    for (final j in [i + 1, i - 1, i + 2]) {
      if (j < 0 || j >= widget.items.length) continue;
      final item = widget.items[j];
      FeedEngine.shared.resolve(item).then((r) {
        if (r != null && r.kind != MediaKind.video && !r.isListing) ImagePipeline.shared.prefetch([(r.url, r.referer)]);
      });
    }
  }

  void _go(int delta) {
    final t = _index + delta;
    if (t < 0 || t >= widget.items.length) return;
    _page.animateToPage(t, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final fade = 1 - (_dragY.abs() / 500).clamp(0.0, 0.7);
    return KeyboardListener(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (e) {
        if (e is! KeyDownEvent) return;
        if (e.logicalKey == LogicalKeyboardKey.escape) Navigator.pop(context);
        if (e.logicalKey == LogicalKeyboardKey.arrowRight) _go(1);
        if (e.logicalKey == LogicalKeyboardKey.arrowLeft) _go(-1);
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(color: Colors.black.withValues(alpha: fade)),
          ),
          Positioned.fill(
            child: GestureDetector(
              onVerticalDragUpdate: _zoomed ? null : (d) => setState(() => _dragY += d.delta.dy),
              onVerticalDragEnd: _zoomed
                  ? null
                  : (d) {
                      if (_dragY.abs() > 130 || (d.primaryVelocity ?? 0).abs() > 900) {
                        Navigator.pop(context);
                      } else {
                        setState(() => _dragY = 0);
                      }
                    },
              child: Transform.translate(
                offset: Offset(0, _dragY),
                child: Transform.scale(
                  scale: 1 - (_dragY.abs() / 2000).clamp(0.0, 0.12),
                  child: PageView.builder(
                    controller: _page,
                    // Neighbours are built ahead, so their images and videos are ready before the swipe.
                    allowImplicitScrolling: true,
                    physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
                    itemCount: widget.items.length,
                    onPageChanged: (i) {
                      HapticFeedback.selectionClick();
                      _clearLoop();
                      setState(() {
                        _index = i;
                        _zoomed = false;
                        _rate = 1;
                      });
                      Library.shared.record(_current);
                      _markLooked();
                      _preload(i);
                      _scheduleSlide();
                    },
                    itemBuilder: (context, i) => MediaPage(
                      key: ValueKey(widget.items[i].id),
                      item: widget.items[i],
                      isActive: i == _index,
                      onTap: () => setState(() => _chrome = !_chrome),
                      onZoom: (z) => setState(() => _zoomed = z),
                    ),
                  ),
                ),
              ),
            ),
          ),
          AnimatedOpacity(
            opacity: _chrome ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(ignoring: !_chrome, child: _bars(context)),
          ),
          ListenableBuilder(
            listenable: DownloadManager.shared,
            builder: (_, __) {
              final t = DownloadManager.shared.toast;
              return Positioned(
                top: MediaQuery.paddingOf(context).top + 70,
                left: 0,
                right: 0,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: t == null
                      ? const SizedBox.shrink()
                      : Center(
                          key: ValueKey(t.id),
                          child: ToastView(toast: t),
                        ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _bars(BuildContext context) {
    final item = _current;
    final wide = isWide(context);
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                _round(Icons.close_rounded, () => Navigator.pop(context)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.siteName.toUpperCase(), style: T.mono(10, spacing: 1), maxLines: 1),
                      Text(
                        item.displayTitle,
                        style: T.text(14, weight: FontWeight.w600, color: Colors.white),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                _round(Icons.auto_awesome_motion_rounded, _similar),
                const SizedBox(width: 8),
                _round(_slideshow ? Icons.pause_rounded : Icons.slideshow_rounded, _toggleSlideshow, active: _slideshow),
                const SizedBox(width: 10),
                Text('${_index + 1} / ${widget.items.length}', style: T.mono(12, color: Colors.white70)),
                if (wide) ...[
                  const SizedBox(width: 10),
                  _round(Icons.chevron_left_rounded, () => _go(-1)),
                  const SizedBox(width: 6),
                  _round(Icons.chevron_right_rounded, () => _go(1)),
                ],
              ],
            ),
          ),
          const Spacer(),
          if (_isVideo)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  _pill('−10 s', () => _seek(-10)),
                  _pill('+10 s', () => _seek(10)),
                  _pill('${_rate == _rate.roundToDouble() ? _rate.toInt() : _rate}×', _cycleRate),
                  _pill(_loopB != null ? 'A–B ✕' : (_loopA != null ? 'Set B' : 'A–B'), _tapLoop, active: _loopA != null),
                  _pill(Platform.isAndroid ? 'Cast / other app' : 'Open in player', _external),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Center(
              child: Frosted(
                radius: 26,
                child: ListenableBuilder(
                  listenable: Listenable.merge([Library.shared, DownloadManager.shared, CollectionStore.shared, WatchLater.shared]),
                  builder: (_, __) {
                    final fav = Library.shared.isFavorite(item);
                    final later = WatchLater.shared.contains(item);
                    final inCollection = CollectionStore.shared.inAny(item);
                    final downloading = DownloadManager.shared.active.contains(item.id);
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _action(fav ? Icons.favorite_rounded : Icons.favorite_border_rounded, fav ? 'Saved' : 'Favorite', () {
                          HapticFeedback.lightImpact();
                          Library.shared.toggleFavorite(item);
                        }, active: fav),
                        _action(Icons.create_new_folder_rounded, 'Collect', () => _pickCollection(item), active: inCollection),
                        _action(later ? Icons.watch_later_rounded : Icons.watch_later_outlined, 'Later', () {
                          HapticFeedback.lightImpact();
                          final on = WatchLater.shared.toggle(item);
                          DownloadManager.shared.show(on ? 'Added to Watch later' : 'Removed from Watch later');
                        }, active: later),
                        _action(
                          downloading ? Icons.hourglass_top_rounded : Icons.download_rounded,
                          'Download',
                          downloading ? null : () => DownloadManager.shared.download(item),
                        ),
                        _action(Icons.link_rounded, 'Copy link', () {
                          final u = item.pageUrl ?? item.mediaUrl;
                          if (u != null) Clipboard.setData(ClipboardData(text: u.toString()));
                          DownloadManager.shared.show('Link copied');
                        }),
                        if ((item.pageUrl ?? item.mediaUrl)?.scheme.startsWith('http') == true)
                          _action(
                            Icons.public_rounded,
                            'Open page',
                            () => ForumsSection.open(context, (item.pageUrl ?? item.mediaUrl)!, item.siteName),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _round(IconData icon, VoidCallback onTap, {bool active = false}) => Pressable(
    onTap: onTap,
    child: Frosted(
      radius: 21,
      child: SizedBox(width: 42, height: 42, child: Icon(icon, color: active ? T.gold : Colors.white, size: 22)),
    ),
  );

  Widget _pill(String label, VoidCallback onTap, {bool active = false}) => Pressable(
    onTap: onTap,
    child: Frosted(
      radius: 18,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: active ? BoxDecoration(gradient: T.goldGradient, borderRadius: BorderRadius.circular(18)) : null,
        child: Text(label, style: T.mono(13, color: active ? T.onGold : Colors.white)),
      ),
    ),
  );

  Widget _action(IconData icon, String label, VoidCallback? onTap, {bool active = false}) => Pressable(
    onTap: onTap,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: isWide(context) ? 18 : 11, vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: active ? T.gold : Colors.white, size: 22),
          const SizedBox(height: 3),
          Text(
            label,
            style: T.text(10, weight: FontWeight.w500, color: Colors.white70),
          ),
        ],
      ),
    ),
  );
}

class MediaPage extends StatefulWidget {
  final MediaItem item;
  final bool isActive;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoom;
  const MediaPage({super.key, required this.item, required this.isActive, required this.onTap, required this.onZoom});

  @override
  State<MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<MediaPage> {
  ResolvedMedia? _resolved;
  bool _failed = false;
  Player? _player;
  VideoController? _video;
  Timer? _progress;

  @override
  void initState() {
    super.initState();
    _resolved = FeedEngine.shared.cachedResolution(widget.item);
    _load();
  }

  @override
  void didUpdateWidget(MediaPage old) {
    super.didUpdateWidget(old);
    if (old.isActive != widget.isActive) {
      if (widget.isActive) {
        if (AppSettings.shared.autoplay) _player?.play();
        if (_resolved?.isListing == true) AppRouter.shared.openListing(widget.item);
      } else {
        _player?.pause();
        _saveProgress();
      }
    }
  }

  /// Remembers the position every few seconds while the video plays.
  void _track() {
    _progress?.cancel();
    _progress = Timer.periodic(const Duration(seconds: 4), (_) {
      final p = _player;
      if (p == null || !p.state.playing) return;
      ResumeStore.shared.update(widget.item, p.state.position, p.state.duration);
    });
  }

  void _saveProgress() {
    final p = _player;
    if (p == null || p.state.position.inSeconds <= 5) return;
    ResumeStore.shared.update(widget.item, p.state.position, p.state.duration);
  }

  @override
  void dispose() {
    _progress?.cancel();
    _saveProgress();
    if (identical(_players[widget.item.id], _player)) _players.remove(widget.item.id);
    _player?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    final r = await FeedEngine.shared.resolve(widget.item);
    if (!mounted) return;
    if (r == null) return setState(() => _failed = true);
    setState(() => _resolved = r);
    if (r.isListing) {
      if (widget.isActive) AppRouter.shared.openListing(widget.item);
      return;
    }
    if (r.kind == MediaKind.video && _player == null) {
      final s = AppSettings.shared;
      final p = Player(configuration: const PlayerConfiguration(bufferSize: 32 * 1024 * 1024));
      final v = VideoController(p);
      await p.setPlaylistMode(s.loopVideos ? PlaylistMode.single : PlaylistMode.none);
      if (s.startMuted) await p.setVolume(0);
      await p.open(Media(r.url.toString(), httpHeaders: Net.playerHeaders(r.referer, r.url)), play: false);
      if (!mounted) {
        await p.dispose();
        return;
      }
      // Carry on where you stopped last time.
      final at = ResumeStore.shared.position(widget.item.id);
      if (at != null) {
        await p.stream.duration.firstWhere((d) => d > Duration.zero).timeout(const Duration(seconds: 8), onTimeout: () => Duration.zero);
        await p.seek(at);
      }
      if (!mounted) {
        await p.dispose();
        return;
      }
      // The page may have been swiped away while the video opened.
      if (widget.isActive && s.autoplay) {
        await p.play();
      } else {
        await p.pause();
      }
      if (!mounted) {
        await p.dispose();
        return;
      }
      _players[widget.item.id] = p;
      _track();
      setState(() {
        _player = p;
        _video = v;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _resolved;
    Widget child;
    if (r != null && r.isListing) {
      child = _listing();
    } else if (r != null && r.kind == MediaKind.video) {
      child = _video == null
          ? _placeholder()
          : Padding(
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 60, bottom: 110),
              child: MaterialVideoControlsTheme(
                // Double-tap left or right to skip 10 s, hold for 2× speed.
                normal: const MaterialVideoControlsThemeData(
                  seekOnDoubleTap: true,
                  speedUpOnLongPress: true,
                  seekBarPositionColor: T.gold,
                  seekBarThumbColor: T.gold,
                ),
                fullscreen: kDefaultMaterialVideoControlsThemeDataFullscreen,
                child: Video(controller: _video!, fill: Colors.transparent),
              ),
            );
    } else if (r != null && r.gallery.length > 1) {
      child = _gallery(r);
    } else if (r != null) {
      child = ZoomableImage(url: r.url, referer: r.referer, thumb: widget.item.thumbnailUrl, onTap: widget.onTap, onZoom: widget.onZoom);
    } else if (_failed) {
      child = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning_amber_rounded, size: 36, color: T.gold),
            const SizedBox(height: 12),
            Text(
              'Couldn\'t load this content',
              style: T.text(15, weight: FontWeight.w500, color: T.ink),
            ),
            const SizedBox(height: 12),
            GhostButton(label: 'Try again', onPressed: _load),
          ],
        ),
      );
    } else {
      child = _placeholder();
    }
    return GestureDetector(behavior: HitTestBehavior.translucent, onTap: r?.kind == MediaKind.video ? null : widget.onTap, child: child);
  }

  /// The grid thumbnail is already cached, so something is on screen instantly.
  Widget _placeholder() => Stack(
    fit: StackFit.expand,
    children: [
      if (widget.item.thumbnailUrl != null)
        RemoteImage(url: widget.item.thumbnailUrl, referer: widget.item.referer, fit: BoxFit.contain, placeholder: false, decodeWidth: 600),
      const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
    ],
  );

  Widget _listing() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.grid_view_rounded, size: 34, color: T.gold),
          const SizedBox(height: 12),
          Text(
            widget.item.displayTitle,
            style: T.display(18, weight: FontWeight.w600),
            textAlign: TextAlign.center,
            maxLines: 2,
          ),
          const SizedBox(height: 6),
          Text('This is a category with more content.', style: T.text(14)),
          const SizedBox(height: 16),
          GoldButton(label: 'Open category', icon: Icons.arrow_forward_rounded, onPressed: () => AppRouter.shared.openListing(widget.item)),
        ],
      ),
    ),
  );

  Widget _gallery(ResolvedMedia r) => ListView.separated(
    padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 64, bottom: 120),
    itemCount: r.gallery.length,
    separatorBuilder: (_, __) => const SizedBox(height: 8),
    itemBuilder: (context, i) => _GalleryImage(url: r.gallery[i], referer: r.referer),
  );
}

class _GalleryImage extends StatefulWidget {
  final Uri url;
  final Uri? referer;
  const _GalleryImage({required this.url, this.referer});

  @override
  State<_GalleryImage> createState() => _GalleryImageState();
}

class _GalleryImageState extends State<_GalleryImage> {
  double _aspect = 1;

  @override
  void initState() {
    super.initState();
    ImagePipeline.shared.load(widget.url, referer: widget.referer).then((b) async {
      if (b == null) return;
      final codec = await ui.instantiateImageCodec(b);
      final f = await codec.getNextFrame();
      if (mounted && f.image.height > 0) setState(() => _aspect = f.image.width / f.image.height);
      f.image.dispose();
    });
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: _aspect,
    child: RemoteImage(url: widget.url, referer: widget.referer, fit: BoxFit.contain, decodeWidth: 1600),
  );
}

/// Pinch / double-tap / scroll-wheel zoom for one image at full resolution.
class ZoomableImage extends StatefulWidget {
  final Uri url;
  final Uri? referer;
  final Uri? thumb;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoom;
  const ZoomableImage({super.key, required this.url, this.referer, this.thumb, required this.onTap, required this.onZoom});

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage> {
  final _t = TransformationController();
  bool _ready = false;
  TapDownDetails? _tap;

  @override
  void initState() {
    super.initState();
    _ready = ImagePipeline.shared.cached(widget.url) != null;
    if (!_ready) {
      ImagePipeline.shared.load(widget.url, referer: widget.referer).then((_) {
        if (mounted) setState(() => _ready = true);
      });
    }
    _t.addListener(() => widget.onZoom(_t.value.getMaxScaleOnAxis() > 1.01));
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onTap,
    onDoubleTapDown: (d) => _tap = d,
    onDoubleTap: () {
      if (_t.value.getMaxScaleOnAxis() > 1.01) {
        _t.value = Matrix4.identity();
      } else {
        final p = _tap?.localPosition ?? Offset.zero;
        _t.value = Matrix4.identity()
          ..translateByDouble(-p.dx * 1.5, -p.dy * 1.5, 0, 1)
          ..scaleByDouble(2.5, 2.5, 1, 1);
      }
    },
    child: InteractiveViewer(
      transformationController: _t,
      minScale: 1,
      maxScale: 6,
      child: SizedBox.expand(
        child: _ready
            ? RemoteImage(url: widget.url, referer: widget.referer, fit: BoxFit.contain, placeholder: false, decodeWidth: null)
            : Stack(
                fit: StackFit.expand,
                children: [
                  if (widget.thumb != null)
                    RemoteImage(url: widget.thumb, referer: widget.referer, fit: BoxFit.contain, placeholder: false, decodeWidth: 600),
                  const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
                ],
              ),
      ),
    ),
  );
}

/// More like this, from the item's own page and the same site.
class SimilarSheet extends StatefulWidget {
  final MediaItem item;
  const SimilarSheet({super.key, required this.item});

  @override
  State<SimilarSheet> createState() => _SimilarSheetState();
}

class _SimilarSheetState extends State<SimilarSheet> {
  List<MediaItem>? _items;

  @override
  void initState() {
    super.initState();
    FeedEngine.shared.related(widget.item).then((l) {
      if (mounted) setState(() => _items = l);
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final a = widget.item.kind == MediaKind.video ? 16 / 11 : 4 / 5;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: Row(children: [Text('Similar', style: T.display(18)), const Spacer()]),
          ),
          Expanded(
            child: items == null
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: T.gold))
                : items.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: EmptyState(
                      icon: Icons.auto_awesome_motion_rounded,
                      title: 'Nothing similar found',
                      message: "This page doesn't link to related content.",
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: gridColumns(context),
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: a,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, i) => Pressable(
                      onTap: () => Navigator.pop(context, (items, i)),
                      child: MediaCard(item: items[i], aspect: a),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
