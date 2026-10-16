import 'dart:async';

import 'package:flutter/foundation.dart';

import 'image_cache.dart';
import 'models.dart';
import 'net.dart';
import 'scraper.dart';
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
  }

  static String key(Site site, [SiteCategory? category]) => category == null ? site.id : '${site.id}|${category.url}';

  List<MediaItem> items(Site site, [SiteCategory? category]) => feeds[key(site, category)] ?? const [];
  bool isLoading(Site site, [SiteCategory? c]) => loading.contains(key(site, c));
  String? error(Site site, [SiteCategory? c]) => errors[key(site, c)];

  /// Clearly a video, GIF or direct media file rather than a picture linking to another page.
  static bool isMedia(MediaItem i) => i.kind == MediaKind.video || i.kind == MediaKind.gif || i.duration != null || i.mediaUrl != null;

  /// The root page shows (almost) no real media, so its content lives in the categories.
  static bool needsCategoryFeeds(List<MediaItem> root) => root.where(isMedia).length < 6;

  /// What a site contributes to Home and its Latest section: real media, never category covers.
  /// When the site's own page only lists categories, its newest items come from those categories.
  List<MediaItem> homeItems(Site site) {
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
    final lists = sites.map(homeItems).toList();
    final out = <MediaItem>[];
    final seen = <String>{};
    final maxLen = lists.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    for (var i = 0; i < maxLen; i++) {
      for (final l in lists) {
        if (i < l.length && !l[i].isListing && seen.add(l[i].id)) out.add(l[i]);
      }
    }
    return out;
  }

  List<MediaItem> allCachedItems() {
    final seen = <String>{};
    return feeds.values.expand((e) => e).where((e) => seen.add(e.id)).toList();
  }

  bool get isStale => lastRefresh == null || DateTime.now().difference(lastRefresh!) > const Duration(minutes: 8);

  Future<void> refreshAll() async {
    if (isRefreshingAll) return;
    final sites = SiteStore.shared.enabledSites;
    if (sites.isEmpty) return;
    isRefreshingAll = true;
    notifyListeners();
    final queue = [...sites];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        await refreshForHome(queue.removeAt(0));
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    isRefreshingAll = false;
    lastRefresh = DateTime.now();
    notifyListeners();
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
    notifyListeners();
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
      notifyListeners();
    }
  }

  Future<void> loadMore(Site site, SiteCategory? category) async {
    final k = key(site, category);
    final next = _nextPages[k];
    if (next == null || loading.contains(k)) return;
    loading.add(k);
    notifyListeners();
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
      notifyListeners();
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
    notifyListeners();
  }

  void clearCache() {
    feeds.clear();
    _nextPages.clear();
    _resolved.clear();
    _listingProbe.clear();
    lastRefresh = null;
    _scheduleSave();
    notifyListeners();
  }

  // MARK: Fetching

  static Future<ScrapeResult> fetchListing(Uri url, Uri base, Site site, String? categoryName, {bool allowRender = true}) async {
    if (Scraper.isReddit(url)) {
      final jsonUrl = url.path.endsWith('.json') ? url : Scraper.redditJsonUrl(url);
      try {
        final data = await Net.redditJson(jsonUrl);
        return Scraper.parseReddit(data, base, site, categoryName);
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
    var result = ScrapeResult();
    var staticOk = false;
    if (site.renderMode != RenderMode.full || !allowRender) {
      final f = await Net.fetch(url);
      final text = f.text;
      if (Scraper.looksLikeFeed(text)) return Scraper.parseFeed(text, f.finalUrl, site, categoryName);
      result = Scraper.parseListing(text, f.finalUrl, site, categoryName);
      staticOk = true;
    }
    final needsRender = site.renderMode == RenderMode.full ||
        (site.renderMode == RenderMode.auto && result.items.length < 6 && result.categories.length < 6);
    if (allowRender && needsRender) {
      final html = await PageRenderer.shared.render(url);
      if (html != null) {
        final r2 = Scraper.parseListing(html, url, site, categoryName);
        if (r2.items.length > result.items.length) {
          result.items = r2.items;
          result.nextPage ??= r2.nextPage;
        }
        if (r2.categories.length > result.categories.length) result.categories = r2.categories;
        result.iconUrl ??= r2.iconUrl;
        result.title ??= r2.title;
      } else if (!staticOk) {
        throw NetException('The page is empty.');
      }
    }
    return result;
  }

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
      return isListingHtml(f.text, f.finalUrl, site);
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
    _scheduleSave();
  }

  // MARK: Resolving

  ResolvedMedia? cachedResolution(MediaItem item) => _resolved[item.id];

  Future<ResolvedMedia?> resolve(MediaItem item) async {
    final cached = _resolved[item.id];
    if (cached != null) return cached;
    final maxQ = AppSettings.shared.maxQuality;
    ResolvedMedia? result;
    final site = SiteStore.shared.site(item.siteId);

    try {
      final g = item.gallery;
      final page = item.pageUrl;
      if (g != null && g.length > 1) {
        result = ResolvedMedia(url: g.first, kind: MediaKind.image, gallery: g);
      } else if (page != null && item.mediaUrl == null && Scraper.isReddit(page)) {
        final data = await Net.redditJson(Scraper.redditJsonUrl(page));
        final posts = Scraper.parseReddit(data, page, site ?? Site(name: item.siteName, url: page), null).items;
        if (posts.isNotEmpty) {
          final p = posts.first;
          if (p.gallery != null && p.gallery!.length > 1) {
            result = ResolvedMedia(url: p.gallery!.first, kind: MediaKind.image, gallery: p.gallery!);
          } else if (p.mediaUrl != null) {
            result = ResolvedMedia(url: p.mediaUrl!, kind: p.kind);
          }
        }
      } else if (item.mediaUrl != null) {
        var url = item.mediaUrl!;
        var kind = MediaKind.guess(url) ?? item.kind;
        if (url.path.toLowerCase().endsWith('.gifv')) {
          url = Uri.parse(url.toString().replaceAll('.gifv', '.mp4'));
          kind = MediaKind.video;
        }
        result = ResolvedMedia(url: url, kind: kind, referer: item.pageUrl ?? item.mediaUrl);
      } else if (page != null) {
        if (site?.renderMode != RenderMode.full) {
          try {
            final f = await Net.fetch(page);
            final html = f.text;
            if (item.kind != MediaKind.video && item.duration == null && site != null && isListingHtml(html, f.finalUrl, site)) {
              final r = ResolvedMedia(url: page, kind: MediaKind.image, referer: page, isListing: true);
              _resolved[item.id] = r;
              _markListing(item);
              return r;
            }
            result = Scraper.resolveDetail(html, f.finalUrl, maxQ);
          } catch (_) {}
        }
        final wantsVideo = item.kind == MediaKind.video && result?.kind != MediaKind.video;
        if (result == null || wantsVideo || site?.renderMode == RenderMode.full) {
          final html = await PageRenderer.shared.render(page, settle: 1.2);
          if (html != null) {
            final r2 = Scraper.resolveDetail(html, page, maxQ);
            if (r2 != null && (result == null || r2.kind == MediaKind.video)) result = r2;
          }
        }
      }
    } catch (_) {}
    if (result == null && item.thumbnailUrl != null) {
      result = ResolvedMedia(
          url: item.thumbnailUrl!, kind: item.kind == MediaKind.gif ? MediaKind.gif : MediaKind.image, referer: item.pageUrl);
    }
    if (result != null) {
      _resolved[item.id] = result;
      if (result.kind != item.kind) {
        for (final list in feeds.values) {
          for (final i in list) {
            if (i.id == item.id) i.kind = result.kind;
          }
        }
        item.kind = result.kind;
        _scheduleSave();
      }
    }
    return result;
  }

  // MARK: Search

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
  }
}
