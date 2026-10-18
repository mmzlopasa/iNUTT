import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';
import 'stores.dart';

class VaultEntry {
  final String id;
  final String title;
  final String siteName;
  final MediaKind kind;
  final String ext;
  final int size;
  final Uri? thumbnailUrl;
  final DateTime addedAt;

  /// The same file's name on every device, set when it came from another device through sync.
  final String? syncId;

  String get syncKey => syncId ?? id;

  VaultEntry({
    required this.id,
    required this.title,
    required this.siteName,
    required this.kind,
    required this.ext,
    required this.size,
    this.thumbnailUrl,
    DateTime? addedAt,
    this.syncId,
  }) : addedAt = addedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'siteName': siteName,
    'kind': kind.name,
    'ext': ext,
    'size': size,
    'thumb': thumbnailUrl?.toString(),
    'addedAt': addedAt.millisecondsSinceEpoch,
    'syncId': ?syncId,
  };

  factory VaultEntry.fromJson(Map<String, dynamic> j) => VaultEntry(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    siteName: j['siteName'] as String? ?? '',
    kind: MediaKind.parse(j['kind'] as String?),
    ext: j['ext'] as String? ?? 'bin',
    size: j['size'] as int? ?? 0,
    thumbnailUrl: Uri.tryParse(j['thumb'] as String? ?? ''),
    addedAt: DateTime.fromMillisecondsSinceEpoch(j['addedAt'] as int? ?? 0),
    syncId: j['syncId'] as String?,
  );
}

/// Downloads kept inside the app, encrypted (AES-GCM) with a key stored in the device's secure storage.
/// Nothing in here shows up in the gallery or the Downloads folder.
class Vault extends ChangeNotifier {
  static final Vault shared = Vault._();
  Vault._();

  static const _storage = FlutterSecureStorage();

  /// Files are sealed in 1 MB pieces so big videos never have to fit in memory at once.
  static const _chunk = 1 << 20;

  List<VaultEntry> entries = [];

  String get _dir => '${Disk.dir.path}${Platform.pathSeparator}Vault';
  String get _openDir => '${Directory.systemTemp.path}${Platform.pathSeparator}inutt-vault-open';

  void load() {
    final raw = Disk.load('vault.json');
    if (raw is List) entries = raw.map((e) => VaultEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  int get totalSize => entries.fold(0, (a, e) => a + e.size);

  void _save() {
    notifyListeners();
    Disk.save('vault.json', entries.map((e) => e.toJson()).toList());
  }

  Future<List<int>> _key() async {
    final s = await _storage.read(key: 'vaultKey');
    if (s != null) return base64Decode(s);
    final r = Random.secure();
    final k = List<int>.generate(32, (_) => r.nextInt(256));
    await _storage.write(key: 'vaultKey', value: base64Encode(k));
    return k;
  }

  /// Encrypts a downloaded file into the vault and deletes the plain copy.
  Future<void> add(File plain, MediaItem item, String ext) async {
    await Directory(_dir).create(recursive: true);
    final id = hashKey('${DateTime.now().microsecondsSinceEpoch}${item.id}');
    final dest = '$_dir${Platform.pathSeparator}$id';
    final key = await _key();
    final src = plain.path;
    final size = await Isolate.run(() => _seal(src, dest, key));
    try {
      await plain.delete();
    } catch (_) {}
    entries.insert(
      0,
      VaultEntry(
        id: id,
        title: item.displayTitle,
        siteName: item.siteName,
        kind: item.kind,
        ext: ext,
        size: size,
        thumbnailUrl: item.thumbnailUrl,
      ),
    );
    _save();
  }

  /// Used by sync: a file that came from another device, already decrypted to `plain`.
  Future<void> addSynced(File plain, VaultEntry e) async {
    await Directory(_dir).create(recursive: true);
    final id = hashKey('${DateTime.now().microsecondsSinceEpoch}${e.syncKey}');
    final dest = '$_dir${Platform.pathSeparator}$id';
    final key = await _key();
    final src = plain.path;
    final size = await Isolate.run(() => _seal(src, dest, key));
    try {
      await plain.delete();
    } catch (_) {}
    entries.add(
      VaultEntry(
        id: id,
        title: e.title,
        siteName: e.siteName,
        kind: e.kind,
        ext: e.ext,
        size: size,
        thumbnailUrl: e.thumbnailUrl,
        addedAt: e.addedAt,
        syncId: e.syncKey,
      ),
    );
    entries.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    _save();
  }

  /// A plain copy to show or play. Removed when the vault closes or the app goes to the background.
  Future<File> open(VaultEntry e) async {
    await Directory(_openDir).create(recursive: true);
    final out = File('$_openDir${Platform.pathSeparator}${e.id}.${e.ext}');
    if (out.existsSync()) return out;
    final key = await _key();
    final src = '$_dir${Platform.pathSeparator}${e.id}';
    final dst = out.path;
    await Isolate.run(() => _unseal(src, dst, key));
    return out;
  }

  void delete(VaultEntry e) {
    try {
      File('$_dir${Platform.pathSeparator}${e.id}').deleteSync();
    } catch (_) {}
    entries.removeWhere((x) => x.id == e.id);
    _save();
  }

  /// Removes every plain copy made for viewing.
  void closeOpenFiles() {
    try {
      final d = Directory(_openDir);
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
  }

  static Future<int> _seal(String src, String dest, List<int> key) async {
    final algo = AesGcm.with256bits();
    final k = SecretKey(key);
    final input = await File(src).open();
    final out = await File(dest).open(mode: FileMode.write);
    var total = 0;
    try {
      while (true) {
        final piece = await input.read(_chunk);
        if (piece.isEmpty) break;
        final box = await algo.encrypt(piece, secretKey: k);
        final sealed = box.concatenation();
        final len = ByteData(4)..setUint32(0, sealed.length);
        await out.writeFrom(len.buffer.asUint8List());
        await out.writeFrom(sealed);
        total += piece.length;
      }
    } finally {
      await input.close();
      await out.close();
    }
    return total;
  }

  static Future<void> _unseal(String src, String dest, List<int> key) async {
    final algo = AesGcm.with256bits();
    final k = SecretKey(key);
    final input = await File(src).open();
    final out = await File(dest).open(mode: FileMode.write);
    try {
      while (true) {
        final head = await input.read(4);
        if (head.length < 4) break;
        final len = ByteData.sublistView(head).getUint32(0);
        final body = await input.read(len);
        if (body.length != len) throw const FormatException('Damaged vault file');
        final box = SecretBox.fromConcatenation(body, nonceLength: 12, macLength: 16);
        await out.writeFrom(await algo.decrypt(box, secretKey: k));
      }
    } finally {
      await input.close();
      await out.close();
    }
  }
}
