import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../screens/forums.dart';
import '../ui/router.dart';
import 'backup.dart';
import 'extras.dart';
import 'feed_engine.dart';
import 'models.dart';
import 'stores.dart';
import 'vault.dart';

/// Everything in the app (sites, forums, favorites, collections, Watch later, history, searches, blocked
/// words, resume points, taste, settings and, through GitHub, the vault) stays the same on all your
/// devices through one encrypted file: in a private GitHub repository, or one you keep in a cloud folder
/// (Google Drive, iCloud Drive, OneDrive…). The file is encrypted with your sync passphrase, so GitHub
/// or the cloud only ever sees noise. The same file works with iNUTT on iPhone. Changes are sent a
/// moment after you make them, and other devices' changes are checked for while the app is open.
class SyncManager extends ChangeNotifier {
  static final SyncManager shared = SyncManager._();
  SyncManager._();

  static const fileName = 'iNUTT-sync.inutt';
  static const _channel = MethodChannel('inutt/sync');
  static const _storage = FlutterSecureStorage();

  /// Android: the picked document's address. Windows: the folder that holds the file.
  String? location;
  String? locationName;
  DateTime? lastSync;
  String? status;

  /// What a long sync is doing right now, such as moving vault files.
  String? progress;
  bool syncing = false;
  bool hasPassphrase = false;

  /// "owner/name" of the private GitHub repository the file is kept in, instead of a folder.
  String? githubRepo;
  String? _githubToken;

  DateTime _lastRun = DateTime.fromMillisecondsSinceEpoch(0);
  (String, String, List<int>)? _keyCache;
  Timer? _timer;
  Timer? _debounce;
  Timer? _scheduled;
  DateTime? _scheduledAt;
  bool _again = false;

  /// True while a sync writes merged lists back, so those writes don't start another sync.
  bool _applying = false;

  /// The GitHub file as last read, so an unchanged file is answered by GitHub with "not modified".
  (String, List<int>?, String?)? _remoteCache;

  Future<void> load() async {
    final j = Disk.load('sync.json');
    if (j is Map) {
      location = j['location'] as String?;
      locationName = j['name'] as String?;
      final t = j['last'] as int?;
      if (t != null) lastSync = DateTime.fromMillisecondsSinceEpoch(t);
      githubRepo = j['github'] as String?;
    }
    // Secure storage can throw on Windows when nothing was ever saved; that just means no passphrase.
    try {
      hasPassphrase = ((await _storage.read(key: 'syncPassphrase')) ?? '').isNotEmpty;
      if (githubRepo != null) _githubToken = await _storage.read(key: 'syncGitHubToken');
    } catch (_) {
      hasPassphrase = false;
    }
    if (Disk.readOnly) return;
    // Other devices' changes arrive while the app is open, too.
    _timer ??= Timer.periodic(const Duration(seconds: 45), (_) {
      if (appResumed.value || Platform.isWindows) syncIfNeeded();
    });
    // Something you added or removed goes out a moment later, without waiting for the next check.
    for (final store in <Listenable>[
      Library.shared,
      WatchLater.shared,
      CollectionStore.shared,
      SiteStore.shared,
      ForumStore.shared,
      ResumeStore.shared,
      AppSettings.shared,
      Vault.shared,
    ]) {
      store.addListener(_changed);
    }
  }

  void _changed() {
    if (_applying || !isConfigured) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), () {
      if (_applying || !isConfigured) return;
      final base = ((Disk.load('syncBase.json') as List?) ?? const []).whereType<String>().toSet();
      final local = _localKeys();
      final changed = local.difference(base).union(base.difference(local));
      final snap = _settingsSnapshot;
      final settingsChanged = snap != null && !mapEquals(snap, _settingsNow());
      if (changed.isEmpty && !settingsChanged) return;
      // What you watch goes out less eagerly, so playing videos doesn't save to GitHub every time.
      final minor = !settingsChanged && changed.every((k) => k.startsWith('h:') || k.startsWith('p:'));
      _schedule(Duration(milliseconds: minor ? 30000 : 1500));
    });
  }

  /// Runs a sync after `wait`, unless one is already due sooner.
  void _schedule(Duration wait) {
    final at = DateTime.now().add(wait);
    final due = _scheduledAt;
    if (_scheduled != null && due != null && !at.isBefore(due)) return;
    _scheduled?.cancel();
    _scheduledAt = at;
    _scheduled = Timer(wait, () {
      _scheduled = null;
      _scheduledAt = null;
      unawaited(sync());
    });
  }

  // Settings that mean the same on every device. Lock settings stay per device.

  static const _settingKeys = [
    'autoplay',
    'loopVideos',
    'startMuted',
    'maxQuality',
    'historyEnabled',
    'reelsSource',
    'reelsAutoNext',
    'hideSeen',
    'slideshowSeconds',
    'slideshowRandom',
    'vaultDownloads',
    'privateMode',
    'offlineFavorites',
    'hideDuplicates',
    'smartMix',
    'notifyNew',
    'notifyDiscreet',
    'hideInSwitcher',
    'lockOnBackground',
  ];

  static Map<String, Object> _settingsNow() {
    final s = AppSettings.shared;
    return {
      'autoplay': s.autoplay,
      'loopVideos': s.loopVideos,
      'startMuted': s.startMuted,
      'maxQuality': s.maxQuality,
      'historyEnabled': s.historyEnabled,
      'reelsSource': s.reelsSource,
      'reelsAutoNext': s.reelsAutoNext,
      'hideSeen': s.hideSeen,
      'slideshowSeconds': s.slideshowSeconds,
      'slideshowRandom': s.slideshowRandom,
      'vaultDownloads': s.vaultDownloads,
      'privateMode': s.privateMode,
      'offlineFavorites': s.offlineFavorites,
      'hideDuplicates': s.hideDuplicates,
      'smartMix': s.smartMix,
      'notifyNew': s.notifyNew,
      'notifyDiscreet': s.notifyDiscreet,
      'hideInSwitcher': s.hideInSwitcher,
      'lockOnBackground': s.lockOnBackground,
    };
  }

  /// Settings as read from the file or from disk: only known names with the right kind of value, `at` in milliseconds.
  @visibleForTesting
  static Map<String, Object> cleanSettings(Object? raw) {
    final out = <String, Object>{};
    if (raw is! Map) return out;
    for (final k in [..._settingKeys, 'at']) {
      final v = raw[k];
      switch (k) {
        case 'at' when v is num:
          out[k] = v.round();
        case 'maxQuality' || 'slideshowSeconds' when v is num:
          out[k] = v.round();
        case 'reelsSource' when v is String:
          out[k] = v;
        case _ when v is bool:
          out[k] = v;
      }
    }
    return out;
  }

  static void _applySettings(Map<String, Object> m) {
    final s = AppSettings.shared;
    void b(String k, bool now, void Function(bool) set) {
      final v = m[k];
      if (v is bool && v != now) set(v);
    }

    b('autoplay', s.autoplay, (v) => s.autoplay = v);
    b('loopVideos', s.loopVideos, (v) => s.loopVideos = v);
    b('startMuted', s.startMuted, (v) => s.startMuted = v);
    if (m['maxQuality'] case final int v when v != s.maxQuality) s.maxQuality = v;
    b('historyEnabled', s.historyEnabled, (v) => s.historyEnabled = v);
    if (m['reelsSource'] case final String v when v != s.reelsSource) s.reelsSource = v;
    b('reelsAutoNext', s.reelsAutoNext, (v) => s.reelsAutoNext = v);
    b('hideSeen', s.hideSeen, (v) => s.hideSeen = v);
    if (m['slideshowSeconds'] case final int v when v != s.slideshowSeconds) s.slideshowSeconds = v;
    b('slideshowRandom', s.slideshowRandom, (v) => s.slideshowRandom = v);
    b('vaultDownloads', s.vaultDownloads, (v) => s.vaultDownloads = v);
    b('privateMode', s.privateMode, (v) => s.privateMode = v);
    b('offlineFavorites', s.offlineFavorites, (v) => s.offlineFavorites = v);
    b('hideDuplicates', s.hideDuplicates, (v) => s.hideDuplicates = v);
    b('smartMix', s.smartMix, (v) => s.smartMix = v);
    b('notifyNew', s.notifyNew, (v) => s.notifyNew = v);
    b('notifyDiscreet', s.notifyDiscreet, (v) => s.notifyDiscreet = v);
    b('hideInSwitcher', s.hideInSwitcher, (v) => s.hideInSwitcher = v);
    b('lockOnBackground', s.lockOnBackground, (v) => s.lockOnBackground = v);
  }

  /// The settings as they were after the last sync (without `at`), or null before the first one.
  Map<String, Object>? get _settingsSnapshot {
    final j = Disk.load('syncSettings.json');
    return j is Map && j['values'] is Map ? cleanSettings(j['values']) : null;
  }

  int get _settingsAt => ((Disk.load('syncSettings.json') as Map?)?['at'] as num?)?.round() ?? 0;

  /// Vault files travel only through GitHub; a folder sync leaves the vault on each device.
  bool get _syncsVault => githubRepo != null;

  static const historyLimit = 500;
  static const searchLimit = 15;

  /// Plain bytes per vault part on GitHub, so no single upload gets large.
  static const vaultPart = 8 << 20;

  bool get _hasPlace => location != null || (githubRepo != null && (_githubToken ?? '').isNotEmpty);
  bool get isConfigured => _hasPlace && hasPassphrase && !Disk.readOnly;

  /// What still has to be done before sync can run, for the settings screen.
  String? get missingStep => switch ((_hasPlace, hasPassphrase)) {
    (false, false) => 'Sync is off: connect GitHub (or pick a folder) and save a passphrase.',
    (false, true) => 'Sync is off: connect GitHub (or pick a folder).',
    (true, false) => 'Sync is off: type a passphrase of at least 6 characters and tap Save.',
    _ => null,
  };

  /// Where the file is kept, for the settings screen.
  String? get placeName => githubRepo != null ? 'GitHub · $githubRepo' : locationName;

  void _saveState() => Disk.save('sync.json', {
    'location': location,
    'name': locationName,
    'github': ?githubRepo,
    if (lastSync != null) 'last': lastSync!.millisecondsSinceEpoch,
  });

  Future<void> setPassphrase(String p) async {
    final t = p.trim();
    if (t.isEmpty) {
      await _storage.delete(key: 'syncPassphrase');
    } else {
      await _storage.write(key: 'syncPassphrase', value: t);
    }
    hasPassphrase = t.isNotEmpty;
    _keyCache = null;
    notifyListeners();
  }

  /// Android: make a new sync file (first device) or pick the existing one (other devices).
  Future<bool> pickAndroid({required bool create}) async {
    final r = await _channel.invokeMethod<Map>(create ? 'create' : 'open');
    if (r == null) return false;
    _setLocation(r['uri'] as String, r['name'] as String? ?? fileName);
    return true;
  }

  /// Windows: the folder where the file is kept, e.g. inside Google Drive or OneDrive.
  void setFolder(String path) => _setLocation(path, path.split(Platform.pathSeparator).where((e) => e.isNotEmpty).lastOrNull ?? path);

  void _setLocation(String loc, String name) {
    unawaited(_clearGitHub());
    location = loc;
    locationName = name;
    status = null;
    Disk.save('syncBase.json', <String>[]);
    _saveState();
    notifyListeners();
  }

  /// Checks the token and repository, then keeps the file there. Returns an error to show, or null.
  Future<String?> connectGitHub(String rawRepo, String rawToken) async {
    final token = rawToken.trim();
    final repo = repoName(rawRepo);
    if (repo == null) return 'Write the repository as owner/name.';
    if (token.isEmpty) return 'Paste a GitHub token.';
    final http.Response r;
    try {
      r = await http.get(_api('repos/$repo'), headers: _headers(token)).timeout(const Duration(seconds: 20));
    } catch (_) {
      return 'GitHub can\'t be reached right now.';
    }
    switch (r.statusCode) {
      case 200:
        break;
      case 401:
        return 'GitHub refused the token.';
      case 403 || 404:
        return 'The repository wasn\'t found, or the token has no access to it.';
      default:
        return 'GitHub answered ${r.statusCode}.';
    }
    final info = jsonDecode(r.body);
    if (info is Map && info['private'] == false) return 'That repository is public. Use a private one.';
    if (info is Map && info['permissions'] is Map && (info['permissions'] as Map)['push'] == false) {
      return 'The token can read the repository but not save to it.';
    }
    try {
      await _storage.write(key: 'syncGitHubToken', value: token);
    } catch (_) {
      return 'The token couldn\'t be stored on this device.';
    }
    _githubToken = token;
    githubRepo = repo;
    location = null;
    locationName = null;
    status = null;
    _remoteCache = null;
    Disk.save('syncBase.json', <String>[]);
    _saveState();
    notifyListeners();
    return null;
  }

  /// "owner/name", from that or from a github.com link.
  static String? repoName(String raw) {
    var s = raw.trim();
    for (final p in ['https://', 'http://', 'www.', 'github.com/']) {
      if (s.toLowerCase().startsWith(p)) s = s.substring(p.length);
    }
    if (s.endsWith('.git')) s = s.substring(0, s.length - 4);
    final parts = s.split('/').where((e) => e.isNotEmpty).toList();
    return parts.length < 2 ? null : '${parts[0]}/${parts[1]}';
  }

  Future<void> _clearGitHub() async {
    githubRepo = null;
    _githubToken = null;
    _remoteCache = null;
    try {
      await _storage.delete(key: 'syncGitHubToken');
    } catch (_) {}
  }

  void stop() {
    unawaited(_clearGitHub());
    location = null;
    locationName = null;
    status = null;
    Disk.save('syncBase.json', <String>[]);
    _saveState();
    notifyListeners();
  }

  /// Runs on launch and when the app opens or leaves; at most once every half minute unless asked.
  void syncIfNeeded() {
    if (!isConfigured || DateTime.now().difference(_lastRun) < const Duration(seconds: 30)) return;
    unawaited(sync());
  }

  Future<void> sync() async {
    if (!isConfigured) return;
    if (syncing) {
      _again = true;
      return;
    }
    syncing = true;
    _lastRun = DateTime.now();
    notifyListeners();
    try {
      try {
        await _run();
      } on _Conflict {
        // Another device saved in between: read its version and merge again.
        _remoteCache = null;
        await _run();
      }
      lastSync = DateTime.now();
      status = null;
      _saveState();
    } catch (e) {
      status = e is SyncError ? e.message : (e is _Conflict ? 'Another device saved at the same moment; try again.' : 'Sync failed: $e');
    }
    syncing = false;
    notifyListeners();
    if (_again) {
      _again = false;
      unawaited(sync());
    }
  }

  // Merge

  Set<String> _localKeys() =>
      _keys(
        Library.shared.favorites,
        WatchLater.shared.items,
        CollectionStore.shared.collections,
        SiteStore.shared.sites.map((e) => e.url),
        ForumStore.shared.forums.map((e) => e.url),
      ).union(
        _extraKeys(
          history: Library.shared.history.take(historyLimit).map((e) => e.item.id),
          searches: AppSettings.shared.recentSearches,
          blocked: AppSettings.shared.blockedWords,
          resume: ResumeStore.shared.points.keys,
          vault: _syncsVault ? Vault.shared.entries.map((e) => e.syncKey) : const [],
        ),
      );

  static Set<String> _extraKeys({
    required Iterable<String> history,
    required Iterable<String> searches,
    required Iterable<String> blocked,
    required Iterable<String> resume,
    required Iterable<String> vault,
  }) => {
    for (final i in history) 'h:$i',
    for (final q in searches) 'q:${q.toLowerCase()}',
    for (final w in blocked) 'b:${w.toLowerCase()}',
    for (final i in resume) 'p:$i',
    for (final v in vault) 'v:$v',
  };

  /// The same key the iPhone app makes from a link (its paths are compared decoded).
  static String _linkKey(Uri u) {
    var s = u.host.toLowerCase().replaceAll('www.', '') + Uri.decodeFull(u.path).toLowerCase();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (u.query.isNotEmpty) s += '?${u.query}';
    return s;
  }

  /// One entry per thing that can be on a list: sites, forums, favorites, Watch later, each collection and its items.
  static Set<String> _keys(
    List<MediaItem> favorites,
    List<MediaItem> later,
    List<MediaCollection> cols,
    Iterable<Uri> sites,
    Iterable<Uri> forums,
  ) {
    final k = <String>{};
    for (final i in favorites) {
      k.add('f:${i.id}');
    }
    for (final i in later) {
      k.add('w:${i.id}');
    }
    for (final c in cols) {
      final n = c.name.toLowerCase();
      k.add('C:$n');
      for (final i in c.items) {
        k.add('c:$n\u0001${i.id}');
      }
    }
    for (final u in sites) {
      k.add('s:${_linkKey(u)}');
    }
    for (final u in forums) {
      k.add('F:${_linkKey(u)}');
    }
    return k;
  }

  Future<void> _run() async {
    final pass = await _storage.read(key: 'syncPassphrase').catchError((_) => null) ?? '';
    if (pass.isEmpty) throw SyncError('Set a sync passphrase first.');

    final (raw, version) = await _readRemote();
    Map? remote;
    List<int> salt;
    if (raw != null && raw.isNotEmpty) {
      Map env;
      try {
        env = jsonDecode(utf8.decode(raw)) as Map;
      } catch (_) {
        throw SyncError('The sync file can\'t be read.');
      }
      salt = base64Decode(env['salt'] as String);
      final nonce = base64Decode(env['nonce'] as String);
      final data = base64Decode(env['data'] as String);
      if (data.length <= 16) throw SyncError('The sync file can\'t be read.');
      final key = await _key(pass, salt);
      try {
        final plain = await AesGcm.with256bits().decrypt(
          SecretBox(data.sublist(0, data.length - 16), nonce: nonce, mac: Mac(data.sublist(data.length - 16))),
          secretKey: SecretKey(key),
        );
        remote = jsonDecode(utf8.decode(plain)) as Map;
      } on SecretBoxAuthenticationError {
        throw SyncError('The passphrase doesn\'t match the one used on your other device.');
      }
    } else {
      final r = Random.secure();
      salt = List<int>.generate(16, (_) => r.nextInt(256));
    }

    List<MediaItem> items(Object? l) => (l as List? ?? const []).map(Backup.unpack).whereType<MediaItem>().toList();
    final lib = Library.shared, later = WatchLater.shared, cols = CollectionStore.shared;
    final rFav = items(remote?['favorites']);
    final rLater = items(remote?['watchLater']);
    final rCols = [
      for (final c in (remote?['collections'] as List? ?? const []).whereType<Map>())
        MediaCollection(name: c['name'] as String? ?? 'Collection', items: items(c['items'])),
    ];
    final rSites = [
      for (final s in (remote?['sites'] as List? ?? const []).whereType<Map>())
        if (Uri.tryParse(s['url'] as String? ?? '') case final u? when u.hasScheme)
          Site(
            name: s['name'] as String? ?? u.host,
            url: u,
            searchTemplate: s['searchTemplate'] as String?,
            renderMode: RenderMode.values.firstWhere((m) => m.name == s['renderMode'], orElse: () => RenderMode.auto),
            enabled: s['enabled'] as bool? ?? true,
          ),
    ];
    final rForums = [
      for (final f in (remote?['forums'] as List? ?? const []).whereType<Map>())
        if (Uri.tryParse(f['url'] as String? ?? '') case final u? when u.hasScheme) Forum(name: f['name'] as String? ?? u.host, url: u),
    ];
    final siteStore = SiteStore.shared, forumStore = ForumStore.shared;

    final rHistory = [
      for (final h in (remote?['history'] as List? ?? const []).whereType<Map>())
        if (Backup.unpack(h['item']) case final i?) HistoryEntry(item: i, viewedAt: _date(h['at'])),
    ];
    final rResume = <String, ResumePoint>{};
    for (final r in (remote?['resume'] as List? ?? const []).whereType<Map>()) {
      final i = Backup.unpack(r['item']);
      if (i == null) continue;
      final p = ResumePoint(i, (r['seconds'] as num?)?.toDouble() ?? 0, (r['duration'] as num?)?.toDouble() ?? 0, _date(r['at']));
      final old = rResume[i.id];
      if (old == null || p.updatedAt.isAfter(old.updatedAt)) rResume[i.id] = p;
    }
    List<String> strings(Object? l) => (l as List? ?? const []).whereType<String>().toList();
    final rSearches = strings(remote?['searches']);
    final rBlocked = strings(remote?['blocked']);
    final rVault = (remote?['vault'] as List? ?? const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    String vid(Map<String, dynamic> v) => v['id'] as String? ?? '';

    final local = _localKeys();
    final theirs = _keys(rFav, rLater, rCols, rSites.map((e) => e.url), rForums.map((e) => e.url)).union(
      _extraKeys(
        history: rHistory.map((e) => e.item.id),
        searches: rSearches,
        blocked: rBlocked,
        resume: rResume.keys,
        vault: _syncsVault ? rVault.map(vid) : const [],
      ),
    );
    final base = ((Disk.load('syncBase.json') as List?) ?? const []).whereType<String>().toSet();
    // Three-way merge: kept on both, or newly added on either side since the last sync.
    // Something removed on one side since then is removed everywhere.
    final merged = local.intersection(theirs).union(local.difference(base)).union(theirs.difference(base));

    List<MediaItem> list(List<MediaItem> mine, List<MediaItem> other, String prefix) {
      final have = mine.map((e) => e.id).toSet();
      final added = other.where((e) => !have.contains(e.id) && merged.contains('$prefix${e.id}'));
      return [...added, ...mine.where((e) => merged.contains('$prefix${e.id}'))];
    }

    final newFav = list(lib.favorites, rFav, 'f:');
    final newLater = list(later.items, rLater, 'w:');
    final newCols = <MediaCollection>[];
    for (final c in cols.collections) {
      final n = c.name.toLowerCase();
      if (!merged.contains('C:$n')) continue;
      final other = rCols.where((e) => e.name.toLowerCase() == n).firstOrNull?.items ?? const <MediaItem>[];
      newCols.add(MediaCollection(id: c.id, name: c.name, items: list(c.items, other, 'c:$n\u0001')));
    }
    for (final r in rCols) {
      final n = r.name.toLowerCase();
      if (!merged.contains('C:$n') || newCols.any((e) => e.name.toLowerCase() == n)) continue;
      newCols.add(MediaCollection(name: r.name, items: r.items.where((e) => merged.contains('c:$n\u0001${e.id}')).toList()));
    }

    // Sites and forums: yours keep their settings and order; ones added elsewhere come after them.
    final newSites = siteStore.sites.where((e) => merged.contains('s:${_linkKey(e.url)}')).toList();
    for (final r in rSites) {
      final k = _linkKey(r.url);
      if (merged.contains('s:$k') && !newSites.any((e) => _linkKey(e.url) == k)) newSites.add(r);
    }
    final newForums = forumStore.forums.where((e) => merged.contains('F:${_linkKey(e.url)}')).toList();
    for (final r in rForums) {
      final k = _linkKey(r.url);
      if (merged.contains('F:$k') && !newForums.any((e) => _linkKey(e.url) == k)) newForums.add(r);
    }
    final addedSites = newSites.where((s) => !siteStore.sites.any((e) => e.id == s.id)).toList();

    // History: newest view of each item wins; entries past what travels stay as they are.
    final settings = AppSettings.shared;
    final views = <String, HistoryEntry>{};
    for (final h in [...lib.history.take(historyLimit), ...rHistory]) {
      if (!merged.contains('h:${h.item.id}')) continue;
      final old = views[h.item.id];
      if (old != null && !h.viewedAt.isAfter(old.viewedAt)) continue;
      views[h.item.id] = h;
    }
    final top = views.values.toList()..sort((a, b) => b.viewedAt.compareTo(a.viewedAt));
    final topIds = top.map((e) => e.item.id).toSet();
    final older = lib.history.skip(historyLimit).where((e) => !topIds.contains(e.item.id));
    final newHistory = [...top, ...older].take(Limits.maxHistory).toList();

    List<String> words(List<String> mine, List<String> other, String prefix) {
      final seen = <String>{};
      return [
        for (final w in [...mine, ...other])
          if (merged.contains('$prefix${w.toLowerCase()}') && seen.add(w.toLowerCase())) w,
      ];
    }

    final newSearches = words(settings.recentSearches, rSearches, 'q:').take(searchLimit).toList();
    final newBlocked = words(settings.blockedWords, rBlocked, 'b:');

    final newResume = <String, ResumePoint>{};
    for (final e in [...ResumeStore.shared.points.entries, ...rResume.entries]) {
      if (!merged.contains('p:${e.key}')) continue;
      final old = newResume[e.key];
      if (old == null || e.value.updatedAt.isAfter(old.updatedAt)) newResume[e.key] = e.value;
    }

    // Taste: the stronger of the two for each thing learned.
    final taste = Taste.shared;
    final rTasteRaw = remote?['taste'];
    final rWeights = <String, double>{
      if (rTasteRaw is Map && rTasteRaw['weights'] is Map)
        for (final e in (rTasteRaw['weights'] as Map).entries)
          if (e.key is String && e.value is num) e.key as String: (e.value as num).toDouble(),
    };
    final rSignals = rTasteRaw is Map ? (rTasteRaw['signals'] as num?)?.round() ?? 0 : 0;
    final newWeights = {...taste.weights};
    rWeights.forEach((k, v) => newWeights[k] = max(newWeights[k] ?? v, v));
    final newSignals = max(taste.signals, rSignals);
    final tasteChanged = rTasteRaw is! Map || rSignals != newSignals || !mapEquals(rWeights, newWeights);

    // Settings: whichever device changed them last.
    final mine = _settingsNow();
    final snapshot = _settingsSnapshot;
    final lastAt = _settingsAt;
    final rSettings = remote?['settings'] is Map ? cleanSettings(remote!['settings']) : null;
    final rAt = rSettings?['at'] as int?;
    Map<String, Object> newSettings;
    var adopt = false;
    if (rSettings != null && rAt != null && (snapshot == null || (mapEquals(mine, snapshot) && rAt > lastAt))) {
      newSettings = rSettings;
      adopt = true;
    } else if (snapshot == null || !mapEquals(mine, snapshot) || rSettings == null) {
      newSettings = {...mine, 'at': DateTime.now().millisecondsSinceEpoch};
    } else {
      newSettings = rSettings;
    }

    // Vault: files added here go up before the list says they exist; files from elsewhere come down after.
    var newVault = rVault;
    var vaultDownloads = <Map<String, dynamic>>[];
    final repo = githubRepo, token = _githubToken;
    if (_syncsVault && repo != null && token != null) {
      final key = await _key(pass, salt);
      final have = rVault.map(vid).toSet();
      newVault = rVault.where((v) => merged.contains('v:${vid(v)}')).toList();
      for (final gone in rVault.where((v) => !merged.contains('v:${vid(v)}'))) {
        await _deleteVaultFiles(vid(gone), repo, token);
      }
      final uploads = Vault.shared.entries.where((e) => merged.contains('v:${e.syncKey}') && !have.contains(e.syncKey)).toList();
      for (var n = 0; n < uploads.length; n++) {
        progress = 'Uploading vault ${n + 1} of ${uploads.length}…';
        notifyListeners();
        try {
          newVault.add(await _uploadVault(uploads[n], key, repo, token));
        } catch (_) {}
      }
      progress = null;
      final localVault = Vault.shared.entries.map((e) => e.syncKey).toSet();
      vaultDownloads = newVault.where((v) => !localVault.contains(vid(v))).toList();
    }

    _applying = true;
    try {
      lib.replaceFavorites(newFav);
      later.replaceAll(newLater);
      cols.replaceAll(newCols);
      siteStore.replaceAll(newSites);
      forumStore.replaceAll(newForums);
      lib.replaceHistory(newHistory);
      if (!listEquals(newSearches, settings.recentSearches)) settings.recentSearches = newSearches;
      if (!listEquals(newBlocked, settings.blockedWords)) settings.blockedWords = newBlocked;
      ResumeStore.shared.replaceAll(newResume);
      taste.replace(newWeights, newSignals);
      if (adopt) _applySettings(newSettings);
      if (_syncsVault) {
        for (final e in [...Vault.shared.entries]) {
          if (!merged.contains('v:${e.syncKey}')) Vault.shared.delete(e);
        }
      }
      Disk.save('syncSettings.json', {
        'values': {...newSettings}..remove('at'),
        'at': newSettings['at'] ?? 0,
      });
    } finally {
      _applying = false;
    }
    for (final s in addedSites) {
      unawaited(FeedEngine.shared.refreshForHome(s));
    }

    final syncedHistory = newHistory.take(historyLimit).toList();
    final state = _keys(newFav, newLater, newCols, newSites.map((e) => e.url), newForums.map((e) => e.url)).union(
      _extraKeys(
        history: syncedHistory.map((e) => e.item.id),
        searches: newSearches,
        blocked: newBlocked,
        resume: newResume.keys,
        vault: _syncsVault ? newVault.map(vid) : const [],
      ),
    );
    // Also written when only an order, a position or a value changed.
    String stamp(HistoryEntry h) => '${h.item.id}@${h.viewedAt.millisecondsSinceEpoch}';
    final historyMoved = !listEquals(syncedHistory.take(20).map(stamp).toList(), rHistory.take(20).map(stamp).toList());
    final resumeMoved = !mapEquals(
      newResume.map((k, v) => MapEntry(k, v.updatedAt.millisecondsSinceEpoch)),
      rResume.map((k, v) => MapEntry(k, v.updatedAt.millisecondsSinceEpoch)),
    );
    final vaultChanged = jsonEncode(newVault) != jsonEncode(rVault);
    final other = historyMoved || resumeMoved || tasteChanged || !mapEquals(newSettings, rSettings) || vaultChanged;
    if (remote == null || !setEquals(state, theirs) || other) {
      final payload = {
        'app': 'iNUTT-sync',
        'version': 1,
        'device': Platform.localHostname,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'favorites': newFav.map((e) => Backup.pack(e, withId: true)).toList(),
        'watchLater': newLater.map((e) => Backup.pack(e, withId: true)).toList(),
        'collections': [
          for (final c in newCols) {'name': c.name, 'items': c.items.map((e) => Backup.pack(e, withId: true)).toList()},
        ],
        'sites': [
          for (final s in newSites)
            {
              'name': s.name,
              'url': s.url.toString(),
              'searchTemplate': ?s.searchTemplate,
              'renderMode': s.renderMode.name,
              'enabled': s.enabled,
            },
        ],
        'forums': [
          for (final f in newForums) {'name': f.name, 'url': f.url.toString()},
        ],
        'history': [
          for (final h in syncedHistory) {'item': Backup.pack(h.item, withId: true), 'at': h.viewedAt.millisecondsSinceEpoch},
        ],
        'searches': newSearches,
        'blocked': newBlocked,
        'resume': [
          for (final p in newResume.values)
            {
              'item': Backup.pack(p.item, withId: true),
              'seconds': p.seconds,
              'duration': p.duration,
              'at': p.updatedAt.millisecondsSinceEpoch,
            },
        ],
        'taste': {'weights': newWeights, 'signals': newSignals},
        'settings': newSettings,
        'vault': newVault,
      };
      final key = await _key(pass, salt);
      final algo = AesGcm.with256bits();
      final box = await algo.encrypt(utf8.encode(jsonEncode(payload)), secretKey: SecretKey(key), nonce: algo.newNonce());
      final env = {
        'app': 'iNUTT-sync',
        'v': 1,
        'salt': base64Encode(salt),
        'nonce': base64Encode(box.nonce),
        'data': base64Encode([...box.cipherText, ...box.mac.bytes]),
      };
      await _writeRemote(utf8.encode(jsonEncode(env)), version);
    }
    Disk.save('syncBase.json', state.toList());

    if (vaultDownloads.isNotEmpty && repo != null && token != null) {
      final key = await _key(pass, salt);
      final failed = <String>{};
      for (var n = 0; n < vaultDownloads.length; n++) {
        progress = 'Downloading vault ${n + 1} of ${vaultDownloads.length}…';
        notifyListeners();
        try {
          await _downloadVault(vaultDownloads[n], key, repo, token);
        } catch (_) {
          failed.add('v:${vid(vaultDownloads[n])}');
        }
      }
      progress = null;
      // A file that didn't come down is fetched next time, not taken as removed here.
      if (failed.isNotEmpty) Disk.save('syncBase.json', state.difference(failed).toList());
    }
  }

  static DateTime _date(Object? ms) => DateTime.fromMillisecondsSinceEpoch((ms as num?)?.round() ?? 0);

  // Vault files on GitHub

  Future<Map<String, dynamic>> _uploadVault(VaultEntry e, List<int> key, String repo, String token) async {
    final plain = await Vault.shared.open(e);
    final input = await plain.open();
    var part = 0;
    try {
      while (true) {
        final piece = await input.read(vaultPart);
        if (piece.isEmpty && part > 0) break;
        final sealed = await Isolate.run(() => sealChunks(piece, key));
        await _putFile('vault/${e.syncKey}/$part', sealed, repo, token);
        part++;
        if (piece.length < vaultPart) break;
      }
    } finally {
      await input.close();
      try {
        await plain.delete();
      } catch (_) {}
    }
    return {
      'id': e.syncKey,
      'title': e.title,
      'siteName': e.siteName,
      'kind': e.kind.name,
      'ext': e.ext,
      'size': e.size,
      'thumb': ?e.thumbnailUrl?.toString(),
      'addedAt': e.addedAt.millisecondsSinceEpoch,
      'parts': part,
    };
  }

  Future<void> _downloadVault(Map<String, dynamic> v, List<int> key, String repo, String token) async {
    final id = v['id'] as String;
    final tmp = File('${Directory.systemTemp.path}${Platform.pathSeparator}inutt-sync-$id');
    final out = await tmp.open(mode: FileMode.write);
    try {
      final parts = max(1, (v['parts'] as num?)?.round() ?? 1);
      for (var part = 0; part < parts; part++) {
        final r = await http
            .get(_api('repos/$repo/contents/vault/$id/$part'), headers: _headers(token, accept: 'application/vnd.github.raw'))
            .timeout(const Duration(seconds: 120));
        if (r.statusCode != 200) throw SyncError('A vault file couldn\'t be read from GitHub.');
        final body = r.bodyBytes;
        await out.writeFrom(await Isolate.run(() => openChunks(body, key)));
      }
      await out.close();
    } catch (_) {
      await out.close();
      try {
        await tmp.delete();
      } catch (_) {}
      rethrow;
    }
    await Vault.shared.addSynced(
      tmp,
      VaultEntry(
        id: id,
        title: v['title'] as String? ?? '',
        siteName: v['siteName'] as String? ?? '',
        kind: MediaKind.parse(v['kind'] as String?),
        ext: v['ext'] as String? ?? 'bin',
        size: (v['size'] as num?)?.round() ?? 0,
        thumbnailUrl: Uri.tryParse(v['thumb'] as String? ?? ''),
        addedAt: _date(v['addedAt']),
        syncId: id,
      ),
    );
  }

  Future<void> _putFile(String path, List<int> data, String repo, String token) async {
    final body = <String, dynamic>{'message': 'iNUTT vault', 'content': base64Encode(data)};
    // A part left by an upload that was cut off is replaced.
    try {
      final found = await http.get(_api('repos/$repo/contents/$path'), headers: _headers(token)).timeout(const Duration(seconds: 30));
      if (found.statusCode == 200) {
        final j = jsonDecode(found.body);
        if (j is Map && j['sha'] is String) body['sha'] = j['sha'];
      }
    } catch (_) {}
    final r = await http
        .put(_api('repos/$repo/contents/$path'), headers: {..._headers(token), 'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 300));
    if (r.statusCode != 200 && r.statusCode != 201) throw SyncError('A vault file couldn\'t be saved to GitHub.');
  }

  Future<void> _deleteVaultFiles(String id, String repo, String token) async {
    if (id.isEmpty) return;
    try {
      final r = await http.get(_api('repos/$repo/contents/vault/$id'), headers: _headers(token)).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) return;
      final files = jsonDecode(r.body);
      if (files is! List) return;
      for (final f in files.whereType<Map>()) {
        final path = f['path'], sha = f['sha'];
        if (path is! String || sha is! String) continue;
        final req = http.Request('DELETE', _api('repos/$repo/contents/$path'))
          ..headers.addAll({..._headers(token), 'Content-Type': 'application/json'})
          ..body = jsonEncode({'message': 'iNUTT vault', 'sha': sha});
        await (await req.send().timeout(const Duration(seconds: 30))).stream.drain<void>();
      }
    } catch (_) {}
  }

  /// The vault's own format (1 MB pieces, each AES-GCM sealed and length-prefixed), with the sync key,
  /// so another device with the same passphrase can open it. The iPhone app reads and writes the same.
  @visibleForTesting
  static Future<List<int>> sealChunks(List<int> plain, List<int> key) async {
    final algo = AesGcm.with256bits();
    final k = SecretKey(key);
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < plain.length; i += 1 << 20) {
      final box = await algo.encrypt(plain.sublist(i, min(i + (1 << 20), plain.length)), secretKey: k);
      final sealed = box.concatenation();
      out.add((ByteData(4)..setUint32(0, sealed.length)).buffer.asUint8List());
      out.add(sealed);
    }
    return out.takeBytes();
  }

  @visibleForTesting
  static Future<List<int>> openChunks(List<int> sealed, List<int> key) async {
    final algo = AesGcm.with256bits();
    final k = SecretKey(key);
    final data = Uint8List.fromList(sealed);
    final out = BytesBuilder(copy: false);
    var i = 0;
    while (i + 4 <= data.length) {
      final len = ByteData.sublistView(data, i, i + 4).getUint32(0);
      i += 4;
      if (i + len > data.length) throw SyncError('A vault file from GitHub is damaged.');
      final box = SecretBox.fromConcatenation(data.sublist(i, i + len), nonceLength: 12, macLength: 16);
      out.add(await algo.decrypt(box, secretKey: k));
      i += len;
    }
    return out.takeBytes();
  }

  // Key and files

  /// PBKDF2-SHA256, the same on every platform; worked out once per launch, off the UI thread.
  Future<List<int>> _key(String pass, List<int> salt) async {
    final s = base64Encode(salt);
    final c = _keyCache;
    if (c != null && c.$1 == s && c.$2 == pass) return c.$3;
    final k = await Isolate.run(() async {
      final pb = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 100000, bits: 256);
      final key = await pb.deriveKeyFromPassword(password: pass, nonce: salt);
      return key.extractBytes();
    });
    _keyCache = (s, pass, k);
    return k;
  }

  // Where the file is kept

  /// The file's bytes (null when there is none yet) and, on GitHub, the version to replace.
  Future<(List<int>?, String?)> _readRemote() async {
    final repo = githubRepo, token = _githubToken;
    if (repo != null && token != null && token.isNotEmpty) return _readGitHub(repo, token);
    final loc = location;
    if (loc == null) throw SyncError('Connect GitHub or pick where the sync file is kept first.');
    return (await _read(loc), null);
  }

  Future<void> _writeRemote(List<int> data, String? version) async {
    final repo = githubRepo, token = _githubToken;
    if (repo != null && token != null && token.isNotEmpty) return _writeGitHub(data, repo, token, version);
    final loc = location;
    if (loc == null) throw SyncError('Connect GitHub or pick where the sync file is kept first.');
    await _write(loc, data);
  }

  static Uri _api(String path) => Uri.parse('https://api.github.com/$path');

  static Map<String, String> _headers(String token, {String accept = 'application/vnd.github+json'}) => {
    'Authorization': 'Bearer $token',
    'Accept': accept,
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'iNUTT',
  };

  Future<(List<int>?, String?)> _readGitHub(String repo, String token) async {
    final cache = _remoteCache;
    final r = await http
        .get(_api('repos/$repo/contents/$fileName'), headers: {..._headers(token), 'If-None-Match': ?cache?.$1})
        .timeout(const Duration(seconds: 20));
    switch (r.statusCode) {
      case 304 when cache != null:
        return (cache.$2, cache.$3);
      case 304:
        _remoteCache = null;
        return _readGitHub(repo, token);
      case 404:
        _remoteCache = null;
        return (null, null);
      case 401:
        throw SyncError('GitHub refused the token. Connect GitHub again in Sync.');
      case 200:
        break;
      default:
        throw SyncError('GitHub answered ${r.statusCode}.');
    }
    final j = jsonDecode(r.body);
    if (j is! Map || j['sha'] is! String) throw SyncError('The sync file can\'t be read.');
    final sha = j['sha'] as String;
    final content = j['content'] as String? ?? '';
    List<int> data;
    if (content.isNotEmpty) {
      data = base64Decode(content.replaceAll('\n', ''));
    } else {
      // Files over 1 MB come without their content; fetch it on its own.
      final b = await http
          .get(_api('repos/$repo/git/blobs/$sha'), headers: _headers(token, accept: 'application/vnd.github.raw'))
          .timeout(const Duration(seconds: 30));
      if (b.statusCode != 200) throw SyncError('The sync file can\'t be read.');
      data = b.bodyBytes;
    }
    final etag = r.headers['etag'];
    if (etag != null) _remoteCache = (etag, data, sha);
    return (data, sha);
  }

  Future<void> _writeGitHub(List<int> data, String repo, String token, String? sha) async {
    final r = await http
        .put(
          _api('repos/$repo/contents/$fileName'),
          headers: {..._headers(token), 'Content-Type': 'application/json'},
          body: jsonEncode({'message': 'iNUTT sync from ${Platform.localHostname}', 'content': base64Encode(data), 'sha': ?sha}),
        )
        .timeout(const Duration(seconds: 30));
    _remoteCache = null;
    switch (r.statusCode) {
      case 200 || 201:
        return;
      case 409 || 422:
        throw _Conflict();
      case 401:
        throw SyncError('GitHub refused the token. Connect GitHub again in Sync.');
      case 403 || 404:
        throw SyncError('The token can\'t save to that repository.');
      default:
        throw SyncError('GitHub answered ${r.statusCode} while saving.');
    }
  }

  Future<List<int>?> _read(String loc) async {
    if (Platform.isAndroid) {
      return await _channel.invokeMethod<Uint8List>('read', {'uri': loc});
    }
    final f = File('$loc${Platform.pathSeparator}$fileName');
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  Future<void> _write(String loc, List<int> data) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<bool>('write', {'uri': loc, 'data': Uint8List.fromList(data)});
      return;
    }
    final f = File('$loc${Platform.pathSeparator}$fileName');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(data, flush: true);
    await tmp.rename(f.path);
  }
}

class _Conflict implements Exception {}

class SyncError implements Exception {
  final String message;
  SyncError(this.message);
  @override
  String toString() => message;
}
