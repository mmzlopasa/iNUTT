import 'dart:convert';

import 'package:crypto/crypto.dart';

enum MediaKind {
  image,
  gif,
  video;

  String get label => switch (this) {
        MediaKind.image => 'Images',
        MediaKind.gif => 'GIF',
        MediaKind.video => 'Video',
      };

  static MediaKind? guess(Uri? url) {
    if (url == null) return null;
    final path = url.path.toLowerCase();
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot < path.lastIndexOf('/')) return null;
    switch (path.substring(dot + 1)) {
      case 'gif':
      case 'gifv':
        return MediaKind.gif;
      case 'mp4':
      case 'm4v':
      case 'mov':
      case 'm3u8':
      case 'webm':
      case 'ts':
        return MediaKind.video;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'webp':
      case 'heic':
      case 'avif':
      case 'bmp':
        return MediaKind.image;
    }
    return null;
  }

  static MediaKind parse(String? s) => MediaKind.values.firstWhere((k) => k.name == s, orElse: () => MediaKind.image);
}

String hashKey(String s) => sha256.convert(utf8.encode(s)).toString().substring(0, 24);

Uri? _u(dynamic v) => v is String && v.isNotEmpty ? Uri.tryParse(v) : null;

class MediaItem {
  String id;
  final String siteId;
  final String siteName;
  final String title;
  final Uri? thumbnailUrl;
  final Uri? mediaUrl;
  Uri? pageUrl;
  MediaKind kind;
  final String? duration;
  final String? categoryName;
  final DateTime addedAt;

  /// The link leads to a list of more items (a category or album), not to one media file.
  bool isListing;

  /// Every image of a multi-image post (Reddit galleries).
  List<Uri>? gallery;

  MediaItem({
    String? id,
    required this.siteId,
    required this.siteName,
    required this.title,
    this.thumbnailUrl,
    this.mediaUrl,
    this.pageUrl,
    required this.kind,
    this.duration,
    this.categoryName,
    DateTime? addedAt,
    this.isListing = false,
    this.gallery,
  })  : id = id ?? hashKey((pageUrl ?? mediaUrl ?? thumbnailUrl)?.toString() ?? DateTime.now().microsecondsSinceEpoch.toString()),
        addedAt = addedAt ?? DateTime.now();

  String get displayTitle => title.isEmpty ? siteName : title;
  Uri? get referer => pageUrl ?? thumbnailUrl;

  /// The category this item opens when it is a listing tile.
  SiteCategory? get asCategory {
    final p = pageUrl;
    if (p == null) return null;
    var name = title;
    if (name.isEmpty) {
      final seg = p.pathSegments.where((s) => s.isNotEmpty);
      name = seg.isEmpty ? p.host : seg.last.replaceAll('-', ' ');
    }
    return SiteCategory(name: name, url: p, thumbnailUrl: thumbnailUrl);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'siteId': siteId,
        'siteName': siteName,
        'title': title,
        'thumb': thumbnailUrl?.toString(),
        'media': mediaUrl?.toString(),
        'page': pageUrl?.toString(),
        'kind': kind.name,
        'duration': duration,
        'category': categoryName,
        'addedAt': addedAt.millisecondsSinceEpoch,
        if (isListing) 'listing': true,
        if (gallery != null) 'gallery': gallery!.map((e) => e.toString()).toList(),
      };

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
        id: j['id'] as String?,
        siteId: j['siteId'] as String? ?? '',
        siteName: j['siteName'] as String? ?? '',
        title: j['title'] as String? ?? '',
        thumbnailUrl: _u(j['thumb']),
        mediaUrl: _u(j['media']),
        pageUrl: _u(j['page']),
        kind: MediaKind.parse(j['kind'] as String?),
        duration: j['duration'] as String?,
        categoryName: j['category'] as String?,
        addedAt: DateTime.fromMillisecondsSinceEpoch(j['addedAt'] as int? ?? 0),
        isListing: j['listing'] == true,
        gallery: (j['gallery'] as List?)?.map((e) => Uri.parse(e as String)).toList(),
      );

  @override
  bool operator ==(Object other) => other is MediaItem && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

class SiteCategory {
  final String name;
  final Uri url;
  final Uri? thumbnailUrl;
  const SiteCategory({required this.name, required this.url, this.thumbnailUrl});

  String get id => url.toString();

  Map<String, dynamic> toJson() => {'name': name, 'url': url.toString(), 'thumb': thumbnailUrl?.toString()};
  factory SiteCategory.fromJson(Map<String, dynamic> j) =>
      SiteCategory(name: j['name'] as String, url: Uri.parse(j['url'] as String), thumbnailUrl: _u(j['thumb']));

  @override
  bool operator ==(Object other) => other is SiteCategory && other.url == url && other.name == name && other.thumbnailUrl == thumbnailUrl;
  @override
  int get hashCode => Object.hash(url, name);
}

enum RenderMode {
  auto,
  fast,
  full;

  String get label => switch (this) {
        RenderMode.auto => 'Automatic',
        RenderMode.fast => 'Fast (HTML)',
        RenderMode.full => 'Full (JavaScript)',
      };
}

class Site {
  final String id;
  String name;
  Uri url;
  String? searchTemplate;
  RenderMode renderMode;
  bool enabled;
  Uri? iconUrl;
  List<SiteCategory> categories;
  DateTime? lastRefreshed;
  final DateTime addedAt;

  Site({
    String? id,
    required this.name,
    required this.url,
    this.searchTemplate,
    this.renderMode = RenderMode.auto,
    this.enabled = true,
    this.iconUrl,
    List<SiteCategory>? categories,
    this.lastRefreshed,
    DateTime? addedAt,
  })  : id = id ?? hashKey('${DateTime.now().microsecondsSinceEpoch}$url'),
        categories = categories ?? [],
        addedAt = addedAt ?? DateTime.now();

  String get host => url.host.replaceFirst('www.', '');

  /// The category a link points to, when it is one of this site's categories.
  SiteCategory? categoryMatching(Uri? u) {
    if (u == null) return null;
    final k = matchKey(u);
    for (final c in categories) {
      if (matchKey(c.url) == k) return c;
    }
    return null;
  }

  Site copy() => Site.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url.toString(),
        'search': searchTemplate,
        'mode': renderMode.name,
        'enabled': enabled,
        'icon': iconUrl?.toString(),
        'categories': categories.map((c) => c.toJson()).toList(),
        'refreshed': lastRefreshed?.millisecondsSinceEpoch,
        'addedAt': addedAt.millisecondsSinceEpoch,
      };

  factory Site.fromJson(Map<String, dynamic> j) => Site(
        id: j['id'] as String,
        name: j['name'] as String,
        url: Uri.parse(j['url'] as String),
        searchTemplate: j['search'] as String?,
        renderMode: RenderMode.values.firstWhere((m) => m.name == j['mode'], orElse: () => RenderMode.auto),
        enabled: j['enabled'] as bool? ?? true,
        iconUrl: _u(j['icon']),
        categories: (j['categories'] as List? ?? []).map((e) => SiteCategory.fromJson(e as Map<String, dynamic>)).toList(),
        lastRefreshed: j['refreshed'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['refreshed'] as int),
        addedAt: DateTime.fromMillisecondsSinceEpoch(j['addedAt'] as int? ?? 0),
      );
}

/// Compares links regardless of scheme, "www.", case and a trailing slash.
String matchKey(Uri u) {
  var s = u.host.toLowerCase().replaceFirst('www.', '') + u.path.toLowerCase();
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (u.query.isNotEmpty) s += '?${u.query}';
  return s;
}

class HistoryEntry {
  final String id;
  final MediaItem item;
  final DateTime viewedAt;
  HistoryEntry({String? id, required this.item, required this.viewedAt}) : id = id ?? hashKey('${item.id}${viewedAt.microsecondsSinceEpoch}');

  Map<String, dynamic> toJson() => {'id': id, 'item': item.toJson(), 'at': viewedAt.millisecondsSinceEpoch};
  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        id: j['id'] as String?,
        item: MediaItem.fromJson(j['item'] as Map<String, dynamic>),
        viewedAt: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
      );
}

/// Result of opening an item: the real, playable media.
class ResolvedMedia {
  final Uri url;
  final MediaKind kind;
  final List<Uri> gallery;
  final Uri? referer;
  final bool isListing;
  const ResolvedMedia({required this.url, required this.kind, this.gallery = const [], this.referer, this.isListing = false});
}

class ScrapeResult {
  String? title;
  Uri? iconUrl;
  List<MediaItem> items = [];
  List<SiteCategory> categories = [];
  Uri? nextPage;
}

class Limits {
  static const maxSites = 50;
  static const maxItemsPerFeed = 400;
  static const maxHistory = 2000;
}
