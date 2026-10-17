import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/feed_engine.dart';
import '../core/models.dart';
import '../core/security.dart';
import '../core/stores.dart';
import '../ui/media_widgets.dart';
import '../ui/remote_image.dart';
import '../ui/router.dart';
import '../ui/theme.dart';
import 'library.dart';
import 'settings.dart';
import 'site_detail.dart';

class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  int _latestLimit = 120;
  bool _loadingMore = false;
  MediaKind? get _filter => AppRouter.shared.homeFilter.value;

  @override
  void initState() {
    super.initState();
    AppRouter.shared.homeFilter.addListener(_filterChanged);
  }

  @override
  void dispose() {
    AppRouter.shared.homeFilter.removeListener(_filterChanged);
    super.dispose();
  }

  void _filterChanged() => setState(() => _latestLimit = 120);

  /// Shows more of what is loaded, then asks the sites for their next pages.
  void _moreLatest(int total, int shownLimit) {
    // Several cards near the end ask at once; act once per page.
    if (!mounted || shownLimit != _latestLimit) return;
    if (_latestLimit < total) {
      setState(() => _latestLimit += 120);
      return;
    }
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    FeedEngine.shared.loadMoreHome(SiteStore.shared.enabledSites).whenComplete(() {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _latestLimit += 120;
      });
    });
  }

  String get _greeting {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 12) return 'Good morning';
    if (h >= 12 && h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([FeedEngine.shared, SiteStore.shared, Library.shared.favoritesVersion, AppSettings.shared]),
        builder: (context, _) {
          final engine = FeedEngine.shared;
          final enabled = SiteStore.shared.enabledSites;
          var items = engine.mixedFeed(enabled);
          if (AppSettings.shared.hideSeen) items = items.where((e) => !Library.shared.isSeen(e)).toList();
          if (_filter != null) items = items.where((e) => e.kind == _filter).toList();
          final slivers = <Widget>[
            SliverToBoxAdapter(child: SafeArea(bottom: false, child: _header(context))),
          ];
          if (enabled.isEmpty) {
            slivers.add(SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: EmptyState(
                  icon: Icons.auto_awesome_rounded,
                  title: 'Welcome to iNUTT',
                  message: 'Add sites with images, GIFs and videos. Everything is shown natively, no browser.',
                  buttonTitle: 'Add site',
                  onButton: () => _add(context),
                ),
              ),
            ));
          } else if (items.isEmpty && enabled.every((s) => s.categories.isEmpty)) {
            slivers.add(SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: engine.isRefreshingAll || engine.loading.isNotEmpty
                    ? Column(children: List.generate(3, (_) => const Padding(padding: EdgeInsets.only(bottom: 14), child: SizedBox(height: 180, child: Shimmer(radius: 22)))))
                    : EmptyState(
                        icon: Icons.auto_fix_high_rounded,
                        title: 'No content yet',
                        message: 'Pull down to refresh or check your site settings.',
                        buttonTitle: 'Refresh',
                        onButton: engine.refreshAll,
                      ),
              ),
            ));
          } else {
            if (items.isNotEmpty) {
              slivers.add(SliverToBoxAdapter(child: HeroCarousel(key: ValueKey(_filter), items: items.take(8).toList())));
            }
            slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 18)));
            slivers.add(SliverToBoxAdapter(child: KindFilterBar(filter: _filter, onChanged: (k) => AppRouter.shared.homeFilter.value = k)));
            if (_filter == null) {
              for (final s in enabled) {
                slivers.add(SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.only(top: 22), child: SiteRow(site: s))));
              }
            }
            if (items.isNotEmpty) {
              slivers.add(SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 26, 16, 12),
                sliver: SliverToBoxAdapter(
                    child: SectionHeader(
                        title: _filter == null ? 'Latest' : 'Latest ${_filter!.label}',
                        subtitle: '${items.length} items from ${enabled.length} sites')),
              ));
              final total = items.length;
              final limit = _latestLimit;
              slivers.add(SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverMediaGrid(items: items.take(_latestLimit).toList(), onReachEnd: () => _moreLatest(total, limit)),
              ));
              if (_loadingMore) {
                slivers.add(const SliverToBoxAdapter(
                    child: Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: T.gold)))));
              }
            } else if (_filter != null) {
              slivers.add(SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverToBoxAdapter(
                  child: EmptyState(
                    icon: Icons.filter_alt_off_rounded,
                    title: 'No ${_filter!.label} yet',
                    message: 'None of your sites has shown ${_filter!.label} so far. Pull down to refresh.',
                  ),
                ),
              ));
            }
          }
          slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 110)));
          return SkyScaffold(
            body: RefreshIndicator(color: T.gold, onRefresh: engine.refreshAll, child: CustomScrollView(slivers: slivers)),
          );
        },
      );

  /// Opens everything Home shows in random order.
  void _shuffle() {
    var items = FeedEngine.shared.mixedFeed(SiteStore.shared.enabledSites).where((e) => !e.isListing).toList();
    if (AppSettings.shared.hideSeen) items = items.where((e) => !Library.shared.isSeen(e)).toList();
    final f = _filter;
    if (f != null) items = items.where((e) => e.kind == f).toList();
    if (items.isEmpty) return;
    HapticFeedback.lightImpact();
    items.shuffle();
    AppRouter.shared.open(items.take(300).toList(), 0);
  }

  void _add(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AddSiteView(), fullscreenDialog: true));

  Widget _header(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_greeting.toUpperCase(), style: T.mono(11, spacing: 1.2)),
              const Wordmark(size: 30),
            ]),
          ),
          if (FeedEngine.shared.isRefreshingAll)
            const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2))),
          if (LockManager.shared.hasLock) ...[_circle(Icons.lock_rounded, LockManager.shared.lockNow), const SizedBox(width: 6)],
          _circle(Icons.shuffle_rounded, _shuffle),
          const SizedBox(width: 6),
          _circle(Icons.history_rounded, () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HistoryView()))),
          const SizedBox(width: 6),
          _circle(Icons.add_rounded, () => _add(context)),
          const SizedBox(width: 6),
          _circle(Icons.settings_rounded, () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsView()))),
        ]),
      );

  Widget _circle(IconData icon, VoidCallback onTap) => Pressable(
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.06), border: Border.all(color: T.line2)),
          child: Icon(icon, size: 20, color: T.ink),
        ),
      );
}

class HeroCarousel extends StatefulWidget {
  final List<MediaItem> items;
  const HeroCarousel({super.key, required this.items});

  @override
  State<HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<HeroCarousel> {
  final _page = PageController();
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_page.hasClients || widget.items.length < 2) return;
      _page.animateToPage((_index + 1) % widget.items.length, duration: const Duration(milliseconds: 500), curve: Curves.easeInOut);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return Column(children: [
      SizedBox(
        height: isWide(context) ? 420 : 250,
        child: PageView.builder(
          controller: _page,
          itemCount: items.length,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Pressable(onTap: () => AppRouter.shared.open(items, i), child: _card(items[i])),
          ),
        ),
      ),
      const SizedBox(height: 10),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < items.length; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == _index ? 22 : 6,
            height: 6,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              gradient: i == _index ? T.goldGradient : null,
              color: i == _index ? null : Colors.white.withValues(alpha: 0.18),
            ),
          ),
      ]),
    ]);
  }

  Widget _card(MediaItem item) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: T.edge),
          boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 20, offset: Offset(0, 12))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(fit: StackFit.expand, children: [
          RemoteImage(url: item.thumbnailUrl, referer: item.referer, decodeWidth: 1100),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0x33000000), Color(0xD9000000)]),
            ),
          ),
          Positioned(
            left: 18,
            right: 70,
            bottom: 18,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  height: 20,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
                  child: Text(item.siteName.toUpperCase(), style: T.mono(10, color: T.ink, spacing: 1)),
                ),
                const SizedBox(width: 6),
                KindBadge(item: item),
              ]),
              if (item.title.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.display(19, weight: FontWeight.w600, color: Colors.white)),
              ],
            ]),
          ),
          Positioned(
            top: 14,
            right: 14,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: T.goldGradient,
                boxShadow: [BoxShadow(color: T.gold.withValues(alpha: 0.5), blurRadius: 10)],
              ),
              child: Icon(item.kind == MediaKind.video ? Icons.play_arrow_rounded : Icons.open_in_full_rounded, size: 18, color: T.onGold),
            ),
          ),
        ]),
      );
}

class SiteRow extends StatelessWidget {
  final Site site;
  const SiteRow({super.key, required this.site});

  @override
  Widget build(BuildContext context) {
    final engine = FeedEngine.shared;
    final all = engine.homeItems(site);
    final items = all.take(20).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          SiteIcon(site: site, size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: SectionHeader(
                title: site.name, subtitle: site.host.toUpperCase(), actionTitle: 'All', onAction: () => AppRouter.shared.openSite(site.id)),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      if (site.categories.isNotEmpty) ...[
        CategoryRow(site: site, categories: site.categories.take(20).toList()),
        if (items.isNotEmpty) const SizedBox(height: 10),
      ],
      if (items.isEmpty && site.categories.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: engine.isLoading(site)
              ? const SizedBox(height: 150, child: Shimmer(radius: 18))
              : SizedBox(
                  height: 60,
                  child: Center(child: Text(engine.error(site) ?? 'No content', style: T.text(13, color: T.muted), textAlign: TextAlign.center)),
                ),
        )
      else if (items.isNotEmpty)
        SizedBox(
          height: 198,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final item = items[i];
              final a = item.kind == MediaKind.video ? 16 / 11 : 4 / 5;
              return Pressable(
                onTap: () => AppRouter.shared.open(all, i),
                onLongPress: () => showMediaActions(context, item),
                child: SizedBox(width: 190 * a, height: 190, child: MediaCard(item: item, aspect: a)),
              );
            },
          ),
        ),
    ]);
  }
}
