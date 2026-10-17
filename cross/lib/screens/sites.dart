import 'package:flutter/material.dart';

import '../core/downloads.dart';
import '../core/extras.dart';
import '../core/feed_engine.dart';
import '../core/models.dart';
import '../core/stores.dart';
import '../ui/remote_image.dart';
import '../ui/router.dart';
import '../ui/theme.dart';
import 'forums.dart';
import 'settings.dart';

class SitesView extends StatelessWidget {
  const SitesView({super.key});

  /// 0 = sites, 1 = forums; kept for the session.
  static final section = ValueNotifier<int>(0);

  Widget _segment(String label, int index) => Expanded(
    child: Pressable(
      onTap: () => section.value = index,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: section.value == index ? T.gold : Colors.transparent, borderRadius: BorderRadius.circular(18)),
        child: Text(
          label,
          style: T.text(14, weight: FontWeight.w600, color: section.value == index ? T.onGold : T.ink),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([FeedEngine.shared, SiteStore.shared, section]),
    builder: (context, _) {
      final store = SiteStore.shared;
      final forums = section.value == 1;
      final cols = MediaQuery.sizeOf(context).width >= 900 ? 3 : (MediaQuery.sizeOf(context).width >= 600 ? 2 : 1);
      return SkyScaffold(
        body: RefreshIndicator(
          color: T.gold,
          onRefresh: FeedEngine.shared.refreshAll,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('SITES', style: T.mono(11, spacing: 1.2)),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text('${store.sites.length}', style: T.dot(34)),
                                  const SizedBox(width: 6),
                                  Text('/ ${Limits.maxSites}', style: T.mono(14)),
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (!forums)
                          GoldButton(
                            label: 'Add',
                            icon: Icons.add_rounded,
                            onPressed: store.canAdd
                                ? () =>
                                      Navigator.of(context)
                                          .push(MaterialPageRoute<void>(builder: (_) => const AddSiteView(), fullscreenDialog: true))
                                : null,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                sliver: SliverToBoxAdapter(
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(21),
                      border: Border.all(color: T.line2),
                    ),
                    child: Row(children: [_segment('Sites', 0), _segment('Forums', 1)]),
                  ),
                ),
              ),
              if (forums)
                const SliverToBoxAdapter(child: ForumsSection())
              else if (store.sites.isEmpty)
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
                      crossAxisCount: cols,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      mainAxisExtent: 186,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => Pressable(
                        onTap: () => AppRouter.shared.openSite(store.sites[i].id),
                        onLongPress: () => watchMenu(context, store.sites[i].id, store.sites[i].name, forum: false),
                        child: GestureDetector(
                          onSecondaryTap: () => watchMenu(context, store.sites[i].id, store.sites[i].name, forum: false),
                          child: SiteCard(site: store.sites[i]),
                        ),
                      ),
                      childCount: store.sites.length,
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

class SiteCard extends StatelessWidget {
  final Site site;
  const SiteCard({super.key, required this.site});

  @override
  Widget build(BuildContext context) {
    final engine = FeedEngine.shared;
    final items = engine.homeItems(site);
    // Up to four thumbnails: latest items first, then category covers.
    final previews = [
      ...items.map((e) => e.thumbnailUrl).whereType<Uri>(),
      ...site.categories.map((c) => c.thumbnailUrl).whereType<Uri>(),
    ].take(4).toList();
    return GlassCard(
      radius: 22,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SiteIcon(site: site, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      site.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.display(17, weight: FontWeight.w600),
                    ),
                    Text(site.host, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (engine.isLoading(site))
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              else if (!site.enabled)
                Text('DISABLED', style: T.mono(9))
              else
                const Icon(Icons.chevron_right_rounded, color: T.muted),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 64,
            child: previews.isEmpty
                ? const Shimmer(radius: 10)
                : Row(
                    children: [
                      for (var i = 0; i < previews.length; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: RemoteImage(url: previews[i], referer: site.url, decodeWidth: 160),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
          const Spacer(),
          Row(
            children: [
              _stat(Icons.layers_rounded, '${items.length}'),
              const SizedBox(width: 14),
              _stat(Icons.folder_rounded, '${site.categories.length} cat.'),
              const Spacer(),
              if (site.lastRefreshed != null)
                Flexible(
                  child: Text(relativeTime(site.lastRefreshed!), style: T.mono(10), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(IconData icon, String text) => Row(
    children: [
      Icon(icon, size: 12, color: T.gold),
      const SizedBox(width: 5),
      Text(text, style: T.mono(11, color: T.body)),
    ],
  );
}

/// Turns new-content alerts on or off for one site or forum.
Future<void> watchMenu(BuildContext context, String id, String name, {required bool forum}) async {
  final s = AppSettings.shared;
  final on = s.notifyNew && (forum ? s.watchedForums : s.watchedSites).contains(id);
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: T.navy,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Text(name, style: T.display(15, weight: FontWeight.w600)),
          ),
          ListTile(
            leading: Icon(on ? Icons.notifications_off_rounded : Icons.notifications_active_rounded, color: T.gold),
            title: Text(on ? 'Stop new-content alerts' : 'Alert me about new content', style: T.text(15, color: T.ink)),
            onTap: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return;
  if (on) {
    s.toggleWatch(id, forum: forum);
    return;
  }
  if (!(forum ? s.watchedForums : s.watchedSites).contains(id)) s.toggleWatch(id, forum: forum);
  s.notifyNew = true;
  final allowed = await NewContentWatcher.requestPermission();
  await NewContentWatcher.start();
  await NewContentWatcher.check();
  DownloadManager.shared.show(allowed ? "You'll be told about new content" : 'Allow notifications for iNUTT', success: allowed);
}
