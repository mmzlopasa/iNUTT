import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show DartPluginRegistrant;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:media_kit/media_kit.dart';
import 'package:workmanager/workmanager.dart';

import '../screens/forums.dart';
import 'feed_engine.dart';
import 'html.dart';
import 'models.dart';
import 'net.dart';
import 'scraper.dart';
import 'stores.dart';

// Continue watching

class ResumePoint {
  final MediaItem item;
  final double seconds;
  final double duration;
  final DateTime updatedAt;
  ResumePoint(this.item, this.seconds, this.duration, this.updatedAt);

  double get progress => duration > 0 ? (seconds / duration).clamp(0.0, 1.0) : 0;

  Map<String, dynamic> toJson() => {
    'item': item.toJson(),
    'seconds': seconds,
    'duration': duration,
    'at': updatedAt.millisecondsSinceEpoch,
  };

  static ResumePoint? fromJson(Object? j) {
    if (j is! Map) return null;
    return ResumePoint(
      MediaItem.fromJson((j['item'] as Map).cast<String, dynamic>()),
      (j['seconds'] as num?)?.toDouble() ?? 0,
      (j['duration'] as num?)?.toDouble() ?? 0,
      DateTime.fromMillisecondsSinceEpoch(j['at'] as int? ?? 0),
    );
  }
}

/// Where you stopped in each video, so it carries on from there and shows up under Continue watching.
class ResumeStore extends ChangeNotifier {
  static final ResumeStore shared = ResumeStore._();
  ResumeStore._();

  final Map<String, ResumePoint> _points = {};
  Timer? _save;
  bool _pending = false;

  void load() {
    final raw = Disk.load('resume.json');
    if (raw is List) {
      for (final p in raw.map(ResumePoint.fromJson).whereType<ResumePoint>()) {
        _points[p.item.id] = p;
      }
    }
  }

  /// Unfinished videos, most recent first.
  List<ResumePoint> get continueWatching => _points.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  /// The position to start from, when there is one worth resuming.
  Duration? position(String id) {
    final p = _points[id];
    if (p == null || p.seconds <= 5) return null;
    if (p.duration > 0 && p.seconds > p.duration - 8) return null;
    return Duration(milliseconds: (p.seconds * 1000).round());
  }

  void update(MediaItem item, Duration at, Duration length) {
    if (AppSettings.shared.privateMode) return;
    final s = at.inMilliseconds / 1000, d = length.inMilliseconds / 1000;
    if (s <= 0) return;
    if (d > 0 && (s >= d * 0.95 || d - s < 8)) return finished(item);
    if (s <= 5) return;
    _points[item.id] = ResumePoint(item, s, d, DateTime.now());
    if (_points.length > 60) {
      final oldest = _points.values.reduce((a, b) => a.updatedAt.isBefore(b.updatedAt) ? a : b);
      _points.remove(oldest.item.id);
    }
    _changed();
  }

  /// Watched to the end: off the Continue watching row and out of Watch later.
  void finished(MediaItem item) {
    WatchLater.shared.remove(item);
    if (_points.containsKey(item.id)) Taste.shared.learn(item, TasteSignal.finished);
    if (_points.remove(item.id) != null) _changed();
  }

  void remove(String id) {
    if (_points.remove(id) != null) _changed();
  }

  void clear() {
    _points.clear();
    _changed();
  }

  /// Screens under the viewer catch up once it closes.
  void flush() {
    if (!_pending) return;
    _pending = false;
    notifyListeners();
  }

  void _changed() {
    if (Library.shared.isHolding) {
      _pending = true;
    } else {
      notifyListeners();
    }
    _save?.cancel();
    _save = Timer(const Duration(seconds: 2), () => Disk.save('resume.json', _points.values.map((e) => e.toJson()).toList()));
  }
}

// Watch later

/// A queue separate from favorites. Pictures leave it once you have looked at them, videos once watched to the end.
class WatchLater extends ChangeNotifier {
  static final WatchLater shared = WatchLater._();
  WatchLater._();

  List<MediaItem> items = [];
  final Set<String> _ids = {};
  bool _pending = false;

  void load() {
    final raw = Disk.load('watchLater.json');
    if (raw is List) items = raw.map((e) => MediaItem.fromJson(e as Map<String, dynamic>)).toList();
    _ids.addAll(items.map((e) => e.id));
  }

  bool contains(MediaItem i) => _ids.contains(i.id);

  /// Returns true when the item is now in the queue.
  bool toggle(MediaItem item) {
    if (_ids.contains(item.id)) {
      remove(item);
      if (Disk.readOnly) WindowInbox.send({'t': 'later', 'on': false, 'item': item.toJson()});
      return false;
    }
    items.insert(0, item);
    _ids.add(item.id);
    Taste.shared.learn(item, TasteSignal.later);
    _changed(now: true);
    if (Disk.readOnly) WindowInbox.send({'t': 'later', 'on': true, 'item': item.toJson()});
    return true;
  }

  /// Used by sync: the queue as merged with your other devices.
  void replaceAll(List<MediaItem> list) {
    if (list.length == items.length && Iterable<int>.generate(list.length).every((i) => list[i].id == items[i].id)) return;
    items = list;
    _ids
      ..clear()
      ..addAll(list.map((e) => e.id));
    _changed(now: true);
  }

  void remove(MediaItem item) => removeIds({item.id});

  void removeIds(Set<String> gone) {
    final hit = gone.intersection(_ids);
    if (hit.isEmpty) return;
    items.removeWhere((e) => hit.contains(e.id));
    _ids.removeAll(hit);
    _changed();
  }

  void clear() {
    items = [];
    _ids.clear();
    _changed(now: true);
  }

  void flush() {
    if (!_pending) return;
    _pending = false;
    notifyListeners();
  }

  void _changed({bool now = false}) {
    if (!now && Library.shared.isHolding) {
      _pending = true;
    } else {
      notifyListeners();
    }
    Disk.save('watchLater.json', items.map((e) => e.toJson()).toList());
  }
}

// Login carries over

/// Sign-ins from the in-app browser are used by Home, Sites, Search and the player as well.
class CookieJar {
  static final Map<String, Map<String, String>> _byHost = {};

  static void load() {
    final raw = Disk.load('cookies.json');
    if (raw is Map) {
      raw.forEach((h, v) {
        if (v is Map) _byHost[h as String] = v.map((k, x) => MapEntry(k as String, '$x'));
      });
    }
  }

  static String _site(String host) {
    final p = host.toLowerCase().split('.');
    return p.length <= 2 ? host.toLowerCase() : p.sublist(p.length - 2).join('.');
  }

  /// Cookies the browser holds for a page, kept for later requests to that site.
  static Future<void> capture(Uri? url) async {
    if (url == null || !url.scheme.startsWith('http')) return;
    try {
      final list = await CookieManager.instance().getCookies(url: WebUri.uri(url));
      if (list.isEmpty) return;
      final m = _byHost.putIfAbsent(_site(url.host), () => {});
      for (final c in list) {
        m[c.name] = '${c.value}';
      }
      unawaited(Disk.save('cookies.json', _byHost));
    } catch (_) {}
  }

  /// The Cookie header value for a request, or null.
  static String? headerFor(Uri url) {
    final m = _byHost[_site(url.host)];
    if (m == null || m.isEmpty) return null;
    return m.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  static void clear() {
    _byHost.clear();
    unawaited(Disk.save('cookies.json', _byHost));
  }
}

// Offline

/// Favorites and chosen collections downloaded on Wi-Fi, so they open without a connection.
class OfflineStore extends ChangeNotifier {
  static final OfflineStore shared = OfflineStore._();
  OfflineStore._();

  /// id -> {file, kind, size}
  final Map<String, Map<String, dynamic>> _entries = {};
  bool syncing = false;
  bool onWiFi = false;
  bool _again = false;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  String get _dir => '${Disk.dir.path}${Platform.pathSeparator}Offline';

  void load() {
    final raw = Disk.load('offline.json');
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is Map) _entries[k as String] = v.cast<String, dynamic>();
      });
    }
    Connectivity().checkConnectivity().then(_net, onError: (_) {});
    _sub = Connectivity().onConnectivityChanged.listen(_net, onError: (_) {});
  }

  void _net(List<ConnectivityResult> r) {
    final was = onWiFi;
    // Phones only download on Wi-Fi; a computer on a cable counts too.
    onWiFi = r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
    if (onWiFi && !was) sync();
    notifyListeners();
  }

  void stop() => _sub?.cancel();

  int get count => _entries.length;
  int get totalSize => _entries.values.fold(0, (a, e) => a + ((e['size'] as int?) ?? 0));

  /// The downloaded copy of an item, when there is one.
  ResolvedMedia? local(String id) {
    final e = _entries[id];
    if (e == null) return null;
    final f = File('$_dir${Platform.pathSeparator}${e['file']}');
    if (!f.existsSync()) return null;
    return ResolvedMedia(url: f.uri, kind: MediaKind.parse(e['kind'] as String?));
  }

  bool isOfflineCollection(String id) => AppSettings.shared.offlineCollections.contains(id);

  void toggleCollection(String id) {
    final s = [...AppSettings.shared.offlineCollections];
    if (!s.remove(id)) s.add(id);
    AppSettings.shared.offlineCollections = s;
    sync();
  }

  List<MediaItem> get _wanted {
    final out = <MediaItem>[];
    final seen = <String>{};
    if (AppSettings.shared.offlineFavorites) {
      for (final i in Library.shared.favorites) {
        if (seen.add(i.id)) out.add(i);
      }
    }
    final cols = AppSettings.shared.offlineCollections.toSet();
    for (final c in CollectionStore.shared.collections.where((c) => cols.contains(c.id))) {
      for (final i in c.items) {
        if (seen.add(i.id)) out.add(i);
      }
    }
    return out.where((e) => !e.isListing).toList();
  }

  /// Downloads what is missing (Wi-Fi only) and removes what is no longer wanted.
  void sync() {
    if (syncing) {
      _again = true;
      return;
    }
    final want = _wanted;
    final keep = want.map((e) => e.id).toSet();
    for (final id in _entries.keys.where((k) => !keep.contains(k)).toList()) {
      try {
        File('$_dir${Platform.pathSeparator}${_entries[id]!['file']}').deleteSync();
      } catch (_) {}
      _entries.remove(id);
    }
    _save();
    final missing = want.where((e) => !_entries.containsKey(e.id)).toList();
    if (!onWiFi || missing.isEmpty) return;
    syncing = true;
    notifyListeners();
    () async {
      for (final item in missing) {
        if (!onWiFi || !_wanted.any((e) => e.id == item.id)) continue;
        await _fetch(item);
      }
      syncing = false;
      notifyListeners();
      if (_again) {
        _again = false;
        sync();
      }
    }();
  }

  void removeAll() {
    try {
      final d = Directory(_dir);
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
    _entries.clear();
    _save();
  }

  Future<void> _fetch(MediaItem item) async {
    try {
      final r = await FeedEngine.shared.resolve(item, priority: RenderPriority.background);
      if (r == null || r.isListing || r.url.scheme == 'file' || r.url.toString().contains('.m3u8')) return;
      await Directory(_dir).create(recursive: true);
      var ext = r.url.pathSegments.isEmpty ? '' : r.url.pathSegments.last.split('.').last.toLowerCase();
      if (!const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'mp4', 'webm', 'mov', 'm4v'].contains(ext)) {
        ext = r.kind == MediaKind.video ? 'mp4' : (r.kind == MediaKind.gif ? 'gif' : 'jpg');
      }
      final name = '${item.id}.$ext';
      final f = File('$_dir${Platform.pathSeparator}$name');
      final size = await Net.download(r.url, f, referer: r.referer);
      _entries[item.id] = {'file': name, 'kind': r.kind.name, 'size': size};
      _save();
    } catch (_) {}
  }

  void _save() {
    notifyListeners();
    unawaited(Disk.save('offline.json', _entries));
  }
}

// New-content notifications

/// Checks the sites and forums you follow and tells you when something new is there.
/// Android checks in the background; Windows while iNUTT is open or minimized.
class NewContentWatcher {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static Timer? _timer;
  static const task = 'inutt-new-content';

  static Future<void> _init() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        windows: WindowsInitializationSettings(
          appName: 'iNUTT',
          appUserModelId: 'Scyde.iNUTT.App',
          guid: '6c1f7b9e-3a52-4d8b-9e1f-2b7c0d4a5e61',
        ),
      ),
    );
    _ready = true;
  }

  static Future<bool> requestPermission() async {
    try {
      await _init();
      if (Platform.isAndroid) {
        final a = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        return await a?.requestNotificationsPermission() ?? true;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Starts the periodic check (background on Android, a timer on Windows).
  static Future<void> start() async {
    _timer?.cancel();
    if (!AppSettings.shared.notifyNew) {
      if (Platform.isAndroid) {
        try {
          await Workmanager().cancelByUniqueName(task);
        } catch (_) {}
      }
      return;
    }
    if (Platform.isAndroid) {
      try {
        await Workmanager().initialize(backgroundDispatcher);
        await Workmanager().registerPeriodicTask(
          task,
          task,
          frequency: const Duration(minutes: 30),
          constraints: Constraints(networkType: NetworkType.connected),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        );
      } catch (e) {
        debugPrint('workmanager: $e');
      }
    } else {
      _timer = Timer.periodic(const Duration(minutes: 30), (_) => checkAndNotify());
    }
  }

  static Map<String, List<String>> _seen = {};
  static bool _loaded = false;

  /// Returns what is new per followed site or forum, and remembers it so it is counted once.
  static Future<List<(String, int)>> check() async {
    final s = AppSettings.shared;
    if (!s.notifyNew) return const [];
    if (!_loaded) {
      final raw = Disk.load('watch.json');
      if (raw is Map) _seen = raw.map((k, v) => MapEntry(k as String, (v as List).cast<String>()));
      _loaded = true;
    }
    final found = <(String, int)>[];
    for (final site in SiteStore.shared.sites.where((e) => s.watchedSites.contains(e.id))) {
      try {
        final r = await FeedEngine.fetchListing(site.url, site.url, site, null, allowRender: false);
        final ids = Blocklist.filter(r.items).where((e) => !e.isListing).map((e) => e.id).toList();
        final n = _note('s:${site.id}', ids);
        if (n > 0) found.add((site.name, n));
      } catch (_) {}
    }
    for (final f in ForumStore.shared.forums.where((e) => s.watchedForums.contains(e.id))) {
      try {
        final page = f.lastUrl ?? f.url;
        final html = (await Net.fetch(page)).text;
        final n = _note('f:${f.id}', forumKeys(html, page));
        if (n > 0) found.add((f.name, n));
      } catch (_) {}
    }
    await Disk.save('watch.json', _seen);
    return found;
  }

  /// Counts keys not seen before. The first look only sets the starting point.
  static int _note(String key, List<String> ids) {
    if (ids.isEmpty) return 0;
    final before = _seen[key];
    final known = (before ?? const []).toSet();
    final fresh = ids.where((e) => !known.contains(e)).toList();
    final merged = [...fresh, ...?before];
    _seen[key] = merged.length > 300 ? merged.sublist(0, 300) : merged;
    return before == null ? 0 : fresh.length;
  }

  /// Pictures, videos and thread links of a forum page.
  static List<String> forumKeys(String html, Uri base) {
    final out = Scraper.rawMediaUrls(html, base).map((e) => e.toString()).toList();
    for (final m in Html.matches(r'''href=["']([^"']*(?:thread|topic|showthread|/t/|viewtopic)[^"']*)["']''', html, limit: 400)) {
      final u = Html.resolve(m[1], base);
      if (u != null) out.add(matchKey(u));
    }
    final seen = <String>{};
    return out.where(seen.add).toList();
  }

  static Future<void> checkAndNotify() async {
    final found = await check();
    if (found.isEmpty) return;
    await _init();
    final body = AppSettings.shared.notifyDiscreet
        ? 'New content is waiting'
        : found.take(4).map((e) => '${e.$1}: ${e.$2} new').join(' · ');
    await _plugin.show(
      id: 7,
      title: 'iNUTT',
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'new-content',
          'New content',
          channelDescription: 'Sites and forums you follow',
          importance: Importance.defaultImportance,
          // Nothing of the content shows on the lock screen.
          visibility: NotificationVisibility.private,
        ),
      ),
    );
  }
}

/// Runs in the background on Android, without the app's screens.
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    try {
      DartPluginRegistrant.ensureInitialized();
      await Disk.init();
      await AppSettings.shared.load();
      SiteStore.shared.load();
      CookieJar.load();
      await NewContentWatcher.checkAndNotify();
    } catch (e) {
      debugPrint('background check: $e');
    }
    return true;
  });
}

// Smart mix

enum TasteSignal {
  open(1),
  later(2),
  finished(3),
  download(3),
  favorite(4);

  const TasteSignal(this.weight);
  final double weight;
}

/// Learns what you open, save and watch to the end, and scores items by it for "Picked for you" on Home.
class Taste extends ChangeNotifier {
  static final Taste shared = Taste._();
  Taste._();

  Map<String, double> _weights = {};
  int _signals = 0;
  Timer? _save;

  void load() {
    final raw = Disk.load('taste.json');
    if (raw is Map) {
      _weights = ((raw['weights'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, (v as num).toDouble()));
      _signals = (raw['signals'] as num?)?.toInt() ?? 0;
    }
  }

  /// Enough has been learned for the picks to mean something.
  bool get isReady => _signals >= 5;

  static List<String> features(MediaItem item) {
    final f = ['s:${item.siteId}', 'k:${item.kind.name}'];
    final c = item.categoryName?.toLowerCase();
    if (c != null && c.isNotEmpty) f.add('c:$c');
    final words = item.title
        .toLowerCase()
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((w) => w.length >= 4 && !RegExp(r'^\d+$').hasMatch(w))
        .toSet()
        .toList()
      ..sort();
    f.addAll(words.take(12).map((w) => 'w:$w'));
    return f;
  }

  void learn(MediaItem item, TasteSignal signal) {
    final s = AppSettings.shared;
    if (!s.smartMix || s.privateMode || item.isFromForum) return;
    // Older taste fades slowly, so the mix follows what you like now.
    if (_signals % 50 == 49) {
      _weights = _weights.map((k, v) => MapEntry(k, v * 0.9))..removeWhere((k, v) => v <= 0.05);
    }
    for (final k in features(item)) {
      _weights[k] = (_weights[k] ?? 0) + signal.weight;
    }
    if (_weights.length > 3000) {
      final top = _weights.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      _weights = Map.fromEntries(top.take(2500));
    }
    _signals++;
    _save?.cancel();
    _save = Timer(const Duration(seconds: 3), () => Disk.save('taste.json', {'weights': _weights, 'signals': _signals}));
  }

  double score(MediaItem item) {
    var total = 0.0;
    for (final k in features(item)) {
      final w = _weights[k];
      if (w == null) continue;
      final factor = k.startsWith('s:') ? 0.6 : (k.startsWith('k:') ? 0.3 : 1.0);
      total += math.log(1 + w) * factor;
    }
    return total;
  }

  /// The best matches among the given items, new ones first.
  List<MediaItem> picks(List<MediaItem> items, {int limit = 20}) {
    if (!isReady) return const [];
    final lib = Library.shared;
    final scored = <(MediaItem, double)>[];
    for (final i in items.take(1500)) {
      final s = score(i) * (lib.isSeen(i) ? 0.4 : 1);
      if (s > 0) scored.add((i, s));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(limit).map((e) => e.$1).toList();
  }

  void reset() {
    _weights = {};
    _signals = 0;
    Disk.save('taste.json', {'weights': <String, double>{}, 'signals': 0});
    notifyListeners();
  }
}

// Video without waiting

/// The next video opens paused on the page after yours; this makes its player keep downloading
/// ahead while paused, so it starts the moment you swipe to it, like TikTok.
Future<void> bufferAhead(Player p) async {
  final native = p.platform;
  if (native is! NativePlayer) return;
  try {
    await native.setProperty('cache', 'yes');
    await native.setProperty('cache-pause-initial', 'no');
    await native.setProperty('demuxer-readahead-secs', '20');
  } catch (_) {}
}
