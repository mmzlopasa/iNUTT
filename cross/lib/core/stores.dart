import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  static Future<void> save(String name, Object value) async {
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(value));
    await tmp.rename(f.path);
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

  void load() {
    final f = Disk.load('favorites.json');
    if (f is List) favorites = f.map((e) => MediaItem.fromJson(e as Map<String, dynamic>)).toList();
    final h = Disk.load('history.json');
    if (h is List) history = h.map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>)).toList();
    _favIds.addAll(favorites.map((e) => e.id));
  }

  bool isFavorite(MediaItem i) => _favIds.contains(i.id);

  void toggleFavorite(MediaItem item) {
    if (_favIds.remove(item.id)) {
      favorites.removeWhere((e) => e.id == item.id);
    } else {
      _favIds.add(item.id);
      favorites.insert(0, item);
    }
    notifyListeners();
    Disk.save('favorites.json', favorites.map((e) => e.toJson()).toList());
  }

  void record(MediaItem item) {
    if (!AppSettings.shared.historyEnabled || item.isListing) return;
    history.removeWhere((e) => e.item.id == item.id);
    history.insert(0, HistoryEntry(item: item, viewedAt: DateTime.now()));
    if (history.length > Limits.maxHistory) history = history.sublist(0, Limits.maxHistory);
    _saveHistory();
  }

  void removeHistory(Set<String> ids) {
    history.removeWhere((e) => ids.contains(e.id));
    _saveHistory();
  }

  void clearHistory() {
    history = [];
    _saveHistory();
  }

  void _saveHistory() {
    notifyListeners();
    Disk.save('history.json', history.map((e) => e.toJson()).toList());
  }
}

class AppSettings extends ChangeNotifier {
  static final AppSettings shared = AppSettings._();
  AppSettings._();

  late SharedPreferences _p;

  Future<void> load() async => _p = await SharedPreferences.getInstance();

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
  bool get hideInSwitcher => _b('hideInSwitcher', false);
  set hideInSwitcher(bool v) => _sb('hideInSwitcher', v);

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
    if (t.isEmpty) return;
    recentSearches = [t, ...recentSearches.where((e) => e.toLowerCase() != t.toLowerCase())].take(15).toList();
  }
}
