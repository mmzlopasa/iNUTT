import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/downloads.dart';
import '../core/feed_engine.dart';
import '../core/models.dart';
import '../core/net.dart';
import '../core/security.dart';
import '../core/stores.dart';
import '../ui/remote_image.dart';
import '../ui/router.dart';
import '../ui/theme.dart';

/// Loads the short videos of the one Reels source and keeps them for an instant start next time.
class ReelsStore extends ChangeNotifier {
  static final ReelsStore shared = ReelsStore._();
  ReelsStore._() {
    final j = Disk.load('reels.json');
    if (j is Map<String, dynamic> && j['source'] == AppSettings.shared.reelsSource) {
      items = (j['items'] as List? ?? []).map((e) => MediaItem.fromJson(e as Map<String, dynamic>)).toList();
      _next = j['next'] == null ? null : Uri.tryParse(j['next'] as String);
      _loadedSource = j['source'] as String;
      _rounds = j['rounds'] as int? ?? 0;
    }
  }

  List<MediaItem> items = [];
  bool loading = false;
  String? error;
  Uri? _next;
  String _loadedSource = '';
  int _rounds = 0;

  Uri? get sourceUrl => SiteStore.normalize(AppSettings.shared.reelsSource);

  /// A hidden site describing the source, so the normal loaders can read it.
  Site? get site {
    final u = sourceUrl;
    if (u == null) return null;
    return Site(id: 'reels-source', name: u.host.replaceFirst('www.', ''), url: u);
  }

  Future<void> loadIfNeeded() async {
    if (_loadedSource != AppSettings.shared.reelsSource) {
      items = [];
      _next = null;
      _rounds = 0;
      error = null;
      notifyListeners();
    }
    if (items.isEmpty) await refresh();
  }

  Future<void> refresh() async {
    final site = this.site;
    if (site == null || loading) return;
    final source = AppSettings.shared.reelsSource;
    loading = true;
    notifyListeners();
    _rounds = 0;
    ScrapeResult? r;
    try {
      r = await FeedEngine.fetchListing(site.url, site.url, site, null);
    } catch (_) {}
    var list = <MediaItem>[];
    final strong = (r?.items ?? []).where((i) => !i.isListing && (i.kind == MediaKind.video || i.kind == MediaKind.gif || i.duration != null));
    // TikTok-style pages load their videos while you swipe: play through the page and keep what it loads.
    if (strong.length < 6) {
      final captured = await _capture(site, 10);
      if (captured.length >= 2) {
        list = captured;
        _rounds = 10;
      }
    }
    if (list.isEmpty && r != null) {
      list = reels(r.items);
      // A page of categories: play the first ones.
      if (list.length < 4) {
        for (final c in r.categories.take(3)) {
          try {
            final r2 = await FeedEngine.fetchListing(c.url, c.url, site, c.name);
            final have = list.map((e) => e.id).toSet();
            list += reels(r2.items).where((e) => !have.contains(e.id)).toList();
          } catch (_) {}
        }
      }
    }
    // The link itself is one reel (a single video page).
    if (list.isEmpty) list = [MediaItem(siteId: site.id, siteName: site.name, title: '', pageUrl: site.url, kind: MediaKind.video)];
    // The source changed while this one loaded: drop it and load the new one.
    if (source != AppSettings.shared.reelsSource) {
      loading = false;
      unawaited(loadIfNeeded());
      return;
    }
    items = list;
    _next = _rounds > 0 ? null : r?.nextPage;
    _loadedSource = AppSettings.shared.reelsSource;
    error = null;
    _save();
    loading = false;
    notifyListeners();
  }

  Future<void> loadMore() async {
    final site = this.site;
    if (site == null || loading) return;
    final source = AppSettings.shared.reelsSource;
    if (_rounds > 0) {
      // Swipe further through the page for the next videos.
      if (_rounds >= 60) return;
      loading = true;
      _rounds += 10;
      final have = items.map((e) => e.id).toSet();
      final more = await _capture(site, _rounds);
      if (source != AppSettings.shared.reelsSource) {
        loading = false;
        return;
      }
      items = [...items, ...more.where((e) => !have.contains(e.id))];
      _save();
      loading = false;
      notifyListeners();
      return;
    }
    final next = _next;
    if (next == null) return;
    loading = true;
    try {
      final r = await FeedEngine.fetchListing(next, site.url, site, null);
      if (source != AppSettings.shared.reelsSource) throw StateError('source changed');
      final have = items.map((e) => e.id).toSet();
      items = [...items, ...reels(r.items).where((e) => !have.contains(e.id))];
      _next = r.nextPage == next ? null : r.nextPage;
      _save();
    } catch (_) {
      _next = null;
    }
    loading = false;
    notifyListeners();
  }

  Future<List<MediaItem>> _capture(Site site, int rounds) async {
    final found = await PageRenderer.shared.captureVideos(site.url, rounds: rounds);
    return [
      for (final v in found)
        // Every video comes from the same page; tell them apart by their file.
        MediaItem(
          id: hashKey(v.url.toString()),
          siteId: site.id,
          siteName: site.name,
          title: v.title,
          thumbnailUrl: v.poster,
          mediaUrl: v.url,
          pageUrl: site.url,
          kind: MediaKind.video,
        ),
    ];
  }

  /// Videos, GIFs, and post links that may hold one, from any site. Post links are treated as
  /// videos so resolving them renders the page until its video shows up. Plain pictures are left out.
  static List<MediaItem> reels(List<MediaItem> items) => [
        for (final i in items)
          if (!i.isListing && (i.kind == MediaKind.video || i.kind == MediaKind.gif))
            i
          else if (!i.isListing && i.mediaUrl == null && i.pageUrl != null)
            (i..kind = MediaKind.video),
      ];

  void _save() => unawaited(Disk.save('reels.json', {
        'source': _loadedSource,
        'items': items.take(300).map((e) => e.toJson()).toList(),
        'next': _next?.toString(),
        'rounds': _rounds,
      }));
}

/// TikTok-style feed: one full-screen video at a time, swipe up for the next.
class ReelsView extends StatefulWidget {
  const ReelsView({super.key});

  @override
  State<ReelsView> createState() => _ReelsViewState();
}

class _ReelsViewState extends State<ReelsView> {
  final _page = PageController();
  int _index = 0;
  String _source = AppSettings.shared.reelsSource;

  /// Playing only while the Reels tab is on screen, the app is open and unlocked.
  bool _active = false;

  @override
  void initState() {
    super.initState();
    AppSettings.shared.addListener(_settingsChanged);
    AppRouter.shared.addListener(_activityChanged);
    LockManager.shared.addListener(_activityChanged);
    appResumed.addListener(_activityChanged);
    _active = _shouldPlay;
    if (_active) unawaited(ReelsStore.shared.loadIfNeeded());
  }

  bool get _shouldPlay => AppRouter.shared.tab == AppTab.reels && !LockManager.shared.isLocked && appResumed.value;

  @override
  void dispose() {
    AppSettings.shared.removeListener(_settingsChanged);
    AppRouter.shared.removeListener(_activityChanged);
    LockManager.shared.removeListener(_activityChanged);
    appResumed.removeListener(_activityChanged);
    _page.dispose();
    super.dispose();
  }

  void _activityChanged() {
    final active = _shouldPlay;
    if (active == _active) return;
    if (mounted) setState(() => _active = active);
    if (active) unawaited(ReelsStore.shared.loadIfNeeded());
  }

  void _settingsChanged() {
    if (AppSettings.shared.reelsSource == _source) return;
    _source = AppSettings.shared.reelsSource;
    setState(() => _index = 0);
    if (_page.hasClients) _page.jumpToPage(0);
    unawaited(ReelsStore.shared.loadIfNeeded());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ReelsStore.shared,
        builder: (context, _) {
          final store = ReelsStore.shared;
          Widget body;
          if (store.sourceUrl == null) {
            body = _setup(context);
          } else if (store.items.isEmpty) {
            body = store.loading
                ? const Center(child: CircularProgressIndicator(color: T.gold))
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        EmptyState(
                          icon: Icons.smart_display_rounded,
                          title: 'No reels',
                          message: store.error ?? 'Nothing to play yet.',
                          buttonTitle: 'Try again',
                          onButton: store.refresh,
                        ),
                        const SizedBox(height: 14),
                        GhostButton(label: 'Change source', onPressed: () => _editSource(context)),
                      ]),
                    ),
                  );
          } else {
            body = Stack(children: [
              PageView.builder(
                controller: _page,
                scrollDirection: Axis.vertical,
                allowImplicitScrolling: true,
                itemCount: store.items.length,
                onPageChanged: (i) {
                  HapticFeedback.selectionClick();
                  setState(() => _index = i);
                  if (i >= store.items.length - 4) unawaited(store.loadMore());
                },
                itemBuilder: (context, i) => ReelPage(
                  key: ValueKey(store.items[i].id),
                  item: store.items[i],
                  active: _active && i == _index,
                ),
              ),
              _topBar(context),
            ]);
          }
          return ColoredBox(color: Colors.black, child: body);
        },
      );

  Widget _topBar(BuildContext context) => Positioned(
        top: MediaQuery.paddingOf(context).top + 4,
        left: 16,
        right: 16,
        child: Row(children: [
          Text('Reels', style: T.display(20, weight: FontWeight.w700, color: Colors.white)),
          const Spacer(),
          _RoundButton(icon: Icons.tune_rounded, onTap: () => _editSource(context)),
        ]),
      );

  Widget _setup(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const EmptyState(
                icon: Icons.smart_display_rounded,
                title: 'Reels',
                message: 'Add one link with short videos. They play full screen; swipe up for the next one.',
              ),
              const SizedBox(height: 16),
              const _SourceField(),
            ]),
          ),
        ),
      );

  void _editSource(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        backgroundColor: T.bg,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (context) => Padding(
          padding: EdgeInsets.fromLTRB(16, 20, 16, MediaQuery.viewInsetsOf(context).bottom + 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Reels source', style: T.display(18, weight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('One link to any site with short videos. A few sites, like TikTok and Instagram, block apps from reading their feed.',
                style: T.text(13, color: T.muted)),
            const SizedBox(height: 14),
            const _SourceField(closeOnSave: true),
          ]),
        ),
      );
}

class _SourceField extends StatefulWidget {
  final bool closeOnSave;
  const _SourceField({this.closeOnSave = false});

  @override
  State<_SourceField> createState() => _SourceFieldState();
}

class _SourceFieldState extends State<_SourceField> {
  late final _text = TextEditingController(text: AppSettings.shared.reelsSource);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _valid => SiteStore.normalize(_text.text) != null;

  void _save() {
    if (!_valid) return;
    AppSettings.shared.reelsSource = _text.text.trim();
    if (widget.closeOnSave) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _text,
          autocorrect: false,
          keyboardType: TextInputType.url,
          style: T.mono(14, color: T.ink),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _save(),
          decoration: InputDecoration(
            hintText: 'any video site or r/subreddit',
            hintStyle: T.mono(14, color: T.muted),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.06),
            contentPadding: const EdgeInsets.all(14),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: T.line2)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: T.line2)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: T.gold)),
          ),
        ),
        const SizedBox(height: 12),
        GoldButton(label: 'Use this source', onPressed: _valid ? _save : null),
      ]);
}

/// One reel: a full-screen video that fills the screen, with its title and actions on top.
class ReelPage extends StatefulWidget {
  final MediaItem item;
  final bool active;
  const ReelPage({super.key, required this.item, required this.active});

  @override
  State<ReelPage> createState() => _ReelPageState();
}

class _ReelPageState extends State<ReelPage> {
  ResolvedMedia? _resolved;
  Player? _player;
  VideoController? _video;
  bool _failed = false;
  bool _paused = false;
  bool _muted = AppSettings.shared.startMuted;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ReelPage old) {
    super.didUpdateWidget(old);
    if (old.active == widget.active) return;
    if (widget.active) {
      Library.shared.record(widget.item);
      if (!_paused) _player?.play();
    } else {
      _player?.pause();
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await FeedEngine.shared.resolve(widget.item);
    if (!mounted) return;
    if (r == null || r.isListing) return setState(() => _failed = true);
    setState(() => _resolved = r);
    if (r.kind != MediaKind.video) {
      if (widget.active) Library.shared.record(widget.item);
      return;
    }
    final p = Player(configuration: const PlayerConfiguration(bufferSize: 16 * 1024 * 1024));
    final v = VideoController(p);
    await p.setPlaylistMode(PlaylistMode.single);
    if (_muted) await p.setVolume(0);
    await p.open(Media(r.url.toString(), httpHeaders: Net.playerHeaders(r.referer)), play: widget.active && !_paused);
    if (!mounted) {
      await p.dispose();
      return;
    }
    // The page may have scrolled away while the video opened.
    if (widget.active && !_paused) {
      await p.play();
    } else {
      await p.pause();
    }
    if (widget.active) Library.shared.record(widget.item);
    setState(() {
      _player = p;
      _video = v;
    });
  }

  void _togglePause() {
    final p = _player;
    if (p == null) return;
    setState(() => _paused = !_paused);
    _paused ? p.pause() : p.play();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _player?.setVolume(_muted ? 0 : 100);
    AppSettings.shared.startMuted = _muted;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final r = _resolved;
    Widget media;
    if (_video != null) {
      media = Video(controller: _video!, fit: BoxFit.cover, fill: Colors.black, controls: NoVideoControls);
    } else if (r != null && r.kind != MediaKind.video) {
      media = RemoteImage(url: r.url, referer: r.referer, fit: BoxFit.contain, placeholder: false, decodeWidth: 900);
    } else {
      media = Stack(fit: StackFit.expand, children: [
        if (item.thumbnailUrl != null)
          RemoteImage(url: item.thumbnailUrl, referer: item.referer, fit: BoxFit.cover, placeholder: false, decodeWidth: 600),
        Center(
          child: _failed
              ? Text('Couldn\'t play this one. Swipe up for the next.', style: T.text(14, color: T.body), textAlign: TextAlign.center)
              : const CircularProgressIndicator(strokeWidth: 2.5, color: T.gold),
        ),
      ]);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _togglePause,
      child: Stack(fit: StackFit.expand, children: [
        const ColoredBox(color: Colors.black),
        media,
        if (_paused) Center(child: Icon(Icons.play_arrow_rounded, size: 72, color: Colors.white.withValues(alpha: 0.85))),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0x8C000000)]),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 80, 16, MediaQuery.paddingOf(context).bottom + 96),
              child: ListenableBuilder(
                listenable: Library.shared,
                builder: (context, _) {
                  final fav = Library.shared.isFavorite(item);
                  return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(item.siteName.toUpperCase(), style: T.mono(10, color: T.gold, spacing: 1)),
                        if (item.title.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(item.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: T.text(15, weight: FontWeight.w500, color: Colors.white)),
                        ],
                      ]),
                    ),
                    const SizedBox(width: 12),
                    Column(mainAxisSize: MainAxisSize.min, children: [
                      _RoundButton(
                          icon: fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                          on: fav,
                          size: 48,
                          onTap: () => Library.shared.toggleFavorite(item)),
                      const SizedBox(height: 16),
                      _RoundButton(icon: Icons.download_rounded, size: 48, onTap: () => DownloadManager.shared.download(item)),
                      const SizedBox(height: 16),
                      _RoundButton(icon: _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, size: 48, onTap: _toggleMute),
                    ]),
                  ]);
                },
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool on;
  final double size;
  const _RoundButton({required this.icon, required this.onTap, this.on = false, this.size = 40});

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: 0.32)),
          child: Icon(icon, size: size * 0.5, color: on ? T.gold : Colors.white),
        ),
      );
}
