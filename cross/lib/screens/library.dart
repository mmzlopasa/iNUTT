import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/downloads.dart';
import '../core/extras.dart';

import '../core/models.dart';
import '../core/stores.dart';
import '../core/vault.dart';
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

  /// null shows every favorite; otherwise one of your collections.
  String? _selected;

  /// The Watch later queue instead of favorites.
  bool _later = false;

  Future<void> _favoritesMenu() async {
    final on = AppSettings.shared.offlineFavorites;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: T.navy,
      builder: (ctx) => SafeArea(
        child: ListTile(
          leading: Icon(on ? Icons.cloud_off_rounded : Icons.download_for_offline_rounded, color: T.gold),
          title: Text(on ? "Don't keep offline" : 'Keep offline (Wi-Fi)', style: T.text(15, color: T.ink)),
          onTap: () => Navigator.pop(ctx, true),
        ),
      ),
    );
    if (ok != true) return;
    AppSettings.shared.offlineFavorites = !on;
    OfflineStore.shared.sync();
    setState(() {});
  }

  Future<void> _collectionMenu(MediaCollection c) async {
    final action = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: T.navy,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_rounded, color: T.gold),
              title: Text('Rename', style: T.text(15, color: T.ink)),
              onTap: () => Navigator.pop(ctx, 0),
            ),
            ListTile(
              leading: Icon(
                OfflineStore.shared.isOfflineCollection(c.id) ? Icons.cloud_off_rounded : Icons.download_for_offline_rounded,
                color: T.gold,
              ),
              title: Text(
                OfflineStore.shared.isOfflineCollection(c.id) ? "Don't keep offline" : 'Keep offline (Wi-Fi)',
                style: T.text(15, color: T.ink),
              ),
              onTap: () => Navigator.pop(ctx, 2),
            ),
            ListTile(
              leading: const Icon(Icons.delete_rounded, color: T.err),
              title: Text('Delete collection', style: T.text(15, color: T.err)),
              subtitle: Text('The items stay in Favorites and on their sites.', style: T.text(12, color: T.muted)),
              onTap: () => Navigator.pop(ctx, 1),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 2) {
      OfflineStore.shared.toggleCollection(c.id);
      setState(() {});
    } else if (action == 0) {
      final n = await askName(context, 'Rename collection', initial: c.name);
      if (n != null) CollectionStore.shared.rename(c.id, n);
    } else {
      if (_selected == c.id) setState(() => _selected = null);
      CollectionStore.shared.delete(c.id);
    }
  }

  Widget _circle(IconData icon, VoidCallback onTap) => Pressable(
    onTap: onTap,
    child: Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.07),
        border: Border.all(color: T.line2),
      ),
      child: Icon(icon, size: 19, color: T.ink),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([Library.shared, CollectionStore.shared, WatchLater.shared]),
    builder: (context, _) {
      final cols = CollectionStore.shared.collections;
      final current = _later ? null : cols.where((c) => c.id == _selected).firstOrNull;
      final source = _later ? WatchLater.shared.items : (current?.items ?? Library.shared.favorites);
      final items = _filter == null ? source : source.where((e) => e.kind == _filter).toList();
      return SkyScaffold(
        body: CustomScrollView(
          scrollCacheExtent: const ScrollCacheExtent.pixels(900),
          slivers: [
            SliverToBoxAdapter(
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_later ? 'WATCH LATER' : (current == null ? 'FAVORITES' : 'COLLECTION'), style: T.mono(11, spacing: 1.2)),
                            Text('${source.length}', style: T.dot(34)),
                          ],
                        ),
                      ),
                      if (items.isNotEmpty) ...[
                        _circle(Icons.download_rounded, () => DownloadManager.shared.downloadAll(items)),
                        const SizedBox(width: 8),
                      ],
                      _circle(
                        Icons.shield_rounded,
                        () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VaultView())),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    GestureDetector(
                      onLongPress: _favoritesMenu,
                      onSecondaryTap: _favoritesMenu,
                      child: Chip2(
                        title: 'All favorites',
                        icon: AppSettings.shared.offlineFavorites ? Icons.download_done_rounded : Icons.favorite_rounded,
                        selected: current == null && !_later,
                        onTap: () => setState(() {
                          _selected = null;
                          _later = false;
                        }),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Chip2(
                      title: 'Watch later · ${WatchLater.shared.items.length}',
                      icon: Icons.watch_later_rounded,
                      selected: _later,
                      onTap: () => setState(() => _later = true),
                    ),
                    for (final c in cols) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        onLongPress: () => _collectionMenu(c),
                        onSecondaryTap: () => _collectionMenu(c),
                        child: Chip2(
                          title: '${c.name} · ${c.items.length}',
                          icon: OfflineStore.shared.isOfflineCollection(c.id) ? Icons.download_done_rounded : Icons.folder_rounded,
                          selected: current?.id == c.id,
                          onTap: () => setState(() {
                            _selected = c.id;
                            _later = false;
                          }),
                        ),
                      ),
                    ],
                    const SizedBox(width: 8),
                    Chip2(
                      title: 'New',
                      icon: Icons.add_rounded,
                      selected: false,
                      onTap: () async {
                        final n = await askName(context, 'New collection');
                        final c = n == null ? null : CollectionStore.shared.create(n);
                        if (c != null) setState(() => _selected = c.id);
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            SliverToBoxAdapter(
              child: KindFilterBar(filter: _filter, onChanged: (k) => setState(() => _filter = k)),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
            if (items.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverToBoxAdapter(
                  child: _later
                      ? const EmptyState(
                          icon: Icons.watch_later_outlined,
                          title: 'Nothing in Watch later',
                          message: 'Tap Later in the viewer or long-press a card. Items leave the queue once you have watched them.',
                        )
                      : current == null
                      ? const EmptyState(
                          icon: Icons.favorite_border_rounded,
                          title: 'No favorites yet',
                          message: 'Tap the heart in the viewer or long-press a card.',
                        )
                      : const EmptyState(
                          icon: Icons.folder_open_rounded,
                          title: 'This collection is empty',
                          message: 'Add items with Collect in the viewer or by long-pressing a card.',
                        ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverMediaGrid(items: items),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 110)),
          ],
        ),
      );
    },
  );
}

/// Encrypted downloads. Opened files are decrypted to a temporary copy that is wiped on close.
class VaultView extends StatefulWidget {
  const VaultView({super.key});

  @override
  State<VaultView> createState() => _VaultViewState();
}

class _VaultViewState extends State<VaultView> {
  String? _opening;

  @override
  void dispose() {
    Vault.shared.closeOpenFiles();
    super.dispose();
  }

  Future<void> _open(VaultEntry e) async {
    if (_opening != null) return;
    setState(() => _opening = e.id);
    try {
      final f = await Vault.shared.open(e);
      if (!mounted) return;
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => _VaultPlayer(entry: e, file: f),
        ),
      );
    } catch (_) {
      DownloadManager.shared.show('Couldn\'t open this file', success: false);
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _confirmDelete(VaultEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.navy,
        title: Text('Delete from the vault?', style: T.display(18)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: T.text(14, color: T.err)),
          ),
        ],
      ),
    );
    if (ok == true) Vault.shared.delete(e);
  }

  String _size(int b) => b > 1 << 30
      ? '${(b / (1 << 30)).toStringAsFixed(1)} GB'
      : (b > 1 << 20 ? '${(b / (1 << 20)).toStringAsFixed(1)} MB' : '${(b / 1024).toStringAsFixed(0)} KB');

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([Vault.shared, AppSettings.shared]),
    builder: (context, _) {
      final v = Vault.shared;
      final cols = MediaQuery.sizeOf(context).width >= 700 ? 5 : 2;
      return SkyScaffold(
        appBar: AppBar(title: const Text('Vault')),
        body: CustomScrollView(
          scrollCacheExtent: const ScrollCacheExtent.pixels(900),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${v.entries.length} files · ${_size(v.totalSize)}', style: T.mono(12)),
                    const SizedBox(height: 12),
                    GlassCard(
                      child: SwitchListTile(
                        value: AppSettings.shared.vaultDownloads,
                        onChanged: (x) => AppSettings.shared.vaultDownloads = x,
                        title: Text(
                          'Download into the vault',
                          style: T.text(15, weight: FontWeight.w500, color: T.ink),
                        ),
                        subtitle: Text('Encrypted, only inside iNUTT. Not in the gallery or Downloads.', style: T.text(12, color: T.muted)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (v.entries.isEmpty)
              const SliverPadding(
                padding: EdgeInsets.all(16),
                sliver: SliverToBoxAdapter(
                  child: EmptyState(
                    icon: Icons.shield_outlined,
                    title: 'The vault is empty',
                    message: 'Turn on "Download into the vault" and every download is stored here, encrypted.',
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
                    childAspectRatio: 0.8,
                  ),
                  delegate: SliverChildBuilderDelegate((context, i) {
                    final e = v.entries[i];
                    return GestureDetector(
                      onLongPress: () => _confirmDelete(e),
                      onSecondaryTap: () => _confirmDelete(e),
                      child: Pressable(
                        onTap: () => _open(e),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              const ColoredBox(color: T.navy),
                              RemoteImage(url: e.thumbnailUrl, decodeWidth: 400),
                              if (_opening == e.id) const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [Colors.transparent, Colors.black87],
                                    ),
                                  ),
                                  child: Text(
                                    e.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: T.text(12, weight: FontWeight.w500, color: Colors.white),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }, childCount: v.entries.length),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 110)),
          ],
        ),
      );
    },
  );
}

class _VaultPlayer extends StatefulWidget {
  final VaultEntry entry;
  final File file;
  const _VaultPlayer({required this.entry, required this.file});

  @override
  State<_VaultPlayer> createState() => _VaultPlayerState();
}

class _VaultPlayerState extends State<_VaultPlayer> {
  Player? _player;
  VideoController? _video;

  @override
  void initState() {
    super.initState();
    if (widget.entry.kind == MediaKind.video) {
      final p = Player();
      _video = VideoController(p);
      _player = p;
      p.open(Media(widget.file.path));
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(
      children: [
        Positioned.fill(
          child: _video != null
              ? Video(controller: _video!)
              : InteractiveViewer(
                  maxScale: 6,
                  child: Center(child: Image.file(widget.file, fit: BoxFit.contain)),
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: IconButton.filledTonal(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
          ),
        ),
      ],
    ),
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
                child: Text(
                  'Clear',
                  style: T.text(15, weight: FontWeight.w500, color: T.err),
                ),
              ),
          ],
        ),
        body: CustomScrollView(
          scrollCacheExtent: const ScrollCacheExtent.pixels(900),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              sliver: SliverToBoxAdapter(
                child: TextField(
                  onChanged: (v) => setState(() => _q = v),
                  style: T.text(15, color: T.ink),
                  decoration: const InputDecoration(
                    hintText: 'Search history',
                    prefixIcon: Icon(Icons.search_rounded, color: T.muted),
                  ),
                ),
              ),
            ),
            if (!AppSettings.shared.historyEnabled)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverToBoxAdapter(
                  child: Text('History is turned off in Settings.', style: T.text(13, color: T.muted)),
                ),
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
          ],
        ),
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
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
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
          child: Text(
            'Clear',
            style: T.text(14, weight: FontWeight.w600, color: T.err),
          ),
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
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 64,
              height: 64,
              child: RemoteImage(url: entry.item.thumbnailUrl, referer: entry.item.referer, decodeWidth: 140),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.item.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: T.text(14, weight: FontWeight.w500, color: T.ink),
                ),
                const SizedBox(height: 4),
                Text(
                  '${entry.item.siteName} · ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.mono(11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          KindBadge(item: entry.item),
        ],
      ),
    );
  }
}
