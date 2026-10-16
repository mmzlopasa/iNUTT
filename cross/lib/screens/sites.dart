import 'package:flutter/material.dart';

import '../core/feed_engine.dart';
import '../core/models.dart';
import '../core/stores.dart';
import '../ui/remote_image.dart';
import '../ui/router.dart';
import '../ui/theme.dart';
import 'settings.dart';

class SitesView extends StatelessWidget {
  const SitesView({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([FeedEngine.shared, SiteStore.shared]),
        builder: (context, _) {
          final store = SiteStore.shared;
          final cols = MediaQuery.sizeOf(context).width >= 900 ? 3 : (MediaQuery.sizeOf(context).width >= 600 ? 2 : 1);
          return SkyScaffold(
            body: RefreshIndicator(
              color: T.gold,
              onRefresh: FeedEngine.shared.refreshAll,
              child: CustomScrollView(slivers: [
                SliverToBoxAdapter(
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('SITES', style: T.mono(11, spacing: 1.2)),
                            Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                              Text('${store.sites.length}', style: T.dot(34)),
                              const SizedBox(width: 6),
                              Text('/ ${Limits.maxSites}', style: T.mono(14)),
                            ]),
                          ]),
                        ),
                        GoldButton(
                          label: 'Add',
                          icon: Icons.add_rounded,
                          onPressed: store.canAdd
                              ? () => Navigator.of(context)
                                  .push(MaterialPageRoute<void>(builder: (_) => const AddSiteView(), fullscreenDialog: true))
                              : null,
                        ),
                      ]),
                    ),
                  ),
                ),
                if (store.sites.isEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverToBoxAdapter(
                      child: EmptyState(
                        icon: Icons.public_rounded,
                        title: 'No sites',
                        message: 'Add up to 50 sites. iNUTT finds images, GIFs, videos and categories automatically.',
                        buttonTitle: 'Add site',
                        onButton: () =>
                            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AddSiteView(), fullscreenDialog: true)),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols, mainAxisSpacing: 12, crossAxisSpacing: 12, mainAxisExtent: 186),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => Pressable(
                            onTap: () => AppRouter.shared.openSite(store.sites[i].id), child: SiteCard(site: store.sites[i])),
                        childCount: store.sites.length,
                      ),
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 110)),
              ]),
            ),
          );
        },
      );
}

class SiteCard extends StatelessWidget {
  final Site site;
  const SiteCard({super.key, required this.site});

  @override
  Widget build(BuildContext context) {
    final engine = FeedEngine.shared;
    final items = engine.items(site);
    // Up to four thumbnails: latest items first, then category covers.
    final previews = [
      ...items.map((e) => e.thumbnailUrl).whereType<Uri>(),
      ...site.categories.map((c) => c.thumbnailUrl).whereType<Uri>(),
    ].take(4).toList();
    return GlassCard(
      radius: 22,
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SiteIcon(site: site, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(site.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.display(17, weight: FontWeight.w600)),
              Text(site.host, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11)),
            ]),
          ),
          const SizedBox(width: 8),
          if (engine.isLoading(site))
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          else if (!site.enabled)
            Text('DISABLED', style: T.mono(9))
          else
            const Icon(Icons.chevron_right_rounded, color: T.muted),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          height: 64,
          child: previews.isEmpty
              ? const Shimmer(radius: 10)
              : Row(children: [
                  for (var i = 0; i < previews.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: RemoteImage(url: previews[i], referer: site.url, decodeWidth: 160),
                      ),
                    ),
                  ],
                ]),
        ),
        const Spacer(),
        Row(children: [
          _stat(Icons.layers_rounded, '${items.length}'),
          const SizedBox(width: 14),
          _stat(Icons.folder_rounded, '${site.categories.length} cat.'),
          const Spacer(),
          if (site.lastRefreshed != null) Flexible(child: Text(relativeTime(site.lastRefreshed!), style: T.mono(10), maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
      ]),
    );
  }

  Widget _stat(IconData icon, String text) => Row(children: [
        Icon(icon, size: 12, color: T.gold),
        const SizedBox(width: 5),
        Text(text, style: T.mono(11, color: T.body)),
      ]);
}
