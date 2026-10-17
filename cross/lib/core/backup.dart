import 'dart:convert';
import 'dart:io';

import '../screens/forums.dart';
import 'feed_engine.dart';
import 'models.dart';
import 'stores.dart';

/// One file with your sites, forums, favorites, collections and blocked words. The same format is
/// used on iOS, Android and Windows, so a backup from one restores on the others.
class Backup {
  static Map<String, dynamic> _pack(MediaItem i) => {
    'title': i.title,
    'siteName': i.siteName,
    'thumbnailUrl': ?i.thumbnailUrl?.toString(),
    'mediaUrl': ?i.mediaUrl?.toString(),
    'pageUrl': ?i.pageUrl?.toString(),
    'kind': i.kind.name,
    'duration': ?i.duration,
    'categoryName': ?i.categoryName,
  };

  static MediaItem? _unpack(Object? raw) {
    if (raw is! Map) return null;
    Uri? u(String k) => raw[k] is String ? Uri.tryParse(raw[k] as String) : null;
    final thumb = u('thumbnailUrl'), media = u('mediaUrl'), page = u('pageUrl');
    if (thumb == null && media == null && page == null) return null;
    final siteName = raw['siteName'] as String? ?? '';
    final site = SiteStore.shared.sites.where((s) => s.name == siteName).firstOrNull;
    return MediaItem(
      siteId: site?.id ?? 'backup',
      siteName: siteName,
      title: raw['title'] as String? ?? '',
      thumbnailUrl: thumb,
      mediaUrl: media,
      pageUrl: page,
      kind: MediaKind.parse(raw['kind'] as String?),
      duration: raw['duration'] as String?,
      categoryName: raw['categoryName'] as String?,
    );
  }

  static String exportJson() => const JsonEncoder.withIndent('  ').convert({
    'app': 'iNUTT',
    'version': 1,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'sites': [
      for (final s in SiteStore.shared.sites)
        {
          'name': s.name,
          'url': s.url.toString(),
          'enabled': s.enabled,
          'searchTemplate': ?s.searchTemplate,
          'renderMode': s.renderMode.name,
        },
    ],
    'forums': [
      for (final f in ForumStore.shared.forums) {'name': f.name, 'url': f.url.toString()},
    ],
    'favorites': Library.shared.favorites.map(_pack).toList(),
    'collections': [
      for (final c in CollectionStore.shared.collections) {'name': c.name, 'items': c.items.map(_pack).toList()},
    ],
    'settings': {'blockedWords': AppSettings.shared.blockedWords, 'reelsSource': AppSettings.shared.reelsSource},
  });

  /// Writes a backup file and returns it.
  static Future<File> exportFile() async {
    final d = DateTime.now();
    final day = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}iNUTT-backup-$day.json');
    await f.writeAsString(exportJson());
    return f;
  }

  /// Adds everything from a backup to what is already here; nothing is removed.
  /// Returns a short summary, or throws when the file isn't a backup.
  static String restore(String text) {
    final j = jsonDecode(text);
    if (j is! Map || j['sites'] is! List) throw const FormatException('Not an iNUTT backup');
    var sites = 0, forums = 0;
    for (final e in (j['sites'] as List).whereType<Map>()) {
      final u = Uri.tryParse(e['url'] as String? ?? '');
      if (u == null || !u.hasScheme) continue;
      final site = Site(
        name: e['name'] as String? ?? u.host,
        url: u,
        enabled: e['enabled'] as bool? ?? true,
        searchTemplate: e['searchTemplate'] as String?,
        renderMode: RenderMode.values.firstWhere((m) => m.name == e['renderMode'], orElse: () => RenderMode.auto),
      );
      if (SiteStore.shared.add(site)) sites++;
    }
    final haveForums = ForumStore.shared.forums.map((f) => f.url.toString().toLowerCase()).toSet();
    for (final e in (j['forums'] as List? ?? const []).whereType<Map>()) {
      final url = e['url'] as String? ?? '';
      if (haveForums.contains(url.toLowerCase())) continue;
      if (ForumStore.shared.add(e['name'] as String? ?? '', url)) forums++;
    }
    final favs = (j['favorites'] as List? ?? const []).map(_unpack).whereType<MediaItem>().toList();
    final newFavs = Library.shared.mergeFavorites(favs);
    final cols = [
      for (final c in (j['collections'] as List? ?? const []).whereType<Map>())
        MediaCollection(
          name: c['name'] as String? ?? 'Collection',
          items: (c['items'] as List? ?? const []).map(_unpack).whereType<MediaItem>().toList(),
        ),
    ];
    CollectionStore.shared.merge(cols);
    final settings = j['settings'];
    if (settings is Map) {
      final words = (settings['blockedWords'] as List? ?? const []).whereType<String>();
      final merged = [...AppSettings.shared.blockedWords];
      for (final w in words) {
        if (!merged.any((m) => m.toLowerCase() == w.toLowerCase())) merged.add(w);
      }
      if (merged.length != AppSettings.shared.blockedWords.length) AppSettings.shared.blockedWords = merged;
      final r = settings['reelsSource'] as String? ?? '';
      if (r.isNotEmpty && AppSettings.shared.reelsSource.isEmpty) AppSettings.shared.reelsSource = r;
    }
    if (sites > 0) FeedEngine.shared.refreshAll();
    return 'Added $sites sites, $forums forums, $newFavs favorites and ${cols.length} collections.';
  }
}
