import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../core/feed_engine.dart';
import '../core/models.dart';
import '../core/stores.dart';
import '../ui/media_widgets.dart';
import '../ui/router.dart';
import '../ui/theme.dart';

class SearchView extends StatefulWidget {
  const SearchView({super.key});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final _controller = TextEditingController();
  bool _remote = false;
  MediaKind? _filter;
  List<MediaItem> _remoteResults = [];
  bool _searching = false;
  String _lastRemote = '';

  String get _q => _controller.text.trim();

  List<MediaItem> get _local {
    final q = _q.toLowerCase();
    if (q.isEmpty) return [];
    final seen = <String>{};
    final pool = [...FeedEngine.shared.allCachedItems(), ...Library.shared.favorites, ...Library.shared.history.map((e) => e.item)];
    return pool.where((i) {
      if (!seen.add(i.id) || i.isListing) return false;
      if (_filter != null && i.kind != _filter) return false;
      return i.title.toLowerCase().contains(q) ||
          i.siteName.toLowerCase().contains(q) ||
          (i.categoryName?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  List<(Site, SiteCategory)> get _categories {
    final q = _q.toLowerCase();
    final out = <(Site, SiteCategory)>[];
    for (final s in SiteStore.shared.enabledSites) {
      for (final c in s.categories) {
        if (q.isEmpty || c.name.toLowerCase().contains(q)) out.add((s, c));
      }
    }
    return out.take(q.isEmpty ? 30 : 60).toList();
  }

  Future<void> _submit() async {
    AppSettings.shared.addRecentSearch(_q);
    if (!_remote || _q.isEmpty) return setState(() {});
    final q = _q;
    setState(() {
      _lastRemote = q;
      _searching = true;
      _remoteResults = [];
    });
    final r = await FeedEngine.shared.remoteSearch(q);
    if (!mounted || q != _lastRemote) return;
    setState(() {
      _remoteResults = Blocklist.filter(r);
      _searching = false;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Search', style: T.display(32)),
                const SizedBox(height: 12),
                TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _submit(),
                  onChanged: (_) => setState(() {}),
                  style: T.text(15, color: T.ink),
                  decoration: InputDecoration(
                    hintText: 'Images, GIFs, videos, categories…',
                    prefixIcon: const Icon(Icons.search_rounded, color: T.muted),
                    suffixIcon: _q.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close_rounded, color: T.muted),
                            onPressed: () => setState(_controller.clear),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('In app')),
                    ButtonSegment(value: true, label: Text('On sites')),
                  ],
                  selected: {_remote},
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.selected) ? T.gold : Colors.white.withValues(alpha: 0.05),
                    ),
                    foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? T.onGold : T.body),
                    side: const WidgetStatePropertyAll(BorderSide(color: T.line)),
                  ),
                  onSelectionChanged: (s) {
                    setState(() => _remote = s.first);
                    if (_remote && _q.isNotEmpty && _q != _lastRemote) _submit();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: KindFilterBar(filter: _filter, onChanged: (k) => setState(() => _filter = k)),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 16)),
    ];

    if (_q.isEmpty) {
      final recent = AppSettings.shared.recentSearches;
      if (recent.isNotEmpty) {
        slivers.add(
          _box(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeader(
                  title: 'Recent',
                  actionTitle: 'Clear',
                  onAction: () => setState(() => AppSettings.shared.recentSearches = []),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in recent)
                      Chip2(
                        title: s,
                        icon: Icons.history_rounded,
                        selected: false,
                        onTap: () {
                          _controller.text = s;
                          _submit();
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      }
      if (_categories.isNotEmpty) {
        slivers.add(_box(_categoryChips()));
      } else if (SiteStore.shared.sites.isEmpty) {
        slivers.add(
          _box(const EmptyState(icon: Icons.search_rounded, title: 'Search', message: 'Add sites in Settings to search their content.')),
        );
      }
    } else if (!_remote) {
      if (_categories.isNotEmpty) slivers.add(_box(_categoryChips()));
      slivers.addAll(_results(_local, 'No results in saved content. Try "On sites".'));
    } else {
      if (_searching) {
        slivers.add(
          _box(
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text('Searching ${SiteStore.shared.enabledSites.length} sites…', style: T.text(14)),
              ],
            ),
          ),
        );
      }
      final r = _filter == null ? _remoteResults : _remoteResults.where((e) => e.kind == _filter).toList();
      if (!_searching || r.isNotEmpty) {
        slivers.addAll(_results(r, _lastRemote.isEmpty ? 'Press Search on the keyboard.' : 'The sites returned no results.'));
      }
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 110)));
    return SkyScaffold(
      body: CustomScrollView(
        scrollCacheExtent: const ScrollCacheExtent.pixels(900),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: slivers,
      ),
    );
  }

  Widget _box(Widget w) => SliverPadding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
    sliver: SliverToBoxAdapter(child: w),
  );

  List<Widget> _results(List<MediaItem> items, String empty) {
    if (items.isEmpty) {
      return [
        _box(
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              empty,
              style: T.text(14, color: T.muted),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ];
    }
    return [
      _box(SectionHeader(title: 'Results', subtitle: '${items.length} items')),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverMediaGrid(items: items),
      ),
    ];
  }

  Widget _categoryChips() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SectionHeader(title: 'Categories', subtitle: 'from all sites'),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (s, c) in _categories)
            Pressable(
              onTap: () => AppRouter.shared.openSite(s.id, category: c),
              child: Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(17),
                  border: Border.all(color: T.line),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      c.name,
                      style: T.text(13, weight: FontWeight.w500, color: T.ink),
                    ),
                    const SizedBox(width: 6),
                    Text(s.name, style: T.mono(9)),
                  ],
                ),
              ),
            ),
        ],
      ),
    ],
  );
}
