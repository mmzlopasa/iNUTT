import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'net.dart';

/// Memory + disk cache for thumbnails and images, so everything already seen shows instantly.
class ImagePipeline {
  static final ImagePipeline shared = ImagePipeline._();
  ImagePipeline._();

  late Directory _dir;
  final LinkedHashMap<String, Uint8List> _memory = LinkedHashMap();
  int _memoryBytes = 0;
  static const _memoryLimit = 160 * 1024 * 1024;
  final Map<String, Future<Uint8List?>> _inFlight = {};
  int _running = 0;
  final Queue<Completer<void>> _waiting = Queue();

  Future<void> init() async {
    _dir = Directory('${(await getApplicationCacheDirectory()).path}${Platform.pathSeparator}inutt-images');
    await _dir.create(recursive: true);
    unawaited(trimDisk());
  }

  String _key(Uri url) => hashKey(url.toString());
  File _file(String key) => File('${_dir.path}${Platform.pathSeparator}$key');

  /// Bytes already in memory; never blocks.
  Uint8List? cached(Uri? url) {
    if (url == null) return null;
    final k = _key(url);
    final b = _memory.remove(k);
    if (b != null) _memory[k] = b;
    return b;
  }

  Future<Uint8List?> load(Uri url, {Uri? referer}) {
    final k = _key(url);
    final mem = cached(url);
    if (mem != null) return Future.value(mem);
    return _inFlight.putIfAbsent(k, () async {
      try {
        if (url.scheme == 'file') {
          final b = await File.fromUri(url).readAsBytes();
          _remember(k, b);
          return b;
        }
        final f = _file(k);
        if (await f.exists()) {
          final b = await f.readAsBytes();
          _remember(k, b);
          return b;
        }
        await _acquire();
        try {
          final b = Uint8List.fromList(await Net.bytes(url, referer: referer));
          _remember(k, b);
          unawaited(f.writeAsBytes(b, flush: false).then((_) {}, onError: (_) {}));
          return b;
        } finally {
          _release();
        }
      } catch (_) {
        return null;
      } finally {
        _inFlight.remove(k);
      }
    });
  }

  void prefetch(List<(Uri, Uri?)> urls) {
    for (final (u, r) in urls.take(80)) {
      if (cached(u) == null) unawaited(load(u, referer: r));
    }
  }

  void _remember(String k, Uint8List b) {
    _memory[k] = b;
    _memoryBytes += b.length;
    while (_memoryBytes > _memoryLimit && _memory.isNotEmpty) {
      final first = _memory.keys.first;
      _memoryBytes -= _memory.remove(first)!.length;
    }
  }

  Future<void> _acquire() async {
    if (_running < 8) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _waiting.add(c);
    await c.future;
    _running++;
  }

  void _release() {
    _running--;
    if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
  }

  Future<int> diskUsage() async {
    var total = 0;
    try {
      await for (final e in _dir.list()) {
        if (e is File) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  Future<void> clear() async {
    _memory.clear();
    _memoryBytes = 0;
    try {
      await _dir.delete(recursive: true);
    } catch (_) {}
    await _dir.create(recursive: true);
  }

  /// Keeps the disk cache under 1.5 GB, dropping the oldest files first.
  Future<void> trimDisk() async {
    try {
      final files = <(File, FileStat)>[];
      await for (final e in _dir.list()) {
        if (e is File) files.add((e, await e.stat()));
      }
      var total = files.fold<int>(0, (s, f) => s + f.$2.size);
      const limit = 1536 * 1024 * 1024;
      if (total <= limit) return;
      files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (f, st) in files) {
        if (total <= limit * 0.8) break;
        await f.delete();
        total -= st.size;
      }
    } catch (_) {}
  }
}
