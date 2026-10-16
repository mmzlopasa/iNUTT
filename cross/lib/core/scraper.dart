import 'dart:convert';

import 'html.dart';
import 'models.dart';

/// Turns arbitrary pages (HTML, RSS/Atom, Reddit JSON) into media items and categories.
class Scraper {
  static const _durationPattern = r'(?<![\d:])((?:\d{1,2}:)?\d{1,2}:\d{2})(?![\d:])';

  static const categoryPathPattern =
      r'/(categor(?:y|ies)|cats?|tags?|channels?|genres?|collections?|topics?|sections?|niches?|albums?|boards?|playlists?|c|r)/[^/?#]+/?$';

  /// "1,234 videos", "56 photos", "12.5K clips" on a tile marks it as a category or album.
  static const countHintPattern =
      r'\b\d[\d.,]*\s*[km]?\+?\s*(?:videos?|clips?|movies?|galleries|gallery|pics|pictures|photos|images|gifs|items|posts|albums?)\b';

  static bool isCategoryUrl(Uri u) => Html.re(categoryPathPattern).hasMatch(u.path);

  static ScrapeResult parseListing(String html, Uri baseUrl, Site site, String? categoryName) {
    final result = ScrapeResult();
    result.title = Html.first(r'''<meta[^>]+property=["']og:site_name["'][^>]+content=["']([^"']+)''', html) ??
        (Html.first(r'<title[^>]*>(.*?)</title>', html) != null ? Html.stripTags(Html.first(r'<title[^>]*>(.*?)</title>', html)!) : null);
    result.iconUrl = iconUrl(html, baseUrl);

    final siteDomain = Html.registrableDomain(site.url.host);
    final seen = <String>{};
    final items = <MediaItem>[];
    final cardCategories = <SiteCategory>[];
    final seenCategories = <String>{};

    void add(MediaItem item) {
      final key = (item.pageUrl ?? item.mediaUrl ?? item.thumbnailUrl)?.toString() ?? item.id;
      if (seen.contains(key)) return;
      final t = item.thumbnailUrl?.toString();
      if (t != null && seen.contains('thumb:$t')) return;
      seen.add(key);
      if (t != null) seen.add('thumb:$t');
      items.add(item);
    }

    // 1) Anchors that wrap a thumbnail ("cards").
    for (final m in Html.matches(r'<a\b([^>]*)>(.*?)</a>', html)) {
      final attrText = m[1] ?? '';
      final inner = m[2] ?? '';
      final attrs = Html.attributes(attrText);
      final href = Html.resolve(attrs['href'], baseUrl);
      if (href == null) continue;
      final hrefKind = MediaKind.guess(href);

      Uri? thumb;
      String? alt;
      final imgTag = Html.first(r'(<img\b[^>]*>)', inner);
      if (imgTag != null) {
        final ia = Html.attributes(imgTag);
        thumb = bestImage(ia, baseUrl, preferSmall: true);
        alt = ia['alt'] ?? ia['title'];
      }
      if (thumb == null) {
        final src = Html.first(r'''<source\b[^>]*(?:data-)?srcset=["']([^"']+)''', inner);
        if (src != null) thumb = Html.bestFromSrcset(src, baseUrl, maxWidth: 800);
      }
      if (thumb == null) {
        const bg = r'''background(?:-image)?\s*:\s*url\(\s*['"]?([^'")]+)''';
        final b = Html.first(bg, inner) ?? Html.first(bg, attrText);
        if (b != null) thumb = Html.resolve(b, baseUrl);
      }
      if (thumb == null) {
        for (final key in ['data-thumb', 'data-poster', 'data-image', 'data-src']) {
          final u = Html.resolve(attrs[key], baseUrl);
          if (u != null) {
            thumb = u;
            break;
          }
        }
      }
      if (thumb == null) {
        final poster = Html.first(r'''<video\b[^>]*poster=["']([^"']+)''', inner);
        if (poster != null) thumb = Html.resolve(poster, baseUrl);
      }

      if (thumb == null && hrefKind == null) continue;
      if (thumb != null && isJunkImage(thumb)) continue;
      final sameSite = Html.registrableDomain(href.host) == siteDomain;
      if (hrefKind == null && !sameSite && !isKnownMediaHost(href.host)) continue;
      if (hrefKind == null && href.path == baseUrl.path && href.query == baseUrl.query) continue;

      final text = Html.stripTags(inner);
      final duration = Html.first(_durationPattern, text);
      final countHint = duration == null && Html.re(countHintPattern).hasMatch(text);
      // Category tiles (a thumbnail linking to a category page) become categories, not media.
      if (hrefKind == null && sameSite && (isCategoryUrl(href) || countHint)) {
        var name = cleanTitle(attrs['title'] ?? (text.isEmpty ? (alt ?? '') : text));
        name = name.replaceAll(Html.re(countHintPattern), '').replaceAll(RegExp(r'^[\s\p{P}]+|[\s\p{P}]+$', unicode: true), '');
        if (name.isEmpty) {
          final segs = href.pathSegments.where((s) => s.isNotEmpty);
          name = cleanTitle(alt ?? (segs.isEmpty ? '' : segs.last.replaceAll('-', ' ')));
        }
        final key = href.toString().toLowerCase();
        if (name.isNotEmpty && name.length <= 60 && seenCategories.add(key)) {
          cardCategories.add(SiteCategory(name: name, url: href, thumbnailUrl: thumb));
          // The cover must not come back later as a standalone image.
          if (thumb != null) seen.add('thumb:$thumb');
        }
        continue;
      }
      final title = cleanTitle(attrs['title'] ?? alt ?? text, duration: duration);
      final lowerInner = '${inner.toLowerCase()} ${attrText.toLowerCase()}';
      final videoHint = duration != null ||
          lowerInner.contains('data-preview') ||
          lowerInner.contains('data-mp4') ||
          lowerInner.contains('data-webm') ||
          lowerInner.contains('<video') ||
          lowerInner.contains('play-icon') ||
          lowerInner.contains('duration') ||
          isVideoPath(href.path);

      var kind = MediaKind.image;
      if (hrefKind != null) {
        kind = hrefKind;
      } else if (MediaKind.guess(thumb) == MediaKind.gif) {
        kind = MediaKind.gif;
      } else if (videoHint) {
        kind = MediaKind.video;
      }

      add(MediaItem(
        siteId: site.id,
        siteName: site.name,
        title: title,
        thumbnailUrl: thumb ?? (hrefKind == MediaKind.image ? href : null),
        mediaUrl: hrefKind != null ? href : null,
        pageUrl: hrefKind == null ? href : null,
        kind: kind,
        duration: duration,
        categoryName: categoryName,
      ));
    }

    // 2) Inline videos on the page itself.
    for (final m in Html.matches(r'<video\b([^>]*)>(.*?)</video>', html)) {
      final va = Html.attributes(m[1] ?? '');
      var src = Html.resolve(va['src'] ?? va['data-src'], baseUrl);
      if (src == null) {
        final s = Html.first(r'''<source\b[^>]*src=["']([^"']+)''', m[2] ?? '');
        src = Html.resolve(s, baseUrl);
      }
      if (src == null) continue;
      add(MediaItem(
        siteId: site.id,
        siteName: site.name,
        title: va['title'] ?? '',
        thumbnailUrl: Html.resolve(va['poster'], baseUrl),
        mediaUrl: src,
        kind: MediaKind.video,
        categoryName: categoryName,
      ));
    }

    // 3) Gallery pages: standalone large images.
    if (items.length < 8) {
      for (final m in Html.matches(r'(<img\b[^>]*>)', html)) {
        final ia = Html.attributes(m[1] ?? '');
        final full = bestImage(ia, baseUrl, preferSmall: false);
        if (full == null || isJunkImage(full)) continue;
        final w = int.tryParse(ia['width'] ?? '');
        final h = int.tryParse(ia['height'] ?? '');
        if (w != null && w < 200) continue;
        if (h != null && h < 150) continue;
        add(MediaItem(
          siteId: site.id,
          siteName: site.name,
          title: ia['alt'] ?? ia['title'] ?? '',
          thumbnailUrl: bestImage(ia, baseUrl, preferSmall: true) ?? full,
          mediaUrl: full,
          kind: MediaKind.guess(full) == MediaKind.gif ? MediaKind.gif : MediaKind.image,
          categoryName: categoryName,
        ));
      }
    }

    // 4) Raw media URLs embedded in scripts / JSON.
    if (items.length < 3) {
      for (final url in rawMediaUrls(html, baseUrl).take(60)) {
        final k = MediaKind.guess(url) ?? MediaKind.video;
        add(MediaItem(
          siteId: site.id,
          siteName: site.name,
          title: '',
          thumbnailUrl: k == MediaKind.video ? null : url,
          mediaUrl: url,
          kind: k,
          categoryName: categoryName,
        ));
      }
    }

    result.items = items;
    final textCategories = categories(html, baseUrl, siteDomain).where((c) => !seenCategories.contains(c.url.toString().toLowerCase()));
    result.categories = [...cardCategories, ...textCategories];
    result.nextPage = nextPage(html, baseUrl);
    return result;
  }

  // MARK: Detail pages

  static ResolvedMedia? resolveDetail(String html, Uri pageUrl, int maxHeight) {
    final videos = <(Uri, int)>[];
    void addVideo(String? raw, {String? label}) {
      final u = Html.resolve(raw, pageUrl);
      if (u == null) return;
      final s = u.toString().toLowerCase();
      final ext = u.path.toLowerCase().split('.').last;
      if (!['mp4', 'm4v', 'mov', 'm3u8', 'webm'].contains(ext) && !s.contains('.m3u8') && !s.contains('.mp4')) return;
      if (videos.any((v) => v.$1 == u)) return;
      videos.add((u, quality(u, label)));
    }

    for (final m in Html.matches(r'<video\b([^>]*)>(.*?)</video>', html)) {
      final va = Html.attributes(m[1] ?? '');
      addVideo(va['src'] ?? va['data-src']);
      for (final s in Html.matches(r'(<source\b[^>]*>)', m[2] ?? '')) {
        final sa = Html.attributes(s[1] ?? '');
        addVideo(sa['src'] ?? sa['data-src'], label: sa['size'] ?? sa['label'] ?? sa['res'] ?? sa['data-quality'] ?? sa['title']);
      }
    }
    for (final key in ['og:video:secure_url', 'og:video:url', 'og:video', 'twitter:player:stream']) {
      addVideo(meta(key, html));
    }
    const jsonKeys =
        r'''["'](?:contentUrl|file|src|videoUrl|video_url|mp4|hls|hlsUrl|url|source|stream_url|videoSrc)["']\s*:\s*["']([^"']+\.(?:mp4|m3u8|webm|mov)[^"']*)["']''';
    for (final m in Html.matches(jsonKeys, html, limit: 40)) {
      addVideo(m[1]);
    }
    for (final m in Html.matches(r'<source\b([^>]*)>', html, limit: 20)) {
      final sa = Html.attributes(m[1] ?? '');
      addVideo(sa['src'], label: sa['size'] ?? sa['label'] ?? sa['res']);
    }
    if (videos.isEmpty) {
      for (final u in rawMediaUrls(html, pageUrl)) {
        if (MediaKind.guess(u) == MediaKind.video) addVideo(u.toString());
      }
    }

    final poster = Html.resolve(meta('og:image', html), pageUrl);

    if (videos.isNotEmpty) {
      final mp4s = videos.where((v) => !v.$1.toString().contains('.m3u8')).toList();
      final hls = videos.where((v) => v.$1.toString().contains('.m3u8')).toList();
      (Uri, int)? pick(List<(Uri, int)> list) {
        if (list.isEmpty) return null;
        final within = list.where((v) => v.$2 <= maxHeight).toList();
        if (within.isNotEmpty) return within.reduce((a, b) => a.$2 >= b.$2 ? a : b);
        return list.reduce((a, b) => a.$2 <= b.$2 ? a : b);
      }

      // Adaptive HLS already goes up to 4K, so prefer it unless a high quality MP4 exists.
      final m = pick(mp4s);
      Uri? best;
      if (m != null && (m.$2 >= 720 || hls.isEmpty)) {
        best = m.$1;
      } else {
        best = hls.isNotEmpty ? hls.first.$1 : m?.$1;
      }
      if (best != null) {
        return ResolvedMedia(url: best, kind: MediaKind.video, referer: pageUrl, gallery: poster == null ? const [] : [poster]);
      }
    }

    final gifv = Html.first(r'''(https?://[^"'\s>]+\.gifv)''', html);
    if (gifv != null) return ResolvedMedia(url: Uri.parse(gifv.replaceAll('.gifv', '.mp4')), kind: MediaKind.video, referer: pageUrl);

    final images = <Uri>[];
    for (final m in Html.matches(r'(<img\b[^>]*>)', html)) {
      final ia = Html.attributes(m[1] ?? '');
      final u = bestImage(ia, pageUrl, preferSmall: false);
      if (u == null || isJunkImage(u)) continue;
      final w = int.tryParse(ia['width'] ?? '');
      final h = int.tryParse(ia['height'] ?? '');
      if (w != null && w < 300) continue;
      if (h != null && h < 200) continue;
      if (!images.contains(u)) images.add(u);
    }
    for (final m in Html.matches(r'''<a\b[^>]*href=["']([^"']+\.(?:jpe?g|png|webp|gif)(?:\?[^"']*)?)["']''', html, limit: 200)) {
      final u = Html.resolve(m[1], pageUrl);
      if (u != null && !isJunkImage(u) && !images.contains(u)) images.add(u);
    }
    if (poster != null && !images.contains(poster)) images.insert(0, poster);
    final large = images.where((u) => !u.toString().toLowerCase().contains('thumb')).toList();
    final pool = large.isEmpty ? images : large;
    if (pool.isEmpty) return null;
    final kind = MediaKind.guess(pool.first) == MediaKind.gif ? MediaKind.gif : MediaKind.image;
    return ResolvedMedia(url: pool.first, kind: kind, gallery: pool.length > 1 ? pool.take(100).toList() : const [], referer: pageUrl);
  }

  // MARK: RSS / Atom

  static bool looksLikeFeed(String text) {
    final head = (text.length > 600 ? text.substring(0, 600) : text).toLowerCase();
    return head.contains('<rss') || head.contains('<feed') || head.contains('<rdf:rdf');
  }

  static ScrapeResult parseFeed(String xml, Uri baseUrl, Site site, String? categoryName) {
    final result = ScrapeResult();
    const titleP = r'<title[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>';
    final t = Html.first(titleP, xml);
    result.title = t == null ? null : Html.stripTags(t);
    for (final m in Html.matches(r'<(item|entry)\b.*?>(.*?)</\1>', xml, limit: 300)) {
      final body = m[2] ?? '';
      final tt = Html.first(titleP, body);
      final title = tt == null ? '' : Html.stripTags(tt);
      final link = Html.first(r'<link[^>]*>([^<]+)</link>', body) ?? Html.first(r'''<link[^>]*href=["']([^"']+)''', body);
      final pageUrl = Html.resolve(link, baseUrl);
      Uri? media;
      String? mediaType;
      final enc = Html.first(r'(<(?:enclosure|media:content)\b[^>]*>)', body);
      if (enc != null) {
        final a = Html.attributes(enc);
        media = Html.resolve(a['url'], baseUrl);
        mediaType = a['type'] ?? a['medium'];
      }
      var thumb = Html.resolve(Html.first(r'''<media:thumbnail\b[^>]*url=["']([^"']+)''', body), baseUrl);
      final decoded = Html.decodeEntities(body);
      thumb ??= Html.resolve(Html.first(r'''<img\b[^>]*src=["']([^"']+)''', decoded), baseUrl);
      var kind = MediaKind.guess(media) ?? MediaKind.image;
      final tl = mediaType?.toLowerCase();
      if (tl != null) {
        if (tl.contains('video')) {
          kind = MediaKind.video;
        } else if (tl.contains('gif')) {
          kind = MediaKind.gif;
        }
      }
      if (media == null && thumb == null) continue;
      if (thumb == null && kind != MediaKind.video) thumb = media;
      result.items.add(MediaItem(
        siteId: site.id,
        siteName: site.name,
        title: title,
        thumbnailUrl: thumb,
        mediaUrl: media,
        pageUrl: pageUrl,
        kind: kind,
        categoryName: categoryName,
      ));
    }
    return result;
  }

  // MARK: Reddit

  static bool isReddit(Uri url) => url.host.toLowerCase().contains('reddit.com');

  static Uri redditJsonUrl(Uri url, {String? after, String? search, String host = 'www.reddit.com'}) {
    var path = url.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path.endsWith('.json')) path = path.substring(0, path.length - 5);
    final query = <String, String>{'raw_json': '1', 'limit': '100'};
    // Keep options such as ?t=week from the original link.
    url.queryParameters.forEach((k, v) {
      if (!['raw_json', 'limit', 'after', 'q', 'restrict_sr'].contains(k)) query[k] = v;
    });
    String p;
    if (search != null) {
      p = '$path/search.json';
      query['q'] = search;
      query['restrict_sr'] = path.isEmpty ? '0' : '1';
    } else {
      p = '${path.isEmpty ? '/' : path}.json';
    }
    if (after != null) query['after'] = after;
    return Uri(scheme: 'https', host: host, path: p, queryParameters: query);
  }

  /// A subreddit or user page (has sort orders), not the front page or a single post.
  static bool isRedditListing(Uri url) {
    final parts = url.pathSegments.where((s) => s.isNotEmpty).map((s) => s.toLowerCase()).toList();
    if (parts.length < 2 || !['r', 'u', 'user'].contains(parts[0])) return false;
    return !parts.contains('comments');
  }

  /// Sort orders shown as categories for a subreddit or user.
  static List<SiteCategory> redditCategories(Uri url) {
    var path = url.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    for (final sort in ['/hot', '/new', '/top', '/rising', '/controversial']) {
      if (path.endsWith(sort)) path = path.substring(0, path.length - sort.length);
    }
    final base = 'https://www.reddit.com$path';
    const sorts = [
      ('Hot', '/hot/'),
      ('New', '/new/'),
      ('Top today', '/top/?t=day'),
      ('Top this week', '/top/?t=week'),
      ('Top this month', '/top/?t=month'),
      ('Top this year', '/top/?t=year'),
      ('Top of all time', '/top/?t=all'),
    ];
    return [for (final s in sorts) SiteCategory(name: s.$1, url: Uri.parse(base + s.$2))];
  }

  static Uri? _s(dynamic v) => v is String ? Uri.tryParse(v) : null;

  /// The playable media of one Reddit post: (media, kind, thumb, gallery).
  static (Uri?, MediaKind, Uri?, List<Uri>)? redditMedia(Map<String, dynamic> post) {
    var p = post;
    // Crossposts carry their media on the original post.
    final parents = p['crosspost_parent_list'];
    if (p['media'] == null && p['is_gallery'] != true && parents is List && parents.isNotEmpty) {
      p = parents.first as Map<String, dynamic>;
    }
    Uri? thumb;
    final preview = p['preview'];
    if (preview is Map && preview['images'] is List && (preview['images'] as List).isNotEmpty) {
      final first = (preview['images'] as List).first as Map;
      final res = first['resolutions'];
      if (res is List && res.isNotEmpty) {
        final fit = res.where((r) => ((r as Map)['width'] as int? ?? 0) <= 640).toList();
        thumb = _s(((fit.isNotEmpty ? fit.last : res.last) as Map)['url']);
      }
      thumb ??= _s((first['source'] as Map?)?['url']);
    }
    final t = p['thumbnail'];
    if (thumb == null && t is String && t.startsWith('http')) thumb = Uri.tryParse(t);

    final link = _s(p['url_overridden_by_dest'] ?? p['url']);
    Uri? media = link;
    var kind = MediaKind.guess(link) ?? MediaKind.image;
    final gallery = <Uri>[];

    final rv = ((p['media'] as Map?)?['reddit_video'] ?? (p['secure_media'] as Map?)?['reddit_video']) as Map?;
    final rvp = preview is Map ? preview['reddit_video_preview'] as Map? : null;
    if (rv != null) {
      media = _s(rv['hls_url'] ?? rv['fallback_url']);
      kind = MediaKind.video;
    } else if (rvp != null) {
      media = _s(rvp['hls_url'] ?? rvp['fallback_url']);
      kind = MediaKind.video;
    } else if (link != null && link.path.toLowerCase().endsWith('.gifv')) {
      media = Uri.parse(link.toString().replaceAll('.gifv', '.mp4'));
      kind = MediaKind.video;
    } else if (p['is_gallery'] == true && p['media_metadata'] is Map) {
      final meta = p['media_metadata'] as Map;
      final items = (p['gallery_data'] as Map?)?['items'] as List?;
      final order = items?.map((e) => (e as Map)['media_id'] as String).toList() ?? meta.keys.cast<String>().toList();
      var anyGif = false;
      for (final id in order) {
        final m = meta[id];
        if (m is! Map || m['s'] is! Map) continue;
        final s = m['s'] as Map;
        final u = _s(s['u'] ?? s['gif']);
        if (u != null) gallery.add(u);
        if (s['gif'] != null) anyGif = true;
        if (thumb == null && m['p'] is List && (m['p'] as List).isNotEmpty) {
          final ps = (m['p'] as List).where((x) => ((x as Map)['x'] as int? ?? 0) <= 640).toList();
          thumb = _s(((ps.isNotEmpty ? ps.last : (m['p'] as List).last) as Map)['u']);
        }
      }
      if (gallery.isEmpty) return null;
      media = gallery.first;
      kind = anyGif && gallery.length == 1 ? MediaKind.gif : MediaKind.image;
    } else if (p['post_hint'] == 'image' && link != null) {
      media = link;
      kind = MediaKind.guess(link) ?? MediaKind.image;
    } else if (MediaKind.guess(link) == null) {
      // Links to other hosts (Redgifs, Imgur pages…): resolved when opened.
      if (thumb == null) return null;
      media = null;
      final host = link?.host.toLowerCase() ?? '';
      if (p['post_hint'] == 'rich:video' || ['redgifs', 'gfycat', 'streamable', 'youtu'].any(host.contains)) kind = MediaKind.video;
    }
    if (media == null && thumb == null) return null;
    return (media, kind, thumb, gallery);
  }

  static ScrapeResult parseReddit(List<int> bytes, Uri listingUrl, Site site, String? categoryName) {
    final result = ScrapeResult();
    dynamic json;
    try {
      json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return result;
    }
    // A post page returns [post listing, comments]; a subreddit returns one listing.
    final listing = json is Map ? json : (json is List && json.isNotEmpty ? json.first : null);
    final d = listing is Map ? listing['data'] : null;
    if (d is! Map || d['children'] is! List) return result;
    for (final child in d['children'] as List) {
      if (child is! Map || child['kind'] == 't1' || child['data'] is! Map) continue;
      final p = (child['data'] as Map).cast<String, dynamic>();
      final rm = redditMedia(p);
      if (rm == null) continue;
      final (media, kind, thumb, gallery) = rm;
      final permalink = p['permalink'] is String ? Uri.parse('https://www.reddit.com${p['permalink']}') : null;
      Uri? page = media == null ? permalink : null;
      final external = _s(p['url_overridden_by_dest']);
      // Open the external page directly; it holds the actual media.
      if (media == null && external != null) page = external;
      result.items.add(MediaItem(
        id: hashKey((permalink ?? media ?? thumb).toString()),
        siteId: site.id,
        siteName: site.name,
        title: Html.decodeEntities(p['title'] as String? ?? ''),
        thumbnailUrl: thumb ?? (kind == MediaKind.video ? null : media),
        mediaUrl: media,
        pageUrl: page,
        kind: kind,
        categoryName: categoryName ?? p['subreddit_name_prefixed'] as String?,
        gallery: gallery.length > 1 ? gallery : null,
      ));
    }
    final after = d['after'];
    if (after is String) result.nextPage = redditJsonUrl(listingUrl, after: after);
    if (isRedditListing(listingUrl)) {
      result.categories = redditCategories(listingUrl);
      result.title = listingUrl.pathSegments.where((s) => s.isNotEmpty).take(2).join('/');
    } else {
      result.title = 'Reddit';
    }
    result.iconUrl = Uri.parse('https://www.redditstatic.com/shreddit/assets/favicon/192x192.png');
    return result;
  }

  // MARK: Helpers

  static String? meta(String property, String html) {
    final p = Html.escape(property);
    return Html.first('<meta[^>]+(?:property|name)=["\']$p["\'][^>]*content=["\']([^"\']+)', html) ??
        Html.first('<meta[^>]+content=["\']([^"\']+)["\'][^>]*(?:property|name)=["\']$p["\']', html);
  }

  static Uri? iconUrl(String html, Uri base) {
    for (final rel in ['apple-touch-icon', 'icon', 'shortcut icon']) {
      final p = Html.escape(rel);
      final h = Html.first('<link[^>]+rel=["\']$p["\'][^>]*href=["\']([^"\']+)', html) ??
          Html.first('<link[^>]+href=["\']([^"\']+)["\'][^>]*rel=["\']$p["\']', html);
      if (h != null) return Html.resolve(h, base);
    }
    return base.resolve('/favicon.ico');
  }

  static Uri? bestImage(Map<String, String> a, Uri base, {required bool preferSmall}) {
    final srcset = a['data-srcset'] ?? a['srcset'] ?? a['data-lazy-srcset'];
    if (srcset != null) {
      final u = Html.bestFromSrcset(srcset, base, maxWidth: preferSmall ? 800 : 3840);
      if (u != null) return u;
    }
    final order = preferSmall
        ? ['data-src', 'data-original', 'data-lazy-src', 'data-lazy', 'data-thumb', 'data-url', 'src', 'data-full', 'data-large']
        : ['data-full', 'data-large', 'data-zoom-image', 'data-hi-res', 'data-original', 'data-src', 'data-lazy-src', 'data-lazy', 'src'];
    for (final key in order) {
      final u = Html.resolve(a[key], base);
      if (u != null && !isPlaceholder(u)) return u;
    }
    return null;
  }

  static bool isPlaceholder(Uri u) {
    final s = u.toString().toLowerCase();
    return ['blank.', 'placeholder', 'spacer', '1x1', 'transparent.', 'lazy.', 'loading.'].any(s.contains) || s.endsWith('.svg');
  }

  static bool isJunkImage(Uri u) {
    if (isPlaceholder(u)) return true;
    final segs = u.pathSegments;
    final s = segs.isEmpty ? '' : segs.last.toLowerCase();
    final path = u.path.toLowerCase();
    for (final w in ['logo', 'favicon', 'icon', 'avatar', 'sprite', 'banner', 'emoji', 'badge', 'flag', '/ads/', 'pixel', 'tracking', 'button']) {
      if (s.contains(w) || (w.startsWith('/') && path.contains(w))) return true;
    }
    return false;
  }

  static bool isVideoPath(String p) {
    final l = p.toLowerCase();
    return ['/video', '/videos/', '/watch', '/v/', '/embed/', '/movie', '/clip', '/vod/', '/play/'].any(l.contains);
  }

  static bool isKnownMediaHost(String? host) {
    final h = host?.toLowerCase();
    if (h == null) return false;
    return ['imgur.com', 'redd.it', 'redgifs.com', 'gfycat.com', 'giphy.com', 'tenor.com', 'vimeo.com', 'streamable.com'].any(h.endsWith);
  }

  static String cleanTitle(String raw, {String? duration}) {
    var t = Html.decodeEntities(raw).trim();
    if (duration != null) t = t.replaceAll(duration, '');
    t = Html.collapse(t);
    if (t.length > 140) t = '${t.substring(0, 140)}…';
    return t;
  }

  static int quality(Uri url, String? label) {
    final hay = '${label ?? ''} $url';
    if (hay.toLowerCase().contains('4k') || hay.contains('2160')) return 2160;
    if (hay.contains('1440')) return 1440;
    final q = Html.first(r'(?<!\d)(2160|1440|1080|720|540|480|360|240)(?:p|_|\b)', hay);
    if (q != null) return int.parse(q);
    if (label != null) {
      final v = int.tryParse(label.replaceAll(RegExp(r'\D'), ''));
      if (v != null && v >= 144 && v <= 4320) return v;
    }
    return 480;
  }

  static List<Uri> rawMediaUrls(String html, Uri base) {
    final unescaped = html.replaceAll(r'\/', '/').replaceAll(r'/', '/');
    final out = <Uri>[];
    for (final m in Html.matches(
        r'''(https?://[^"'\s<>()\\]+?\.(?:mp4|m3u8|webm|gif|jpe?g|png|webp)(?:\?[^"'\s<>\\]*)?)(?=["'\s<>\\)])''', unescaped,
        limit: 400)) {
      final u = Html.resolve(m[1], base);
      if (u == null || isJunkImage(u) || out.contains(u)) continue;
      out.add(u);
    }
    return out;
  }

  static List<SiteCategory> categories(String html, Uri base, String siteDomain) {
    final out = <SiteCategory>[];
    final seen = <String>{};
    void consider(String? href, String inner, {required bool strict}) {
      final u = Html.resolve(href, base);
      if (u == null || Html.registrableDomain(u.host) != siteDomain) return;
      if (u.toString() == base.toString()) return;
      final name = Html.stripTags(inner);
      if (name.length < 2 || name.length > 40 || !RegExp(r'\p{L}', unicode: true).hasMatch(name)) return;
      if (strict && !isCategoryUrl(u)) return;
      if (!seen.add(u.toString().toLowerCase())) return;
      out.add(SiteCategory(name: name, url: u));
    }

    for (final m in Html.matches(r'<a\b([^>]*)>(.*?)</a>', html, limit: 4000)) {
      consider(Html.attributes(m[1] ?? '')['href'], m[2] ?? '', strict: true);
      if (out.length >= 120) break;
    }
    if (out.length < 3) {
      for (final nav in Html.matches(r'<nav\b[^>]*>(.*?)</nav>', html, limit: 5)) {
        for (final m in Html.matches(r'<a\b([^>]*)>(.*?)</a>', nav[1] ?? '')) {
          consider(Html.attributes(m[1] ?? '')['href'], m[2] ?? '', strict: false);
        }
      }
    }
    return out;
  }

  static Uri? nextPage(String html, Uri current) {
    final h = Html.first(r'''<link[^>]+rel=["']next["'][^>]*href=["']([^"']+)''', html) ??
        Html.first(r'''<a\b[^>]*rel=["']next["'][^>]*href=["']([^"']+)''', html) ??
        Html.first(r'''<a\b[^>]*href=["']([^"']+)["'][^>]*rel=["']next["']''', html);
    final hu = Html.resolve(h, current);
    if (hu != null && hu != current) return hu;
    for (final m in Html.matches(r'<a\b([^>]*)>(.*?)</a>', html)) {
      final a = Html.attributes(m[1] ?? '');
      final text = Html.stripTags(m[2] ?? '').toLowerCase();
      final cls = '${a['class'] ?? ''} ${a['aria-label'] ?? ''}'.toLowerCase();
      final isNext = ['next', 'next page', '›', '»', 'older', 'older posts', 'next »', '>'].contains(text) || cls.contains('next');
      if (isNext) {
        final u = Html.resolve(a['href'], current);
        if (u != null && u != current) return u;
      }
    }
    final s = current.toString();
    final n = Html.first(r'[?&]page=(\d+)', s);
    if (n != null) return Uri.tryParse(s.replaceAll('page=$n', 'page=${int.parse(n) + 1}'));
    final n2 = Html.first(r'/page/(\d+)', s);
    if (n2 != null) return Uri.tryParse(s.replaceAll('/page/$n2', '/page/${int.parse(n2) + 1}'));
    return null;
  }
}
