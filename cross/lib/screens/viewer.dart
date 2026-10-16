import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/downloads.dart';
import '../core/feed_engine.dart';
import '../core/image_cache.dart';
import '../core/models.dart';
import '../core/net.dart';
import '../core/stores.dart';
import '../ui/media_widgets.dart';
import '../ui/remote_image.dart';
import '../ui/router.dart';
import '../ui/theme.dart';

/// Full-screen pager for images, GIFs and videos. Swipe sideways to browse, drag down to close.
class MediaViewer extends StatefulWidget {
  final List<MediaItem> items;
  final int startIndex;
  const MediaViewer({super.key, required this.items, required this.startIndex});

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  late final PageController _page = PageController(initialPage: widget.startIndex);
  late int _index = widget.startIndex;
  bool _chrome = true;
  bool _zoomed = false;
  double _dragY = 0;
  final _focus = FocusNode();

  MediaItem get _current => widget.items[_index.clamp(0, widget.items.length - 1)];

  @override
  void initState() {
    super.initState();
    Library.shared.record(_current);
    _preload(_index);
  }

  @override
  void dispose() {
    _page.dispose();
    _focus.dispose();
    super.dispose();
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
      child: Stack(children: [
        Positioned.fill(child: ColoredBox(color: Colors.black.withValues(alpha: fade))),
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
                  physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
                  itemCount: widget.items.length,
                  onPageChanged: (i) {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _index = i;
                      _zoomed = false;
                    });
                    Library.shared.record(_current);
                    _preload(i);
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
                child: t == null ? const SizedBox.shrink() : Center(key: ValueKey(t.id), child: ToastView(toast: t)),
              ),
            );
          },
        ),
      ]),
    );
  }

  Widget _bars(BuildContext context) {
    final item = _current;
    final wide = isWide(context);
    return SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(children: [
            _round(Icons.close_rounded, () => Navigator.pop(context)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.siteName.toUpperCase(), style: T.mono(10, spacing: 1), maxLines: 1),
                Text(item.displayTitle, style: T.text(14, weight: FontWeight.w600, color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
            Text('${_index + 1} / ${widget.items.length}', style: T.mono(12, color: Colors.white70)),
            if (wide) ...[
              const SizedBox(width: 10),
              _round(Icons.chevron_left_rounded, () => _go(-1)),
              const SizedBox(width: 6),
              _round(Icons.chevron_right_rounded, () => _go(1)),
            ],
          ]),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Center(
            child: Frosted(
              radius: 26,
              child: ListenableBuilder(
                listenable: Listenable.merge([Library.shared, DownloadManager.shared]),
                builder: (_, __) {
                  final fav = Library.shared.isFavorite(item);
                  final downloading = DownloadManager.shared.active.contains(item.id);
                  return Row(mainAxisSize: MainAxisSize.min, children: [
                    _action(fav ? Icons.favorite_rounded : Icons.favorite_border_rounded, fav ? 'Saved' : 'Favorite', () {
                      HapticFeedback.lightImpact();
                      Library.shared.toggleFavorite(item);
                    }, active: fav),
                    _action(downloading ? Icons.hourglass_top_rounded : Icons.download_rounded, 'Download',
                        downloading ? null : () => DownloadManager.shared.download(item)),
                    _action(Icons.link_rounded, 'Copy link', () {
                      final u = item.pageUrl ?? item.mediaUrl;
                      if (u != null) Clipboard.setData(ClipboardData(text: u.toString()));
                      DownloadManager.shared.show('Link copied');
                    }),
                  ]);
                },
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _round(IconData icon, VoidCallback onTap) => Pressable(
        onTap: onTap,
        child: Frosted(radius: 21, child: SizedBox(width: 42, height: 42, child: Icon(icon, color: Colors.white, size: 22))),
      );

  Widget _action(IconData icon, String label, VoidCallback? onTap, {bool active = false}) => Pressable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: active ? T.gold : Colors.white, size: 22),
            const SizedBox(height: 3),
            Text(label, style: T.text(10, weight: FontWeight.w500, color: Colors.white70)),
          ]),
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
      }
    }
  }

  @override
  void dispose() {
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
      await p.open(Media(r.url.toString(), httpHeaders: Net.playerHeaders(r.referer)), play: widget.isActive && s.autoplay);
      if (!mounted) {
        await p.dispose();
        return;
      }
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
              child: Video(controller: _video!, fill: Colors.transparent),
            );
    } else if (r != null && r.gallery.length > 1) {
      child = _gallery(r);
    } else if (r != null) {
      child = ZoomableImage(url: r.url, referer: r.referer, thumb: widget.item.thumbnailUrl, onTap: widget.onTap, onZoom: widget.onZoom);
    } else if (_failed) {
      child = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.warning_amber_rounded, size: 36, color: T.gold),
          const SizedBox(height: 12),
          Text('Couldn\'t load this content', style: T.text(15, weight: FontWeight.w500, color: T.ink)),
          const SizedBox(height: 12),
          GhostButton(label: 'Try again', onPressed: _load),
        ]),
      );
    } else {
      child = _placeholder();
    }
    return GestureDetector(behavior: HitTestBehavior.translucent, onTap: r?.kind == MediaKind.video ? null : widget.onTap, child: child);
  }

  /// The grid thumbnail is already cached, so something is on screen instantly.
  Widget _placeholder() => Stack(fit: StackFit.expand, children: [
        if (widget.item.thumbnailUrl != null)
          RemoteImage(url: widget.item.thumbnailUrl, referer: widget.item.referer, fit: BoxFit.contain, placeholder: false, decodeWidth: 600),
        const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      ]);

  Widget _listing() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.grid_view_rounded, size: 34, color: T.gold),
            const SizedBox(height: 12),
            Text(widget.item.displayTitle, style: T.display(18, weight: FontWeight.w600), textAlign: TextAlign.center, maxLines: 2),
            const SizedBox(height: 6),
            Text('This is a category with more content.', style: T.text(14)),
            const SizedBox(height: 16),
            GoldButton(label: 'Open category', icon: Icons.arrow_forward_rounded, onPressed: () => AppRouter.shared.openListing(widget.item)),
          ]),
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
                : Stack(fit: StackFit.expand, children: [
                    if (widget.thumb != null)
                      RemoteImage(url: widget.thumb, referer: widget.referer, fit: BoxFit.contain, placeholder: false, decodeWidth: 600),
                    const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
                  ]),
          ),
        ),
      );
}
