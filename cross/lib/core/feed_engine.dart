import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'image_cache.dart';
import 'extras.dart';
import 'models.dart';
import 'net.dart';
import 'scraper.dart';
import 'site_adapters.dart';
import 'stores.dart';

/// Loads, caches and refreshes content from every site. Cached feeds are shown instantly on launch.
class FeedEngine extends ChangeNotifier {
  static final FeedEngine shared = FeedEngine._();
  FeedEngine._();

  final Map<String, List<MediaItem>> feeds = {};
  final Set<String> loading = {};
  final Map<String, String> errors = {};
  bool isRefreshingAll = false;
  DateTime? lastRefresh;

  final Map<String, Uri> _nextPages = {};
  final Map<String, ResolvedMedia> _resolved = {};
  final Map<String, DateTime> _resolvedAt = {};
  final Map<String, Future<ResolvedMedia?>> _inflight = {};
  final List<MediaItem> _prefetchQueue = [];
  int _prefetching = 0;

  /// Bumped on every change; Home's lists are computed once per version.
  int _version = 0;
  Timer? _notifyTimer;
  final Map<String, (int, Object, List<MediaItem>)> _homeCache = {};
  (int, String, List<MediaItem>)? _mixedCache;

  /// Per feed: whether its thumbnail tiles turned out to be categories (checked once per launch).
  final Map<String, bool> _listingProbe = {};
  Timer? _saveTimer;

  void load() {
    final raw = Disk.load('feeds.json');
    if (raw is! Map) return;
    (raw['feeds'] as Map? ?? {}).forEach((k, v) {
      feeds[k as String] = (v as List).map((e) => MediaItem.fromJson(e as Map<String, dynamic>)).toList();
    });
    (raw['next'] as Map? ?? {}).forEach((k, v) => _nextPages[k as String] = Uri.parse(v as String));
    final lr = raw['lastRefresh'];
    if (lr is int) lastRefresh = DateTime.fromMillisecondsSinceEpoch(lr);
    // What was opened in the last hours opens again without loading.
    final res = Disk.load('resolved.json');
    if (res is Map) {
      final now = DateTime.now();
      res.forEach((k, v) {
        if (v is! Map) return;
        final at = v['at'];
        final m = ResolvedMedia.fromJson(v['media']);
        if (at is! int || m == null) return;
        final t = DateTime.fromMillisecondsSinceEpoch(at);
        if (now.difference(t) > const Duration(hours: 6)) return;
        _resolved[k as String] = m;
        _resolvedAt[k] = t;
      });
    }
  }

  /// Screens redraw at most five times a second, however many feeds change at once.
  void _changed() {
    _version++;
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 200), notifyListeners);
  }

  static String key(Site site, [SiteCategory? category]) => category == null ? site.id : '${site.id}|${category.url}';

  List<MediaItem> items(Site site, [SiteCategory? category]) => Blocklist.filter(feeds[key(site, category)] ?? const []);

  /// Blocked words changed: lists are worked out again.
  void filtersChanged() => _changed();
  bool isLoading(Site site, [SiteCategory? c]) => loading.contains(key(site, c));
  String? error(Site site, [SiteCategory? c]) => errors[key(site, c)];

  /// Clearly a video, GIF or direct media file rather than a picture linking to another page.
  static bool isMedia(MediaItem i) => i.kind == MediaKind.video || i.kind == MediaKind.gif || i.duration != null || i.mediaUrl != null;

  /// The root page shows (almost) no real media, so its content lives in the categories.
  static bool needsCategoryFeeds(List<MediaItem> root) => root.where(isMedia).length < 6;

  /// What a site contributes to Home and its Latest section: real media, never category covers.
  /// When the site's own page only lists categories, its newest items come from those categories.
  List<MediaItem> homeItems(Site site) {
    final c = _homeCache[site.id];
    if (c != null && c.$1 == _version && identical(c.$2, site.categories)) return c.$3;
    final items = Blocklist.filter(_computeHomeItems(site));
    _homeCache[site.id] = (_version, site.categories, items);
    return items;
  }

  List<MediaItem> _computeHomeItems(Site site) {
    final covers = site.categories.map((c) => c.thumbnailUrl?.toString()).whereType<String>().toSet();
    final root = (feeds[key(site)] ?? const <MediaItem>[])
        .where((i) => !i.isListing && !covers.contains(i.thumbnailUrl?.toString()) && site.categoryMatching(i.pageUrl) == null)
        .toList();
    if (site.categories.isEmpty || !needsCategoryFeeds(root)) return root;
    final lists = site.categories.map((c) => feeds[key(site, c)] ?? const <MediaItem>[]).where((l) => l.isNotEmpty).toList();
    final out = root.where(isMedia).toList();
    if (lists.isEmpty) return out;
    final seen = out.map((e) => e.id).toSet();
    final maxLen = lists.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    for (var i = 0; i < maxLen; i++) {
      for (final l in lists) {
        if (i < l.length && !l[i].isListing && seen.add(l[i].id)) out.add(l[i]);
      }
    }
    return out;
  }

  /// All cached items across enabled sites, interleaved so no site dominates.
  List<MediaItem> mixedFeed(List<Site> sites) {
    final key = sites.map((s) => '${s.id}:${s.categories.length}').join(',');
    final c = _mixedCache;
    if (c != null && c.$1 == _version && c.$2 == key) return c.$3;
    final lists = sites.map(homeItems).toList();
    final out = <MediaItem>[];
    final seen = <String>{};
    final maxLen = lists.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    for (var i = 0; i < maxLen; i++) {
      for (final l in lists) {
        if (i < l.length && !l[i].isListing && seen.add(l[i].id)) out.add(l[i]);
      }
    }
    _mixedCache = (_version, key, out);
    return out;
  }

  List<MediaItem> allCachedItems() {
    final seen = <String>{};
    return Blocklist.filter(feeds.values.expand((e) => e).where((e) => seen.add(e.id)).toList());
  }

  bool get isStale => lastRefresh == null || DateTime.now().difference(lastRefresh!) > const Duration(minutes: 8);

  Future<void> refreshAll() async {
    if (isRefreshingAll) return;
    final sites = SiteStore.shared.enabledSites;
    if (sites.isEmpty) return;
    isRefreshingAll = true;
    _changed();
    final queue = [...sites];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        await refreshForHome(queue.removeAt(0));
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    isRefreshingAll = false;
    lastRefresh = DateTime.now();
    _changed();
    _scheduleSave();
    _prefetchThumbnails();
  }

  /// Refreshes a site and, when its page only lists categories, the first few categories too.
  Future<void> refreshForHome(Site site) async {
    await refresh(site, null);
    final s = SiteStore.shared.site(site.id);
    if (s == null || s.categories.isEmpty || !needsCategoryFeeds(feeds[key(s)] ?? const [])) return;
    for (final c in s.categories.take(4)) {
      await refresh(s, c);
    }
  }

  Future<void> refresh(Site site, SiteCategory? category) async {
    final k = key(site, category);
    if (loading.contains(k)) return;
    loading.add(k);
    _changed();
    try {
      final r = await fetchListing(category?.url ?? site.url, category?.url ?? site.url, site, category?.name);
      var old = [...?feeds[k]];
      // Tiles that open more items (categories, albums) must not be shown as single images.
      var probe = _listingProbe[k];
      if (probe == null && !Scraper.isReddit(site.url)) probe = await probeListingTiles(r, site);
      if (probe != null) {
        _listingProbe[k] = probe;
        if (probe) {
          final tiles = r.items.where(isTileCandidate).toList();
          final tileIds = tiles.map((e) => e.id).toSet();
          if (category == null) {
            final cats = tiles.map((e) => e.asCategory).whereType<SiteCategory>().toList();
            final catUrls = cats.map((e) => e.url).toSet();
            r.categories = [...cats, ...r.categories.where((c) => !catUrls.contains(c.url))];
            r.items.removeWhere((e) => tileIds.contains(e.id));
            old.removeWhere((e) => e.isListing || tileIds.contains(e.id) || isTileCandidate(e));
          } else {
            for (final i in r.items) {
              if (tileIds.contains(i.id)) i.isListing = true;
            }
            old.removeWhere((e) => tileIds.contains(e.id));
          }
        }
      }
      errors.remove(k);
      // Tiles that link to one of the site's categories open that category, never an image.
      final known = {...r.categories, ...?SiteStore.shared.site(site.id)?.categories}.map((c) => matchKey(c.url)).toSet();
      if (known.isNotEmpty) {
        bool hit(MediaItem e) => e.pageUrl != null && known.contains(matchKey(e.pageUrl!));
        if (category == null) {
          r.items.removeWhere(hit);
          old.removeWhere(hit);
        } else {
          for (final i in r.items.where(hit)) {
            i.isListing = true;
          }
        }
      }
      // The site was removed while it loaded.
      if (SiteStore.shared.site(site.id) == null) return;
      final newIds = r.items.map((e) => e.id).toSet();
      var merged = [...r.items, ...old.where((e) => !newIds.contains(e.id))];
      if (merged.length > Limits.maxItemsPerFeed) merged = merged.sublist(0, Limits.maxItemsPerFeed);
      feeds[k] = merged;
      if (r.nextPage != null) {
        _nextPages[k] = r.nextPage!;
      } else {
        _nextPages.remove(k);
      }
      if (category == null) _updateSiteMeta(site, r);
      _scheduleSave();
    } catch (e) {
      if ((feeds[k] ?? const []).isEmpty) errors[k] = e.toString();
    } finally {
      loading.remove(k);
      _changed();
    }
  }

  /// Next pages for the Home feed: each site's own page, or the categories its Home items come from.
  Future<void> loadMoreHome(List<Site> sites) async {
    final jobs = <Future<void>>[];
    for (final site in sites.take(12)) {
      if (_nextPages.containsKey(key(site))) jobs.add(loadMore(site, null));
      if (site.categories.isNotEmpty && needsCategoryFeeds(feeds[key(site)] ?? const [])) {
        for (final c in site.categories.take(3)) {
          if (_nextPages.containsKey(key(site, c))) jobs.add(loadMore(site, c));
        }
      }
    }
    await Future.wait(jobs);
  }

  Future<void> loadMore(Site site, SiteCategory? category) async {
    final k = key(site, category);
    final next = _nextPages[k];
    if (next == null || loading.contains(k)) return;
    loading.add(k);
    _changed();
    try {
      final r = await fetchListing(next, category?.url ?? site.url, site, category?.name);
      final list = [...?feeds[k]];
      final have = list.map((e) => e.id).toSet();
      final fresh = r.items.where((e) => !have.contains(e.id)).toList();
      feeds[k] = [...list, ...fresh];
      if (fresh.isEmpty || r.nextPage == null || r.nextPage == next) {
        _nextPages.remove(k);
      } else {
        _nextPages[k] = r.nextPage!;
      }
      _scheduleSave();
    } catch (_) {
      _nextPages.remove(k);
    } finally {
      loading.remove(k);
      _changed();
    }
  }

  void _updateSiteMeta(Site site, ScrapeResult r) {
    final s = SiteStore.shared.site(site.id)?.copy();
    if (s == null) return;
    if (r.categories.isNotEmpty && !listEquals(r.categories, s.categories)) s.categories = r.categories;
    if (s.iconUrl == null && r.iconUrl != null) s.iconUrl = r.iconUrl;
    s.lastRefreshed = DateTime.now();
    SiteStore.shared.update(s);
  }

  void forget(String siteId) {
    feeds.removeWhere((k, _) => k.startsWith(siteId));
    _nextPages.removeWhere((k, _) => k.startsWith(siteId));
    _scheduleSave();
    _changed();
  }

  void clearCache() {
    feeds.clear();
    _nextPages.clear();
    _resolved.clear();
    _resolvedAt.clear();
    _listingProbe.clear();
    lastRefresh = null;
    _scheduleSave();
    _changed();
  }

  // MARK: Fetching

  static Future<ScrapeResult> fetchListing(Uri url, Uri base, Site site, String? categoryName, {bool allowRender = true}) async {
    if (Scraper.isReddit(url)) {
      final jsonUrl = url.path.endsWith('.json') ? url : Scraper.redditJsonUrl(url);
      try {
        final data = await Net.redditJson(jsonUrl);
        return await _parseRedditOff(data, base, site, categoryName);
      } catch (e) {
        // JSON refused: the RSS feed of the same page still lists images and thumbnails.
        var path = url.path;
        if (path.endsWith('.json')) path = path.substring(0, path.length - 5);
        while (path.endsWith('/')) {
          path = path.substring(0, path.length - 1);
        }
        final q = Map.of(url.queryParameters)..removeWhere((k, _) => !['t', 'q', 'after'].contains(k));
        final rss = Uri(scheme: 'https', host: 'www.reddit.com', path: '$path/.rss', queryParameters: q.isEmpty ? null : q);
        final r = Scraper.parseFeed((await Net.fetch(rss, ua: Net.redditUserAgent)).text, rss, site, categoryName);
        if (r.items.isEmpty) rethrow;
        if (Scraper.isRedditListing(base)) r.categories = Scraper.redditCategories(base);
        return r;
      }
    }
    // App-only sites: read their feed API.
    if (SiteAdapters.isFikFap(url)) {
      try {
        return await SiteAdapters.fikfapFeed(site, url.queryParameters['inuttAfter']);
      } catch (_) {}
    }
    var result = ScrapeResult();
    var staticOk = false;
    Object? staticError;
    if (site.renderMode != RenderMode.full || !allowRender) {
      try {
        final f = await Net.fetch(url);
        if (SiteAdapters.looksLikeJson(f.bytes)) {
          final r = await _parseJsonOff(f.text, f.finalUrl, site, categoryName);
          if (r.items.isNotEmpty) return r;
        }
        final text = f.text;
        if (Scraper.looksLikeFeed(text)) return await _parseFeedOff(text, f.finalUrl, site, categoryName);
        result = await _parseListingOff(text, f.finalUrl, site, categoryName);
        staticOk = true;
      } catch (e) {
        // Blocked or empty for plain requests (bot checks, app shells): the browser may still get it.
        if (!allowRender) rethrow;
        staticError = e;
      }
    }
    final needsRender =
        site.renderMode == RenderMode.full ||
        (site.renderMode == RenderMode.auto && result.items.length < 6 && result.categories.length < 6);
    if (staticError != null && !needsRender) throw staticError;
    if (allowRender && needsRender) {
      final html = await PageRenderer.shared.render(url);
      if (html != null) {
        final r2 = await _parseListingOff(html, url, site, categoryName);
        if (r2.items.length > result.items.length) {
          result.items = r2.items;
          result.nextPage ??= r2.nextPage;
        }
        if (r2.categories.length > result.categories.length) result.categories = r2.categories;
        result.iconUrl ??= r2.iconUrl;
        result.title ??= r2.title;
      } else if (!staticOk) {
        throw staticError ?? NetException('The page is empty.');
      }
    }
    return result;
  }

  // Parsing runs in its own isolate so scrolling never stutters while pages load.
  static Future<ScrapeResult> _parseListingOff(String html, Uri url, Site site, String? cat) =>
      Isolate.run(() => Scraper.parseListing(html, url, site, cat));
  static Future<ScrapeResult> _parseJsonOff(String text, Uri url, Site site, String? cat) =>
      Isolate.run(() => SiteAdapters.parseJsonListing(text, url, site, cat));
  static Future<ScrapeResult> _parseFeedOff(String xml, Uri url, Site site, String? cat) =>
      Isolate.run(() => Scraper.parseFeed(xml, url, site, cat));
  static Future<ScrapeResult> _parseRedditOff(List<int> data, Uri url, Site site, String? cat) =>
      Isolate.run(() => Scraper.parseReddit(data, url, site, cat));
  static Future<ResolvedMedia?> _resolveDetailOff(String html, Uri url, int maxQ) =>
      Isolate.run(() => Scraper.resolveDetail(html, url, maxQ));
  static Future<bool> _isListingOff(String html, Uri url, Site site) => Isolate.run(() => isListingHtml(html, url, site));

  // MARK: Category tiles

  /// A tile that opens a page (not a media file) and shows no video duration.
  static bool isTileCandidate(MediaItem i) => i.pageUrl != null && i.mediaUrl == null && i.duration == null && i.kind != MediaKind.video;

  /// Opens up to two tiles of a listing; when they lead to pages full of videos or images,
  /// the tiles are categories (or albums) rather than single media.
  static Future<bool?> probeListingTiles(ScrapeResult r, Site site) async {
    final tiles = r.items.where(isTileCandidate).toList();
    if (tiles.length < 4 || tiles.length < r.items.length * 0.6) return false;
    var listings = 0, checked = 0;
    for (final t in tiles.take(2)) {
      final isList = await isListingPage(t.pageUrl!, site);
      if (isList == null) continue;
      checked++;
      if (!isList) return false;
      listings++;
    }
    return checked == 0 ? null : listings == checked;
  }

  static Future<bool?> isListingPage(Uri url, Site site) async {
    try {
      final f = await Net.fetch(url);
      return await _isListingOff(f.text, f.finalUrl, site);
    } catch (_) {
      return null;
    }
  }

  /// True when the page is a grid of many items rather than a page for one video or image.
  static bool isListingHtml(String html, Uri url, Site site) {
    final type = Scraper.meta('og:type', html)?.toLowerCase();
    if (type != null && type.contains('video')) return false;
    if (Scraper.meta('og:video', html) != null || Scraper.meta('og:video:url', html) != null) return false;
    if (Scraper.resolveDetail(html, url, 2160)?.kind == MediaKind.video) return false;
    final r = Scraper.parseListing(html, url, site, null);
    final media = r.items.where((e) => e.kind == MediaKind.video || e.duration != null || e.kind == MediaKind.gif).length;
    return r.items.length >= 8 && media >= 4;
  }

  void _markListing(MediaItem item) {
    for (final list in feeds.values) {
      for (final i in list) {
        if (i.id == item.id) i.isListing = true;
      }
    }
    _changed();
    _scheduleSave();
  }

  // MARK: Resolving

  ResolvedMedia? cachedResolution(MediaItem item) => _resolved[item.id];

  /// The playable file behind an item. Answers instantly from the cache, joins a load that is already
  /// running, and otherwise loads it now ahead of any background work.
  Future<ResolvedMedia?> resolve(MediaItem item, {RenderPriority priority = RenderPriority.user}) async {
    // Kept offline: plays from the device, no connection needed.
    final local = OfflineStore.shared.local(item.id);
    if (local != null) return local;
    final cached = _resolved[item.id];
    if (cached != null) return cached;
    final running = _inflight[item.id];
    final r = await (running ?? _track(item, _resolveUncached(item, allowRender: true, priority: priority)));
    if (r != null) return r;
    // Nothing better found: show the thumbnail, but don't remember it so the next open tries again.
    if (running != null) {
      final again = await _track(item, _resolveUncached(item, allowRender: true, priority: priority));
      if (again != null) return again;
    }
    final t = item.thumbnailUrl;
    if (t == null) return null;
    return ResolvedMedia(url: t, kind: item.kind == MediaKind.gif ? MediaKind.gif : MediaKind.image, referer: item.pageUrl);
  }

  Future<ResolvedMedia?> _track(MediaItem item, Future<ResolvedMedia?> f) {
    final tracked = f.then(
      (r) {
        _inflight.remove(item.id);
        if (r != null) _remember(item, r);
        return r;
      },
      onError: (_) {
        _inflight.remove(item.id);
        return null;
      },
    );
    _inflight[item.id] = tracked;
    return tracked;
  }

  /// Loads items as they scroll into view, newest request first, so a tap on them opens at once.
  /// Pages that need a browser are left for the tap.
  void prefetch(MediaItem item) {
    if (item.isListing || item.mediaUrl != null || item.pageUrl == null) return;
    if (_resolved.containsKey(item.id) || _inflight.containsKey(item.id)) return;
    _prefetchQueue.removeWhere((e) => e.id == item.id);
    _prefetchQueue.add(item);
    if (_prefetchQueue.length > 40) _prefetchQueue.removeRange(0, _prefetchQueue.length - 40);
    _pumpPrefetch();
  }

  void _pumpPrefetch() {
    while (_prefetching < 3 && _prefetchQueue.isNotEmpty) {
      final item = _prefetchQueue.removeLast();
      if (_resolved.containsKey(item.id) || _inflight.containsKey(item.id)) continue;
      _prefetching++;
      _track(item, _resolveUncached(item, allowRender: false, priority: RenderPriority.background)).whenComplete(() {
        _prefetching--;
        _pumpPrefetch();
      });
    }
  }

  void _remember(MediaItem item, ResolvedMedia r) {
    _resolved[item.id] = r;
    _resolvedAt[item.id] = DateTime.now();
    if (r.isListing) {
      _markListing(item);
    } else if (r.kind != item.kind) {
      for (final list in feeds.values) {
        for (final i in list) {
          if (i.id == item.id) i.kind = r.kind;
        }
      }
      item.kind = r.kind;
      _changed();
    }
    _scheduleSave();
  }

  Future<ResolvedMedia?> _resolveUncached(MediaItem item, {required bool allowRender, required RenderPriority priority}) async {
    final maxQ = AppSettings.shared.maxQuality;
    final site = SiteStore.shared.site(item.siteId);
    try {
      final g = item.gallery;
      final page = item.pageUrl;
      if (g != null && g.length > 1) return ResolvedMedia(url: g.first, kind: MediaKind.image, gallery: g);
      if (item.mediaUrl != null) {
        var url = item.mediaUrl!;
        var kind = MediaKind.guess(url) ?? item.kind;
        if (url.path.toLowerCase().endsWith('.gifv')) {
          url = Uri.parse(url.toString().replaceAll('.gifv', '.mp4'));
          kind = MediaKind.video;
        }
        return ResolvedMedia(url: url, kind: kind, referer: item.pageUrl ?? item.mediaUrl);
      }
      if (page == null) return null;
      if (Scraper.isReddit(page)) {
        final data = await Net.redditJson(Scraper.redditJsonUrl(page));
        final posts = (await _parseRedditOff(data, page, site ?? Site(name: item.siteName, url: page), null)).items;
        if (posts.isEmpty) return null;
        final p = posts.first;
        if (p.gallery != null && p.gallery!.length > 1) {
          return ResolvedMedia(url: p.gallery!.first, kind: MediaKind.image, gallery: p.gallery!);
        }
        if (p.mediaUrl != null) return ResolvedMedia(url: p.mediaUrl!, kind: p.kind, referer: page);
        return null;
      }
      ResolvedMedia? result;
      if (site?.renderMode != RenderMode.full) {
        try {
          final f = await Net.fetch(page);
          final html = f.text;
          if (item.kind != MediaKind.video && item.duration == null && site != null && await _isListingOff(html, f.finalUrl, site)) {
            return ResolvedMedia(url: page, kind: MediaKind.image, referer: page, isListing: true);
          }
          result = await _resolveDetailOff(html, f.finalUrl, maxQ);
        } catch (_) {}
      }
      final wantsVideo = item.kind == MediaKind.video && result?.kind != MediaKind.video;
      if (result == null || wantsVideo || site?.renderMode == RenderMode.full) {
        if (!allowRender) return result != null && !wantsVideo ? result : null;
        // Returns as soon as the page shows its video, not when the whole page is done.
        final (video, html) = await PageRenderer.shared.renderMedia(page);
        if (video != null) {
          return ResolvedMedia(
            url: video.url,
            kind: MediaKind.guess(video.url) == MediaKind.gif ? MediaKind.gif : MediaKind.video,
            referer: page,
          );
        }
        if (html != null) {
          final r2 = await _resolveDetailOff(html, page, maxQ);
          if (r2 != null && (result == null || r2.kind == MediaKind.video)) result = r2;
        }
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  // MARK: Search

  /// More like this: what the item's own page links to (related videos and pictures), then items
  /// from the same site with similar titles.
  Future<List<MediaItem>> related(MediaItem item) async {
    final out = <MediaItem>[];
    final seen = <String>{item.id};
    final own = item.pageUrl == null ? null : matchKey(item.pageUrl!);
    void take(Iterable<MediaItem> list) {
      for (final i in Blocklist.filter(list.toList())) {
        if (i.isListing || (own != null && i.pageUrl != null && matchKey(i.pageUrl!) == own)) continue;
        if (seen.add(i.id)) out.add(i);
      }
    }

    final page = item.pageUrl;
    if (page != null && page.scheme.startsWith('http')) {
      final site = SiteStore.shared.site(item.siteId) ?? Site(name: item.siteName, url: page);
      try {
        final r = await fetchListing(page, page, site, item.categoryName, allowRender: false);
        take(r.items.where((e) => isMedia(e) || e.pageUrl != null));
      } catch (_) {}
    }
    if (out.length < 12) {
      List<String> words(String t) => t.toLowerCase().split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)).where((w) => w.isNotEmpty).toList();
      final mine = words(item.title).where((w) => w.length >= 4).toSet();
      final scored = <(MediaItem, int)>[];
      for (final i in allCachedItems()) {
        if (i.siteId != item.siteId && i.siteName != item.siteName) continue;
        var score = words(i.title).toSet().intersection(mine).length * 2;
        if (item.categoryName != null && item.categoryName == i.categoryName) score += 1;
        if (i.kind == item.kind) score += 1;
        if (score > 1) scored.add((i, score));
      }
      scored.sort((a, b) => b.$2.compareTo(a.$2));
      take(scored.take(60).map((e) => e.$1));
    }
    return out.take(80).toList();
  }

  Future<List<MediaItem>> remoteSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final lists = await Future.wait(SiteStore.shared.enabledSites.map((s) => search(q, s)));
    final out = <MediaItem>[];
    final maxLen = lists.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    for (var i = 0; i < maxLen; i++) {
      for (final l in lists) {
        if (i < l.length) out.add(l[i]);
      }
    }
    return out;
  }

  static Future<List<MediaItem>> search(String q, Site site) async {
    final enc = Uri.encodeQueryComponent(q);
    final pathEnc = Uri.encodeComponent(q.replaceAll(' ', '-'));
    final candidates = <Uri>[];
    if (Scraper.isReddit(site.url)) {
      candidates.add(Scraper.redditJsonUrl(site.url, search: q));
    } else if (site.searchTemplate != null && site.searchTemplate!.isNotEmpty) {
      final u = Uri.tryParse(site.searchTemplate!.replaceAll('{q}', enc));
      if (u != null) candidates.add(u);
    } else {
      final root = '${site.url.scheme}://${site.url.host}';
      candidates.addAll(['$root/search?q=$enc', '$root/?s=$enc', '$root/search/$pathEnc/'].map(Uri.parse));
    }
    for (final u in candidates) {
      try {
        final r = await fetchListing(u, Scraper.isReddit(site.url) ? site.url : u, site, null, allowRender: false);
        if (r.items.length >= 2) return r.items.take(60).toList();
      } catch (_) {}
    }
    return [];
  }

  void _prefetchThumbnails() {
    final urls = <(Uri, Uri?)>[];
    for (final s in SiteStore.shared.enabledSites) {
      for (final i in (feeds[key(s)] ?? const <MediaItem>[]).take(24)) {
        if (i.thumbnailUrl != null) urls.add((i.thumbnailUrl!, i.referer));
      }
    }
    ImagePipeline.shared.prefetch(urls);
  }

  // MARK: Persistence

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1500), saveNow);
  }

  void saveNow() {
    Disk.save('feeds.json', {
      'feeds': feeds.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
      'next': _nextPages.map((k, v) => MapEntry(k, v.toString())),
      'lastRefresh': lastRefresh?.millisecondsSinceEpoch,
    });
    final recent = _resolvedAt.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    Disk.save('resolved.json', {
      for (final e in recent.take(3000))
        if (_resolved[e.key] case final m?) e.key: {'media': m.toJson(), 'at': e.value.millisecondsSinceEpoch},
    });
  }
}
