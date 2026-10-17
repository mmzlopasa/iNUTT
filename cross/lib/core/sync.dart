import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'backup.dart';
import 'models.dart';
import 'extras.dart';
import 'stores.dart';

/// Favorites, collections and Watch later stay the same on all your devices through one file you keep
/// in a cloud folder (Google Drive, iCloud Drive, OneDrive…). The file is encrypted with your sync
/// passphrase, so the cloud only ever sees noise. The same file works with iNUTT on iPhone.
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

  DateTime _lastRun = DateTime.fromMillisecondsSinceEpoch(0);
  (String, String, List<int>)? _keyCache;
  Timer? _timer;

  Future<void> load() async {
    final j = Disk.load('sync.json');
    if (j is Map) {
      location = j['location'] as String?;
      locationName = j['name'] as String?;
      final t = j['last'] as int?;
      if (t != null) lastSync = DateTime.fromMillisecondsSinceEpoch(t);
    }
    hasPassphrase = ((await _storage.read(key: 'syncPassphrase')) ?? '').isNotEmpty;
    // Windows has no app-switch moment to rely on, so it also checks every few minutes while open.
    if (Platform.isWindows && !Disk.readOnly) _timer ??= Timer.periodic(const Duration(minutes: 3), (_) => syncIfNeeded());
  }

  bool get isConfigured => location != null && hasPassphrase && !Disk.readOnly;

  void _saveState() => Disk.save('sync.json', {
    'location': location,
    'name': locationName,
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
    location = loc;
    locationName = name;
    status = null;
    Disk.save('syncBase.json', <String>[]);
    _saveState();
    notifyListeners();
  }

  void stop() {
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
    if (!isConfigured || syncing) return;
    syncing = true;
    _lastRun = DateTime.now();
    notifyListeners();
    try {
      await _run();
      lastSync = DateTime.now();
      status = null;
      _saveState();
    } catch (e) {
      status = e is SyncError ? e.message : 'Sync failed: $e';
    }
    syncing = false;
    notifyListeners();
  }

  // Merge

  /// One entry per thing that can be on a list: favorites, Watch later, each collection and its items.
  static Set<String> _keys(List<MediaItem> favorites, List<MediaItem> later, List<MediaCollection> cols) {
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
    return k;
  }

  Future<void> _run() async {
    final loc = location;
    if (loc == null) throw SyncError('Pick where the sync file is kept first.');
    final pass = await _storage.read(key: 'syncPassphrase') ?? '';
    if (pass.isEmpty) throw SyncError('Set a sync passphrase first.');

    final raw = await _read(loc);
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

    final local = _keys(lib.favorites, later.items, cols.collections);
    final theirs = _keys(rFav, rLater, rCols);
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

    lib.replaceFavorites(newFav);
    later.replaceAll(newLater);
    cols.replaceAll(newCols);

    final state = _keys(newFav, newLater, newCols);
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
      await _write(loc, utf8.encode(jsonEncode(env)));
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

class SyncError implements Exception {
  final String message;
  SyncError(this.message);
  @override
  String toString() => message;
}
