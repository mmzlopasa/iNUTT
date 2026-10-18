import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'extras.dart';
import 'models.dart';

/// JSON files in the app's support folder.
class Disk {
  static late Directory dir;

  static Future<void> init() async {
    dir = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}iNUTT');
    await dir.create(recursive: true);
  }

  static dynamic load(String name) {
    try {
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      if (!f.existsSync()) return null;
      return jsonDecode(f.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  static final Map<String, Future<void>> _pending = {};

  static Future<String> _encode(Object value) => Isolate.run(() => jsonEncode(value));
  static int _seq = 0;

  /// Saves one file at a time per name, each through its own temporary file, so quick
  /// successive saves can never interleave and leave a broken file behind.
  /// A second window (Windows "Open in new window") never writes the stores; its changes go to
  /// the main window through [WindowInbox] instead, so the two never overwrite each other.
  static bool readOnly = false;

  static Future<void> save(String name, Object value) {
    if (readOnly) return Future<void>.value();
    // Encoding a large feed takes long enough to drop frames, so it runs in its own isolate.
    final encoded = _encode(value);
    final prev = _pending[name] ?? Future<void>.value();
    final next = prev.then((_) async {
      final String text;
      try {
        text = await encoded;
      } catch (e) {
        debugPrint('encode $name failed: $e');
        return;
      }
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      final tmp = File('${f.path}.${_seq++}.tmp');
      try {
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(f.path);
      } catch (e) {
        debugPrint('save $name failed: $e');
        try {
          if (tmp.existsSync()) await tmp.delete();
        } catch (_) {}
      }
    });
    _pending[name] = next;
    return next;
  }
}

class SiteStore extends ChangeNotifier {
  static final SiteStore shared = SiteStore._();
  SiteStore._();

  List<Site> sites = [];

  void load() {
    final raw = Disk.load('sites.json');
    if (raw is List) sites = raw.map((e) => Site.fromJson(e as Map<String, dynamic>)).toList();
  }

  void _save() {
    notifyListeners();
    Disk.save('sites.json', sites.map((s) => s.toJson()).toList());
  }

  List<Site> get enabledSites => sites.where((s) => s.enabled).toList();
  bool get canAdd => sites.length < Limits.maxSites;

  Site? site(String id) {
    for (final s in sites) {
      if (s.id == id) return s;
    }
    return null;
  }

  bool add(Site s) {
    if (!canAdd || sites.any((e) => matchKey(e.url) == matchKey(s.url))) return false;
    sites.add(s);
    _save();
    return true;
  }

  void update(Site s) {
    final i = sites.indexWhere((e) => e.id == s.id);
    if (i < 0) return;
    sites[i] = s;
    _save();
  }

  void remove(String id) {
    sites.removeWhere((s) => s.id == id);
    _save();
  }

  /// Used by sync: the merged list of sites from all your devices.
  void replaceAll(List<Site> list) {
    if (listEquals(list.map((e) => e.id).toList(), sites.map((e) => e.id).toList())) return;
    sites = list;
    _save();
  }

  void move(int from, int to) {
    final s = sites.removeAt(from);
    sites.insert(to > from ? to - 1 : to, s);
    _save();
  }

  static Uri? normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    // "r/pics", "/r/pics", "u/name" and "reddit.com/..." all mean Reddit.
    final lower = s.toLowerCase();
    if (lower.startsWith('r/') || lower.startsWith('u/') || lower.startsWith('user/')) {
      s = 'https://www.reddit.com/$s';
    } else if (lower.startsWith('/r/') || lower.startsWith('/u/')) {
      s = 'https://www.reddit.com$s';
    }
    if (!s.toLowerCase().startsWith('http://') && !s.toLowerCase().startsWith('https://')) s = 'https://$s';
    final u = Uri.tryParse(s);
    if (u == null || !u.host.contains('.')) return null;
    return u;
  }
}

class Library extends ChangeNotifier {
  static final Library shared = Library._();
  Library._();

  List<MediaItem> favorites = [];
  List<HistoryEntry> history = [];
  final Set<String> _favIds = {};
  final Set<String> _seenIds = {};

  /// Already opened once; cards show it.
  bool isSeen(MediaItem i) => _seenIds.contains(i.id);

  /// Changes only when favorites change, so grids don't redraw on every history entry.
  final ValueNotifier<int> favoritesVersion = ValueNotifier(0);

  void load() {
    final f = Disk.load('favorites.json');
    if (f is List) favorites = f.map((e) => MediaItem.fromJson(e as Map<String, dynamic>)).toList();
    final h = Disk.load('history.json');
    if (h is List) history = h.map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>)).toList();
    _favIds.addAll(favorites.map((e) => e.id));
    _seenIds.addAll(history.map((e) => e.item.id));
  }

  bool isFavorite(MediaItem i) => _favIds.contains(i.id);

  /// Used by sync: the list as merged with your other devices.
  void replaceFavorites(List<MediaItem> items) {
    if (_sameIds(items, favorites)) return;
    favorites = items;
    _favIds
      ..clear()
      ..addAll(items.map((e) => e.id));
    favoritesVersion.value++;
    notifyListeners();
    Disk.save('favorites.json', favorites.map((e) => e.toJson()).toList());
    if (AppSettings.shared.offlineFavorites) OfflineStore.shared.sync();
  }

  /// Used by backup restore. Returns how many were new.
  int mergeFavorites(List<MediaItem> items) {
    final fresh = items.where((e) => !_favIds.contains(e.id)).toList();
    if (fresh.isEmpty) return 0;
    favorites.addAll(fresh);
    _favIds.addAll(fresh.map((e) => e.id));
    favoritesVersion.value++;
    notifyListeners();
    Disk.save('favorites.json', favorites.map((e) => e.toJson()).toList());
    return fresh.length;
  }

  void toggleFavorite(MediaItem item) {
    if (_favIds.remove(item.id)) {
      favorites.removeWhere((e) => e.id == item.id);
    } else {
      _favIds.add(item.id);
      favorites.insert(0, item);
      Taste.shared.learn(item, TasteSignal.favorite);
    }
    favoritesVersion.value++;
    notifyListeners();
    Disk.save('favorites.json', favorites.map((e) => e.toJson()).toList());
    if (AppSettings.shared.offlineFavorites) OfflineStore.shared.sync();
    if (Disk.readOnly) WindowInbox.send({'t': 'fav', 'on': isFavorite(item), 'item': item.toJson()});
  }

  /// While the viewer or Reels is open, screens underneath are not redrawn for every swipe;
  /// they catch up once when it closes.
  int _hold = 0;
  bool _dirty = false;
  Timer? _historySave;

  void holdUpdates() => _hold++;
  bool get isHolding => _hold > 0;

  void releaseUpdates() {
    if (_hold > 0) _hold--;
    if (_hold == 0) {
      ResumeStore.shared.flush();
      WatchLater.shared.flush();
    }
    if (_hold == 0 && _dirty) {
      _dirty = false;
      favoritesVersion.value++;
      notifyListeners();
    }
  }

  void record(MediaItem item) {
    if (!AppSettings.shared.historyEnabled || AppSettings.shared.privateMode || item.isListing) return;
    history.removeWhere((e) => e.item.id == item.id);
    history.insert(0, HistoryEntry(item: item, viewedAt: DateTime.now()));
    Taste.shared.learn(item, TasteSignal.open);
    final firstTime = _seenIds.add(item.id);
    if (history.length > Limits.maxHistory) history = history.sublist(0, Limits.maxHistory);
    // Saving 2000 entries on every swipe is wasted work; once things settle is enough.
    _historySave?.cancel();
    _historySave = Timer(const Duration(seconds: 2), () => Disk.save('history.json', history.map((e) => e.toJson()).toList()));
    if (_hold > 0) {
      _dirty = true;
      return;
    }
    // Grids redraw once, the first time something is opened.
    if (firstTime) favoritesVersion.value++;
    notifyListeners();
  }

  void removeHistory(Set<String> ids) {
    history.removeWhere((e) => ids.contains(e.id));
    _seenIds
      ..clear()
      ..addAll(history.map((e) => e.item.id));
    favoritesVersion.value++;
    _saveHistory();
  }

  /// Used by sync: history as merged with your other devices.
  void replaceHistory(List<HistoryEntry> list) {
    final same = listEquals(list.map((e) => e.item.id).toList(), history.map((e) => e.item.id).toList());
    if (same && list.firstOrNull?.viewedAt == history.firstOrNull?.viewedAt) return;
    history = list;
    _seenIds
      ..clear()
      ..addAll(list.map((e) => e.item.id));
    favoritesVersion.value++;
    _saveHistory();
  }

  void clearHistory() {
    history = [];
    _seenIds.clear();
    favoritesVersion.value++;
    _saveHistory();
  }

  void _saveHistory() {
    notifyListeners();
    Disk.save('history.json', history.map((e) => e.toJson()).toList());
  }
}

/// Hides items whose title, category or link contains a blocked word.
class Blocklist {
  static List<String> _words = const [];

  static void update(List<String> list) => _words = list.map((w) => w.trim().toLowerCase()).where((w) => w.isNotEmpty).toList();

  static bool blocks(MediaItem i) {
    if (_words.isEmpty) return false;
    final hay = '${i.title} ${i.categoryName ?? ''} ${i.pageUrl?.path ?? ''} ${i.mediaUrl?.path ?? ''}'.toLowerCase();
    return _words.any(hay.contains);
  }

  static List<MediaItem> filter(List<MediaItem> items) => _words.isEmpty ? items : items.where((i) => !blocks(i)).toList();
}

class MediaCollection {
  final String id;
  String name;
  List<MediaItem> items;
  MediaCollection({String? id, required this.name, List<MediaItem>? items})
    : id = id ?? hashKey('${DateTime.now().microsecondsSinceEpoch}$name'),
      items = items ?? [];

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'items': items.map((e) => e.toJson()).toList()};
  factory MediaCollection.fromJson(Map<String, dynamic> j) => MediaCollection(
    id: j['id'] as String?,
    name: j['name'] as String? ?? 'Collection',
    items: (j['items'] as List? ?? []).map((e) => MediaItem.fromJson(e as Map<String, dynamic>)).toList(),
  );
}

/// Your own folders of saved items, next to Favorites.
class CollectionStore extends ChangeNotifier {
  static final CollectionStore shared = CollectionStore._();
  CollectionStore._();

  List<MediaCollection> collections = [];

  void load() {
    final raw = Disk.load('collections.json');
    if (raw is List) collections = raw.map((e) => MediaCollection.fromJson(e as Map<String, dynamic>)).toList();
  }

  void _save() {
    notifyListeners();
    Disk.save('collections.json', collections.map((c) => c.toJson()).toList());
  }

  MediaCollection? create(String name, [MediaItem? item]) {
    final n = name.trim();
    if (n.isEmpty) return null;
    final c = MediaCollection(name: n, items: [?item]);
    collections.add(c);
    _save();
    return c;
  }

  bool contains(MediaItem item, String id) => collections.any((c) => c.id == id && c.items.any((e) => e.id == item.id));
  bool inAny(MediaItem item) => collections.any((c) => c.items.any((e) => e.id == item.id));

  /// Adds the item, or takes it out when it is already there. Returns true when it was added.
  bool toggle(MediaItem item, String id) {
    final c = collections.where((c) => c.id == id).firstOrNull;
    if (c == null) return false;
    final had = c.items.any((e) => e.id == item.id);
    if (had) {
      c.items.removeWhere((e) => e.id == item.id);
    } else {
      c.items.insert(0, item);
    }
    _save();
    if (Disk.readOnly) WindowInbox.send({'t': 'col', 'id': id, 'on': !had, 'item': item.toJson()});
    return !had;
  }

  void rename(String id, String name) {
    final n = name.trim();
    final c = collections.where((c) => c.id == id).firstOrNull;
    if (n.isEmpty || c == null) return;
    c.name = n;
    _save();
  }

  void delete(String id) {
    collections.removeWhere((c) => c.id == id);
    _save();
  }

  /// Used by sync: the collections as merged with your other devices.
  void replaceAll(List<MediaCollection> list) {
    final same =
        list.length == collections.length &&
        Iterable<int>.generate(list.length)
            .every((i) => list[i].name == collections[i].name && _sameIds(list[i].items, collections[i].items));
    if (same) return;
    collections = list;
    _save();
  }

  /// Used by backup restore.
  void merge(List<MediaCollection> incoming) {
    for (final c in incoming) {
      final have = collections.where((e) => e.name.toLowerCase() == c.name.toLowerCase()).firstOrNull;
      if (have == null) {
        collections.add(c);
      } else {
        final ids = have.items.map((e) => e.id).toSet();
        have.items.addAll(c.items.where((e) => !ids.contains(e.id)));
      }
    }
    _save();
  }
}

class AppSettings extends ChangeNotifier {
  static final AppSettings shared = AppSettings._();
  AppSettings._();

  late SharedPreferences _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    Blocklist.update(blockedWords);
  }

  bool _b(String k, bool d) => _p.getBool(k) ?? d;
  void _sb(String k, bool v) {
    _p.setBool(k, v);
    notifyListeners();
  }

  bool get biometricEnabled => _b('biometric', false);
  set biometricEnabled(bool v) => _sb('biometric', v);
  bool get pinEnabled => _b('pin', false);
  set pinEnabled(bool v) => _sb('pin', v);
  bool get lockOnBackground => _b('lockOnBackground', true);
  set lockOnBackground(bool v) => _sb('lockOnBackground', v);
  bool get historyEnabled => _b('history', true);
  set historyEnabled(bool v) => _sb('history', v);
  bool get autoplay => _b('autoplay', true);
  set autoplay(bool v) => _sb('autoplay', v);
  bool get loopVideos => _b('loop', true);
  set loopVideos(bool v) => _sb('loop', v);
  bool get startMuted => _b('muted', false);
  set startMuted(bool v) => _sb('muted', v);
  bool get saveToGallery => _b('saveToGallery', true);
  set saveToGallery(bool v) => _sb('saveToGallery', v);
  bool get onboarded => _b('onboarded', false);
  set onboarded(bool v) => _sb('onboarded', v);
  bool get hideInSwitcher => _b('hideInSwitcher', false);
  set hideInSwitcher(bool v) => _sb('hideInSwitcher', v);

  /// Reels move on to the next video when one ends.
  bool get reelsAutoNext => _b('reelsAutoNext', false);
  set reelsAutoNext(bool v) => _sb('reelsAutoNext', v);

  /// Home leaves out what you have already opened.
  bool get hideSeen => _b('hideSeen', false);
  set hideSeen(bool v) => _sb('hideSeen', v);

  /// Words that hide items everywhere.
  List<String> get blockedWords => _p.getStringList('blockedWords') ?? [];
  set blockedWords(List<String> v) {
    _p.setStringList('blockedWords', v);
    Blocklist.update(v);
    blocklistVersion.value++;
    notifyListeners();
  }

  /// Bumped when blocked words change, so feeds are worked out again.
  final ValueNotifier<int> blocklistVersion = ValueNotifier(0);

  int get slideshowSeconds => _p.getInt('slideshowSeconds') ?? 5;
  set slideshowSeconds(int v) {
    _p.setInt('slideshowSeconds', v);
    notifyListeners();
  }

  bool get slideshowRandom => _b('slideshowRandom', false);
  set slideshowRandom(bool v) => _sb('slideshowRandom', v);

  /// Downloads go into the encrypted vault inside the app instead of the gallery or Downloads.
  bool get vaultDownloads => _b('vaultDownloads', false);
  set vaultDownloads(bool v) => _sb('vaultDownloads', v);

  bool get shakeToLock => _b('shakeToLock', false);
  set shakeToLock(bool v) => _sb('shakeToLock', v);

  /// Nothing is remembered: no history, no seen marks, no resume points, no recent searches.
  bool get privateMode => _b('privateMode', false);
  set privateMode(bool v) => _sb('privateMode', v);

  /// Favorites are downloaded on Wi-Fi so they open offline.
  bool get offlineFavorites => _b('offlineFavorites', false);
  set offlineFavorites(bool v) => _sb('offlineFavorites', v);
  List<String> get offlineCollections => _p.getStringList('offlineCollections') ?? [];
  set offlineCollections(List<String> v) {
    _p.setStringList('offlineCollections', v);
    notifyListeners();
  }

  /// The same picture or video from several sites is shown once.
  bool get hideDuplicates => _b('hideDuplicates', true);
  set hideDuplicates(bool v) {
    _sb('hideDuplicates', v);
    blocklistVersion.value++;
  }

  /// Home puts what matches your taste first, in a "Picked for you" row.
  bool get smartMix => _b('smartMix', true);
  set smartMix(bool v) => _sb('smartMix', v);

  bool get notifyNew => _b('notifyNew', false);
  set notifyNew(bool v) => _sb('notifyNew', v);

  /// Notifications say only that something is new, never which site.
  bool get notifyDiscreet => _b('notifyDiscreet', true);
  set notifyDiscreet(bool v) => _sb('notifyDiscreet', v);
  List<String> get watchedSites => _p.getStringList('watchedSites') ?? [];
  List<String> get watchedForums => _p.getStringList('watchedForums') ?? [];

  /// Follows a site or forum for new-content alerts. Returns true when it is now followed.
  bool toggleWatch(String id, {required bool forum}) {
    final key = forum ? 'watchedForums' : 'watchedSites';
    final list = [...(_p.getStringList(key) ?? <String>[])];
    final on = !list.remove(id);
    if (on) list.add(id);
    _p.setStringList(key, list);
    if (on) _p.setBool('notifyNew', true);
    notifyListeners();
    return on;
  }

  /// Windows: the key that hides and locks the app at once.
  String get hideKey => _p.getString('hideKey') ?? 'F12';
  set hideKey(String v) {
    _p.setString('hideKey', v);
    notifyListeners();
  }

  /// The one link the Reels tab plays from.
  String get reelsSource => _p.getString('reelsSource') ?? '';
  set reelsSource(String v) {
    _p.setString('reelsSource', v);
    notifyListeners();
  }

  int get maxQuality => _p.getInt('maxQuality') ?? 2160;
  set maxQuality(int v) {
    _p.setInt('maxQuality', v);
    notifyListeners();
  }

  List<String> get recentSearches => _p.getStringList('recent') ?? [];
  set recentSearches(List<String> v) {
    _p.setStringList('recent', v);
    notifyListeners();
  }

  void addRecentSearch(String q) {
    final t = q.trim();
    if (t.isEmpty || privateMode) return;
    recentSearches = [t, ...recentSearches.where((e) => e.toLowerCase() != t.toLowerCase())].take(15).toList();
  }
}

bool _sameIds(List<MediaItem> a, List<MediaItem> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id) return false;
  }
  return true;
}

/// Windows: changes made in a second window reach the main window through a small file it reads.
class WindowInbox {
  static File get _file => File('${Disk.dir.path}${Platform.pathSeparator}inbox.jsonl');
  static Timer? _timer;

  static void send(Map<String, dynamic> m) {
    try {
      _file.writeAsStringSync('${jsonEncode(m)}\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static void start() {
    if (!Platform.isWindows || Disk.readOnly) return;
    _timer ??= Timer.periodic(const Duration(seconds: 2), (_) => _drain());
  }

  static void _drain() {
    final f = _file;
    if (!f.existsSync()) return;
    final List<String> lines;
    try {
      final taken = f.renameSync('${f.path}.reading');
      lines = taken.readAsLinesSync();
      taken.deleteSync();
    } catch (_) {
      return;
    }
    for (final l in lines) {
      try {
        final m = jsonDecode(l) as Map<String, dynamic>;
        final item = MediaItem.fromJson(m['item'] as Map<String, dynamic>);
        final on = m['on'] == true;
        switch (m['t']) {
          case 'fav':
            if (Library.shared.isFavorite(item) != on) Library.shared.toggleFavorite(item);
          case 'later':
            if (WatchLater.shared.contains(item) != on) WatchLater.shared.toggle(item);
          case 'col':
            final id = m['id'] as String;
            if (CollectionStore.shared.contains(item, id) != on) CollectionStore.shared.toggle(item, id);
        }
      } catch (_) {}
    }
  }
}
