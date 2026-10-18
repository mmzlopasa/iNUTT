import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

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

/// Everything you add (sites, forums, favorites, collections, Watch later) stays the same on all your
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
  bool syncing = false;
  bool hasPassphrase = false;

  /// "owner/name" of the private GitHub repository the file is kept in, instead of a folder.
  String? githubRepo;
  String? _githubToken;

  DateTime _lastRun = DateTime.fromMillisecondsSinceEpoch(0);
  (String, String, List<int>)? _keyCache;
  Timer? _timer;
  Timer? _debounce;
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
    for (final store in <Listenable>[Library.shared, WatchLater.shared, CollectionStore.shared, SiteStore.shared, ForumStore.shared]) {
      store.addListener(_changed);
    }
  }

  void _changed() {
    if (_applying || !isConfigured) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 2500), () {
      // History and other changes that aren't synced leave the lists as they were.
      final base = ((Disk.load('syncBase.json') as List?) ?? const []).whereType<String>().toSet();
      if (!setEquals(_localKeys(), base)) unawaited(sync());
    });
  }

  bool get _hasPlace => location != null || (githubRepo != null && (_githubToken ?? '').isNotEmpty);
  bool get isConfigured => _hasPlace && hasPassphrase && !Disk.readOnly;

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

  Set<String> _localKeys() => _keys(
    Library.shared.favorites,
    WatchLater.shared.items,
    CollectionStore.shared.collections,
    SiteStore.shared.sites.map((e) => e.url),
    ForumStore.shared.forums.map((e) => e.url),
  );

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

    final local = _localKeys();
    final theirs = _keys(rFav, rLater, rCols, rSites.map((e) => e.url), rForums.map((e) => e.url));
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

    _applying = true;
    try {
      lib.replaceFavorites(newFav);
      later.replaceAll(newLater);
      cols.replaceAll(newCols);
      siteStore.replaceAll(newSites);
      forumStore.replaceAll(newForums);
    } finally {
      _applying = false;
    }
    for (final s in addedSites) {
      unawaited(FeedEngine.shared.refreshForHome(s));
    }

    final state = _keys(newFav, newLater, newCols, newSites.map((e) => e.url), newForums.map((e) => e.url));
    if (remote == null || !setEquals(state, theirs)) {
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
