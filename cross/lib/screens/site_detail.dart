import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../core/downloads.dart';
import '../core/feed_engine.dart';
import '../core/models.dart';
import '../core/stores.dart';
import '../ui/media_widgets.dart';
import '../ui/remote_image.dart';
import '../ui/router.dart';
import '../ui/theme.dart';
import 'settings.dart';

final _all = Listenable.merge([FeedEngine.shared, SiteStore.shared, Library.shared.favoritesVersion]);

/// Resolves a navigation route to a site page or one of its categories.
class SiteRouteView extends StatelessWidget {
  final String siteId;
  final SiteCategory? category;
  final bool allCategories;
  const SiteRouteView({super.key, required this.siteId, this.category, this.allCategories = false});

  @override
  Widget build(BuildContext context) {
    final site = SiteStore.shared.site(siteId);
    if (site == null) {
      return SkyScaffold(
        appBar: AppBar(),
        body: const Padding(
          padding: EdgeInsets.all(16),
          child: EmptyState(icon: Icons.help_outline, title: 'Site not found', message: 'This site was removed.'),
        ),
      );
    }
    if (allCategories) return CategoryIndexView(site: site);
    if (category != null) return CategoryView(site: site, category: category!);
    return SiteDetailView(site: site);
  }
}

class SiteDetailView extends StatefulWidget {
  final Site site;
  const SiteDetailView({super.key, required this.site});

  @override
  State<SiteDetailView> createState() => _SiteDetailViewState();
}

class _SiteDetailViewState extends State<SiteDetailView> {
  MediaKind? _filter;

  @override
  void initState() {
    super.initState();
    final e = FeedEngine.shared;
    if (e.homeItems(widget.site).isEmpty) e.refreshForHome(widget.site);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _all,
    builder: (context, _) {
      final site = SiteStore.shared.site(widget.site.id) ?? widget.site;
      final engine = FeedEngine.shared;
      final all = engine.homeItems(site);
      final items = _filter == null ? all : all.where((e) => e.kind == _filter).toList();
      final cats = site.categories;
      return SkyScaffold(
        appBar: AppBar(
          title: Text(site.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              icon: const Icon(Icons.tune_rounded),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditSiteView(site: site))),
            ),
          ],
        ),
        body: RefreshIndicator(
          color: T.gold,
          onRefresh: () => engine.refreshForHome(site),
          child: CustomScrollView(
            scrollCacheExtent: const ScrollCacheExtent.pixels(900),
            slivers: [
              SliverToBoxAdapter(
                child: SiteHeader(site: site, subtitle: site.host),
              ),
              if (cats.isNotEmpty && all.isEmpty) ...[
                // A site whose page is a category index: show the categories as the main content.
                _pad(SectionHeader(title: 'Categories', subtitle: '${cats.length} categories')),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverCategoryGrid(site: site, categories: cats),
                ),
              ] else if (cats.isNotEmpty) ...[
                _pad(
                  SectionHeader(
                    title: 'Categories',
                    subtitle: '${cats.length} categories',
                    actionTitle: 'See all',
                    onAction: () => AppRouter.shared.openSite(site.id, allCategories: true),
                  ),
                ),
                SliverToBoxAdapter(
                  child: CategoryRow(site: site, categories: cats.take(30).toList()),
                ),
              ],
              if (all.isNotEmpty) ...[
                _pad(SectionHeader(title: 'Latest', subtitle: '${all.length} items')),
                SliverToBoxAdapter(
                  child: KindFilterBar(filter: _filter, onChanged: (k) => setState(() => _filter = k)),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverMediaGrid(items: items, onReachEnd: () => engine.loadMore(site, null)),
                ),
                if (engine.isLoading(site)) const SliverToBoxAdapter(child: _Spinner()),
              ] else if (cats.isEmpty)
                if (engine.isLoading(site))
                  const SliverPadding(padding: EdgeInsets.symmetric(horizontal: 16), sliver: LoadingGrid())
                else
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: EmptyState(
                        icon: Icons.inbox_outlined,
                        title: 'No content',
                        message: engine.error(site) ?? 'Try refreshing, or switch the site to "Full (JavaScript)" mode in its settings.',
                        buttonTitle: 'Refresh',
                        onButton: () => engine.refresh(site, null),
                      ),
                    ),
                  ),
              const SliverToBoxAdapter(child: SizedBox(height: 110)),
            ],
          ),
        ),
      );
    },
  );
}

Widget _pad(Widget w) => SliverPadding(
  padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
  sliver: SliverToBoxAdapter(child: w),
);

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(20),
    child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
  );
}

/// Content of one category, in the same 2-column (phone) / 5-column (tablet, desktop) grid.
class CategoryView extends StatefulWidget {
  final Site site;
  final SiteCategory category;
  const CategoryView({super.key, required this.site, required this.category});

  @override
  State<CategoryView> createState() => _CategoryViewState();
}

class _CategoryViewState extends State<CategoryView> {
  MediaKind? _filter;
  bool _didLoad = false;

  @override
  void initState() {
    super.initState();
    final e = FeedEngine.shared;
    if (e.items(widget.site, widget.category).isEmpty) {
      e.refresh(widget.site, widget.category).whenComplete(() {
        if (mounted) setState(() => _didLoad = true);
      });
    } else {
      _didLoad = true;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _all,
    builder: (context, _) {
      final site = SiteStore.shared.site(widget.site.id) ?? widget.site;
      final c = widget.category;
      final engine = FeedEngine.shared;
      final all = engine.items(site, c);
      final items = _filter == null ? all : all.where((e) => e.kind == _filter).toList();
      return SkyScaffold(
        appBar: AppBar(
          title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'Download all',
              icon: const Icon(Icons.download_rounded),
              onPressed: items.isEmpty ? null : () => DownloadManager.shared.downloadAll(items),
            ),
          ],
        ),
        body: RefreshIndicator(
          color: T.gold,
          onRefresh: () => engine.refresh(site, c),
          child: CustomScrollView(
            scrollCacheExtent: const ScrollCacheExtent.pixels(900),
            slivers: [
              SliverToBoxAdapter(
                child: SiteHeader(site: site, subtitle: c.name, title: c.name, caption: site.name),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 14)),
              SliverToBoxAdapter(
                child: KindFilterBar(filter: _filter, onChanged: (k) => setState(() => _filter = k)),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 14)),
              if (items.isEmpty)
                if (engine.isLoading(site, c) || !_didLoad)
                  const SliverPadding(padding: EdgeInsets.symmetric(horizontal: 16), sliver: LoadingGrid())
                else
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: EmptyState(
                        icon: Icons.inbox_outlined,
                        title: 'No content',
                        message: engine.error(site, c) ?? 'This category is empty or needs "Full (JavaScript)" mode.',
                        buttonTitle: 'Refresh',
                        onButton: () => engine.refresh(site, c),
                      ),
                    ),
                  )
              else ...[
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverMediaGrid(items: items, onReachEnd: () => engine.loadMore(site, c)),
                ),
                if (engine.isLoading(site, c)) const SliverToBoxAdapter(child: _Spinner()),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 110)),
            ],
          ),
        ),
      );
    },
  );
}

/// Every category of a site, searchable.
class CategoryIndexView extends StatefulWidget {
  final Site site;
  const CategoryIndexView({super.key, required this.site});

  @override
  State<CategoryIndexView> createState() => _CategoryIndexViewState();
}

class _CategoryIndexViewState extends State<CategoryIndexView> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final cats = widget.site.categories.where((c) => _q.isEmpty || c.name.toLowerCase().contains(_q.toLowerCase())).toList();
    return SkyScaffold(
      appBar: AppBar(title: const Text('Categories')),
      body: CustomScrollView(
        scrollCacheExtent: const ScrollCacheExtent.pixels(900),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            sliver: SliverToBoxAdapter(
              child: TextField(
                onChanged: (v) => setState(() => _q = v),
                style: T.text(15, color: T.ink),
                decoration: const InputDecoration(
                  hintText: 'Search categories',
                  prefixIcon: Icon(Icons.search_rounded, color: T.muted),
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverCategoryGrid(site: widget.site, categories: cats),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
    );
  }
}

class SiteHeader extends StatelessWidget {
  final Site site;
  final String subtitle;
  final String? title;
  final String? caption;
  const SiteHeader({super.key, required this.site, required this.subtitle, this.title, this.caption});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
    child: Row(
      children: [
        SiteIcon(site: site, size: 52),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (caption != null)
                Text(caption!.toUpperCase(), style: T.mono(10, spacing: 1), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(title ?? site.name, style: T.display(24), maxLines: 2, overflow: TextOverflow.ellipsis),
              if (title == null)
                Text(
                  subtitle,
                  style: T.mono(12, color: T.gold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class SliverCategoryGrid extends StatelessWidget {
  final Site site;
  final List<SiteCategory> categories;
  const SliverCategoryGrid({super.key, required this.site, required this.categories});

  @override
  Widget build(BuildContext context) => SliverGrid(
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: gridColumns(context),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 4 / 3,
    ),
    delegate: SliverChildBuilderDelegate(
      (context, i) => Pressable(
        onTap: () => AppRouter.shared.openSite(site.id, category: categories[i]),
        child: CategoryCard(category: categories[i], referer: site.url),
      ),
      childCount: categories.length,
    ),
  );
}

class CategoryRow extends StatelessWidget {
  final Site site;
  final List<SiteCategory> categories;
  const CategoryRow({super.key, required this.site, required this.categories});

  @override
  Widget build(BuildContext context) {
    final withThumbs = categories.any((c) => c.thumbnailUrl != null);
    return SizedBox(
      height: withThumbs ? 112 : 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final c = categories[i];
          return Pressable(
            onTap: () => AppRouter.shared.openSite(site.id, category: c),
            child: withThumbs
                ? SizedBox(
                    width: 150,
                    child: CategoryCard(category: c, referer: site.url),
                  )
                : Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: T.line),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.folder_rounded, size: 13, color: T.gold),
                        const SizedBox(width: 6),
                        Text(
                          c.name,
                          style: T.text(13, weight: FontWeight.w500, color: T.ink),
                        ),
                      ],
                    ),
                  ),
          );
        },
      ),
    );
  }
}

class CategoryCard extends StatelessWidget {
  final SiteCategory category;
  final Uri? referer;
  const CategoryCard({super.key, required this.category, this.referer});

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: T.edge, width: 0.6),
    ),
    clipBehavior: Clip.antiAlias,
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (category.thumbnailUrl != null)
          RemoteImage(url: category.thumbnailUrl, referer: referer, decodeWidth: 360)
        else
          const DecoratedBox(
            decoration: BoxDecoration(
              color: T.navy2,
              gradient: RadialGradient(center: Alignment.topRight, radius: 1.2, colors: [Color(0x2EFFD76A), Color(0x001A1D25)]),
            ),
            child: Center(child: Icon(Icons.folder_rounded, size: 28, color: Color(0xCCFFD76A))),
          ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0.45, 1],
              colors: [Colors.transparent, Color(0xCC000000)],
            ),
          ),
        ),
        Positioned(
          left: 10,
          right: 10,
          bottom: 9,
          child: Text(
            category.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: T.display(14, weight: FontWeight.w600, color: Colors.white),
          ),
        ),
      ],
    ),
  );
}
