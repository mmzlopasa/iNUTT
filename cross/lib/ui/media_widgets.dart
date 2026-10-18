import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/downloads.dart';
import '../core/extras.dart';
import '../core/feed_engine.dart';
import '../core/image_cache.dart';
import '../core/net.dart';
import '../core/models.dart';
import '../core/stores.dart';
import 'remote_image.dart';
import 'router.dart';
import 'theme.dart';

class KindBadge extends StatelessWidget {
  final MediaItem item;
  const KindBadge({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final icon = switch (item.kind) {
      MediaKind.video => Icons.play_arrow_rounded,
      MediaKind.gif => Icons.gif_rounded,
      MediaKind.image => (item.gallery?.length ?? 0) > 1 ? Icons.collections_rounded : Icons.photo_rounded,
    };
    final label = item.kind == MediaKind.video
        ? (item.duration ?? 'VIDEO')
        : item.kind == MediaKind.gif
        ? 'GIF'
        : null;
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(11)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          if (label != null) ...[const SizedBox(width: 3), Text(label, style: T.mono(10, color: Colors.white))],
        ],
      ),
    );
  }
}

class MediaCard extends StatelessWidget {
  final MediaItem item;
  final double aspect;
  const MediaCard({super.key, required this.item, this.aspect = 4 / 5});

  @override
  Widget build(BuildContext context) {
    final card = _card();
    return Platform.isWindows && item.kind == MediaKind.video ? HoverPreview(item: item, child: card) : card;
  }

  Widget _card() => AspectRatio(
    aspectRatio: aspect,
    child: Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: T.edge, width: 0.6),
        color: T.navy2,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RemoteImage(url: item.thumbnailUrl, referer: item.referer, decodeWidth: 420),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.55, 1],
                colors: [Colors.transparent, Color(0xCC000000)],
              ),
            ),
          ),
          // Already opened: dimmed, so new things stand out.
          if (Library.shared.isSeen(item)) const ColoredBox(color: Color(0x59000000)),
          Positioned(
            top: 8,
            left: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                KindBadge(item: item),
                if (Library.shared.isSeen(item))
                  Container(
                    width: 22,
                    height: 22,
                    margin: const EdgeInsets.only(left: 4),
                    decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
                    child: const Icon(Icons.visibility_rounded, size: 13, color: Colors.white),
                  ),
              ],
            ),
          ),
          if (Library.shared.isFavorite(item))
            const Positioned(top: 8, right: 8, child: Icon(Icons.favorite_rounded, size: 18, color: T.gold)),
          if (item.title.isNotEmpty)
            Positioned(
              left: 10,
              right: 10,
              bottom: 9,
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: T.text(12.5, weight: FontWeight.w500, color: Colors.white),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Set by the app: opens items in a second window (Windows).
Future<void> Function(List<MediaItem> items, int index)? openInNewWindow;

/// Windows: resting the mouse on a video card plays it silently inside the card.
class HoverPreview extends StatefulWidget {
  final MediaItem item;
  final Widget child;
  const HoverPreview({super.key, required this.item, required this.child});

  @override
  State<HoverPreview> createState() => _HoverPreviewState();
}

class _HoverPreviewState extends State<HoverPreview> {
  /// Only one card plays at a time.
  static _HoverPreviewState? _playing;
  Timer? _wait;
  Player? _player;
  VideoController? _video;
  bool _ready = false;

  void _enter() {
    _wait?.cancel();
    _wait = Timer(const Duration(milliseconds: 450), _start);
  }

  Future<void> _start() async {
    final r = await FeedEngine.shared.resolve(widget.item);
    if (!mounted || _wait == null || r == null || r.kind != MediaKind.video) return;
    if (_playing != this) _playing?._stop();
    _playing = this;
    final p = Player();
    final v = VideoController(p);
    await p.setVolume(0);
    await p.setPlaylistMode(PlaylistMode.single);
    final at = ResumeStore.shared.position(widget.item.id);
    await p.open(Media(r.url.toString(), httpHeaders: Net.playerHeaders(r.referer, r.url), start: at), play: true);
    if (!mounted || _playing != this) {
      await p.dispose();
      return;
    }
    _player = p;
    _video = v;
    p.stream.width.firstWhere((w) => (w ?? 0) > 0).then((_) {
      if (mounted && _player == p) setState(() => _ready = true);
    }).ignore();
    setState(() {});
  }

  void _stop() {
    _wait?.cancel();
    _wait = null;
    final p = _player;
    _player = null;
    _video = null;
    _ready = false;
    if (_playing == this) _playing = null;
    p?.dispose();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => _enter(),
    onExit: (_) => _stop(),
    child: Stack(
      children: [
        widget.child,
        if (_video != null)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _ready ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Video(controller: _video!, fit: BoxFit.cover, controls: NoVideoControls, fill: Colors.black),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Long-press / right-click: a silent preview of the video (or the picture larger) above the actions.
void showMediaActions(BuildContext context, MediaItem item, {List<Widget> extra = const []}) {
  HapticFeedback.mediumImpact();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: T.navy,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      final fav = Library.shared.isFavorite(item);
      Widget tile(IconData i, String t, VoidCallback f) => ListTile(
        leading: Icon(i, color: T.gold),
        title: Text(t, style: T.text(15, color: T.ink)),
        onTap: () {
          Navigator.pop(ctx);
          f();
        },
      );
      final later = WatchLater.shared.contains(item);
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: ClipRRect(borderRadius: BorderRadius.circular(18), child: MediaPreview(item: item)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
              child: Text(
                item.displayTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: T.display(15, weight: FontWeight.w600),
              ),
            ),
            tile(
              fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              fav ? 'Remove from favorites' : 'Add to favorites',
              () => Library.shared.toggleFavorite(item),
            ),
            tile(later ? Icons.watch_later_rounded : Icons.watch_later_outlined, later ? 'Remove from Watch later' : 'Watch later', () {
              final on = WatchLater.shared.toggle(item);
              DownloadManager.shared.show(on ? 'Added to Watch later' : 'Removed from Watch later');
            }),
            tile(Icons.download_rounded, 'Download', () => DownloadManager.shared.download(item)),
            if (Platform.isWindows && !Disk.readOnly) tile(Icons.open_in_new_rounded, 'Open in new window', () => openInNewWindow?.call([item], 0)),
            ...extra,
            for (final c in CollectionStore.shared.collections)
              tile(
                CollectionStore.shared.contains(item, c.id) ? Icons.check_circle_rounded : Icons.folder_rounded,
                CollectionStore.shared.contains(item, c.id) ? 'In ${c.name}' : 'Add to ${c.name}',
                () {
                  final added = CollectionStore.shared.toggle(item, c.id);
                  DownloadManager.shared.show(added ? 'Added to ${c.name}' : 'Removed from ${c.name}');
                },
              ),
            tile(Icons.link_rounded, 'Copy link', () {
              final u = item.pageUrl ?? item.mediaUrl;
              if (u != null) Clipboard.setData(ClipboardData(text: u.toString()));
              DownloadManager.shared.show('Link copied');
            }),
            const SizedBox(height: 8),
          ],
          ),
        ),
      );
    },
  );
}

/// Media grid as a sliver: 2 columns on phones, 5 on tablets and desktop.
class SliverMediaGrid extends StatelessWidget {
  final List<MediaItem> items;
  final VoidCallback? onReachEnd;
  const SliverMediaGrid({super.key, required this.items, this.onReachEnd});

  /// Fixed per list, so cards don't jump when an item turns out to be a video while scrolling.
  static final Map<String, double> _aspects = {};

  @override
  Widget build(BuildContext context) {
    final aspect = _aspects.putIfAbsent(items.isEmpty ? '' : items.first.id, () {
      final sample = items.take(30).toList();
      final videos = sample.where((e) => e.kind == MediaKind.video).length;
      return videos * 2 > sample.length ? 16 / 11 : 4 / 5;
    });
    if (_aspects.length > 200) _aspects.clear();
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: gridColumns(context),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: aspect,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, idx) {
          if (idx >= items.length - 6) WidgetsBinding.instance.addPostFrameCallback((_) => onReachEnd?.call());
          // Warm the next screenful of thumbnails while scrolling.
          if (idx % 6 == 0) {
            ImagePipeline.shared.prefetch([
              for (final i in items.skip(idx + 1).take(18))
                if (i.thumbnailUrl != null) (i.thumbnailUrl!, i.referer),
            ]);
          }
          final item = items[idx];
          // Load what's on screen ahead of the tap, so it opens at once.
          FeedEngine.shared.prefetch(item);
          return Pressable(
            onTap: () => AppRouter.shared.open(items, idx),
            onLongPress: () => showMediaActions(context, item),
            child: GestureDetector(
              onSecondaryTap: () => showMediaActions(context, item),
              child: MediaCard(item: item, aspect: aspect),
            ),
          );
        },
        childCount: items.length,
        addAutomaticKeepAlives: false,
      ),
    );
  }
}

class KindFilterBar extends StatelessWidget {
  final MediaKind? filter;
  final ValueChanged<MediaKind?> onChanged;
  const KindFilterBar({super.key, required this.filter, required this.onChanged});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 34,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        Chip2(title: 'All', icon: Icons.auto_awesome_rounded, selected: filter == null, onTap: () => onChanged(null)),
        for (final k in MediaKind.values) ...[
          const SizedBox(width: 8),
          Chip2(
            title: k.label,
            icon: switch (k) {
              MediaKind.image => Icons.photo_rounded,
              MediaKind.gif => Icons.gif_box_rounded,
              MediaKind.video => Icons.play_circle_rounded,
            },
            selected: filter == k,
            onTap: () => onChanged(k),
          ),
        ],
      ],
    ),
  );
}

class ToastView extends StatelessWidget {
  final Toast toast;
  const ToastView({super.key, required this.toast});

  @override
  Widget build(BuildContext context) => Frosted(
    radius: 22,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(toast.success ? Icons.check_circle_rounded : Icons.error_rounded, size: 18, color: toast.success ? T.gold : T.err),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              toast.message,
              style: T.text(14, weight: FontWeight.w500, color: T.ink),
            ),
          ),
        ],
      ),
    ),
  );
}

class LoadingGrid extends StatelessWidget {
  const LoadingGrid({super.key});

  @override
  Widget build(BuildContext context) => SliverGrid(
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: gridColumns(context),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 4 / 5,
    ),
    delegate: SliverChildBuilderDelegate((_, __) => const Shimmer(radius: 18), childCount: gridColumns(context) * 3),
  );
}

/// Plays the video silently (from where you stopped), or shows the picture larger.
class MediaPreview extends StatefulWidget {
  final MediaItem item;
  const MediaPreview({super.key, required this.item});

  @override
  State<MediaPreview> createState() => _MediaPreviewState();
}

class _MediaPreviewState extends State<MediaPreview> {
  Player? _player;
  VideoController? _video;
  ResolvedMedia? _media;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await FeedEngine.shared.resolve(widget.item);
    if (!mounted || r == null || r.isListing) return;
    if (r.kind != MediaKind.video) {
      if (r.gallery.length <= 1) setState(() => _media = r);
      return;
    }
    final p = Player();
    final v = VideoController(p);
    await p.setVolume(0);
    await p.setPlaylistMode(PlaylistMode.single);
    await p.open(Media(r.url.toString(), httpHeaders: Net.playerHeaders(r.referer, r.url)), play: false);
    final at = ResumeStore.shared.position(widget.item.id);
    if (at != null) {
      await p.stream.duration.firstWhere((d) => d > Duration.zero).timeout(const Duration(seconds: 6), onTimeout: () => Duration.zero);
      await p.seek(at);
    }
    if (!mounted) {
      await p.dispose();
      return;
    }
    await p.play();
    setState(() {
      _player = p;
      _video = v;
    });
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.item.kind == MediaKind.video || _video != null;
    final h = (MediaQuery.sizeOf(context).height * (video ? 0.28 : 0.4)).clamp(160.0, 420.0);
    return SizedBox(
      height: h,
      width: double.infinity,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RemoteImage(url: widget.item.thumbnailUrl, referer: widget.item.referer, fit: BoxFit.contain, placeholder: false, decodeWidth: 800),
            if (_media != null)
              RemoteImage(url: _media!.url, referer: _media!.referer, fit: BoxFit.contain, placeholder: false, decodeWidth: 1400),
            if (_video != null) Video(controller: _video!, controls: NoVideoControls, fill: Colors.black),
          ],
        ),
      ),
    );
  }
}
