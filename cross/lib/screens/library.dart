import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/stores.dart';
import '../ui/media_widgets.dart';
import '../ui/remote_image.dart';
import '../ui/router.dart';
import '../ui/theme.dart';

class FavoritesView extends StatefulWidget {
  const FavoritesView({super.key});

  @override
  State<FavoritesView> createState() => _FavoritesViewState();
}

class _FavoritesViewState extends State<FavoritesView> {
  MediaKind? _filter;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Library.shared,
        builder: (context, _) {
          final favs = Library.shared.favorites;
          final items = _filter == null ? favs : favs.where((e) => e.kind == _filter).toList();
          return SkyScaffold(
            body: CustomScrollView(slivers: [
              SliverToBoxAdapter(
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('FAVORITES', style: T.mono(11, spacing: 1.2)),
                      Text('${favs.length}', style: T.dot(34)),
                    ]),
                  ),
                ),
              ),
              SliverToBoxAdapter(child: KindFilterBar(filter: _filter, onChanged: (k) => setState(() => _filter = k))),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
              if (items.isEmpty)
                const SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverToBoxAdapter(
                    child: EmptyState(
                        icon: Icons.favorite_border_rounded, title: 'No favorites yet', message: 'Tap the heart in the viewer or long-press a card.'),
                  ),
                )
              else
                SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 16), sliver: SliverMediaGrid(items: items)),
              const SliverToBoxAdapter(child: SizedBox(height: 110)),
            ]),
          );
        },
      );
}

class HistoryView extends StatefulWidget {
  const HistoryView({super.key});

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  String _q = '';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Library.shared,
        builder: (context, _) {
          final q = _q.toLowerCase();
          final entries = Library.shared.history
              .where((e) => q.isEmpty || e.item.title.toLowerCase().contains(q) || e.item.siteName.toLowerCase().contains(q))
              .toList();
          // Group by day.
          final groups = <String, List<HistoryEntry>>{};
          for (final e in entries) {
            groups.putIfAbsent(_day(e.viewedAt), () => []).add(e);
          }
          final all = entries.map((e) => e.item).toList();
          return SkyScaffold(
            appBar: AppBar(
              title: const Text('History'),
              actions: [
                if (Library.shared.history.isNotEmpty)
                  TextButton(
                    onPressed: () => _confirmClear(context),
                    child: Text('Clear', style: T.text(15, weight: FontWeight.w500, color: T.err)),
                  ),
              ],
            ),
            body: CustomScrollView(slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                sliver: SliverToBoxAdapter(
                  child: TextField(
                    onChanged: (v) => setState(() => _q = v),
                    style: T.text(15, color: T.ink),
                    decoration: const InputDecoration(hintText: 'Search history', prefixIcon: Icon(Icons.search_rounded, color: T.muted)),
                  ),
                ),
              ),
              if (!AppSettings.shared.historyEnabled)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverToBoxAdapter(child: Text('History is turned off in Settings.', style: T.text(13, color: T.muted))),
                ),
              if (entries.isEmpty)
                const SliverPadding(
                  padding: EdgeInsets.all(16),
                  sliver: SliverToBoxAdapter(
                    child: EmptyState(icon: Icons.history_rounded, title: 'No history', message: 'What you open shows up here.'),
                  ),
                ),
              for (final g in groups.entries) ...[
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  sliver: SliverToBoxAdapter(child: Text(g.key.toUpperCase(), style: T.mono(11, spacing: 1))),
                ),
                SliverList.builder(
                  itemCount: g.value.length,
                  itemBuilder: (context, i) {
                    final e = g.value[i];
                    return Dismissible(
                      key: ValueKey(e.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: T.err.withValues(alpha: 0.25),
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        child: const Icon(Icons.delete_rounded, color: T.err),
                      ),
                      onDismissed: (_) => Library.shared.removeHistory({e.id}),
                      child: InkWell(
                        onTap: () => AppRouter.shared.open(all, all.indexOf(e.item)),
                        child: HistoryRow(entry: e),
                      ),
                    );
                  },
                ),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 110)),
            ]),
          );
        },
      );

  String _day(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  void _confirmClear(BuildContext context) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: T.navy,
          title: Text('Clear history?', style: T.display(18)),
          content: Text('This removes everything you have viewed.', style: T.text(14)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                Library.shared.clearHistory();
                Navigator.pop(ctx);
              },
              child: Text('Clear', style: T.text(14, weight: FontWeight.w600, color: T.err)),
            ),
          ],
        ),
      );
}

class HistoryRow extends StatelessWidget {
  final HistoryEntry entry;
  const HistoryRow({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final t = entry.viewedAt;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(width: 64, height: 64, child: RemoteImage(url: entry.item.thumbnailUrl, referer: entry.item.referer, decodeWidth: 140)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(entry.item.displayTitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.text(14, weight: FontWeight.w500, color: T.ink)),
            const SizedBox(height: 4),
            Text('${entry.item.siteName} · ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11)),
          ]),
        ),
        const SizedBox(width: 8),
        KindBadge(item: entry.item),
      ]),
    );
  }
}
