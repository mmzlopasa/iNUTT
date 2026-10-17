import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import 'feed_engine.dart';
import 'models.dart';
import 'net.dart';
import 'stores.dart';
import 'vault.dart';

class Toast {
  final String message;
  final bool success;
  final int id = DateTime.now().microsecondsSinceEpoch;
  Toast(this.message, {this.success = true});
}

/// Saves media to the gallery (Android) or the Downloads folder (Windows).
class DownloadManager extends ChangeNotifier {
  static final DownloadManager shared = DownloadManager._();
  DownloadManager._();

  Toast? toast;
  final Set<String> active = {};
  Timer? _toastTimer;

  void show(String message, {bool success = true}) {
    toast = Toast(message, success: success);
    notifyListeners();
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 2600), () {
      toast = null;
      notifyListeners();
    });
  }

  Future<Directory> _folder() async {
    Directory? base;
    if (Platform.isWindows) base = await getDownloadsDirectory();
    base ??= await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}iNUTT Downloads');
    await d.create(recursive: true);
    return d;
  }

  Future<void> download(MediaItem item) async {
    if (active.contains(item.id)) return;
    await _perform(item, null);
  }

  // Download all

  /// Items still waiting; kept on disk so an interrupted batch carries on next time.
  List<MediaItem> queue = [];
  int _total = 0, _done = 0, _failed = 0;
  bool _running = false;

  void downloadAll(List<MediaItem> items) {
    final have = queue.map((e) => e.id).toSet();
    final add = items.where((e) => !e.isListing && !have.contains(e.id)).toList();
    if (add.isEmpty) return;
    queue.addAll(add);
    _total += add.length;
    _saveQueue();
    show('Downloading $_total items');
    unawaited(_runQueue());
  }

  /// Picks up a batch that was interrupted when the app closed.
  void resumeQueue() {
    final raw = Disk.load('downloadQueue.json');
    if (raw is! List || raw.isEmpty || queue.isNotEmpty) return;
    queue = raw.map((e) => MediaItem.fromJson(e as Map<String, dynamic>)).toList();
    _total = queue.length;
    unawaited(_runQueue());
  }

  void _saveQueue() => unawaited(Disk.save('downloadQueue.json', queue.map((e) => e.toJson()).toList()));

  Future<void> _runQueue() async {
    if (_running) return;
    _running = true;
    try {
      while (queue.isNotEmpty) {
        final item = queue.first;
        _done++;
        if (!await _perform(item, (_done, _total))) _failed++;
        if (queue.isNotEmpty) queue.removeAt(0);
        _saveQueue();
      }
      if (_total > 0) {
        final ok = _done - _failed;
        show(_failed == 0 ? 'Downloaded $ok items' : 'Downloaded $ok of $_done items', success: _failed == 0);
      }
    } finally {
      _running = false;
      _total = _done = _failed = 0;
    }
  }

  /// Downloads one item into the gallery, Downloads or the vault. Returns false when it failed.
  Future<bool> _perform(MediaItem item, (int, int)? batch) async {
    active.add(item.id);
    notifyListeners();
    if (batch != null) show('Downloading ${batch.$1} of ${batch.$2}…');
    try {
      final r = await FeedEngine.shared.resolve(item);
      if (r == null || r.isListing) throw Exception('Nothing to download.');
      final urls = r.gallery.isNotEmpty && r.kind != MediaKind.video ? r.gallery : [r.url];
      var saved = 0;
      final vault = AppSettings.shared.vaultDownloads;
      for (final u in urls) {
        if (u.toString().contains('.m3u8')) {
          if (batch == null) show('Streaming videos can\'t be downloaded.', success: false);
          return false;
        }
        final bytes = await Net.bytes(u, referer: r.referer);
        var name = u.pathSegments.isEmpty ? 'media' : u.pathSegments.last;
        if (!name.contains('.')) name += r.kind == MediaKind.video ? '.mp4' : (r.kind == MediaKind.gif ? '.gif' : '.jpg');
        name = '${DateTime.now().millisecondsSinceEpoch}_${name.replaceAll(RegExp(r'[^\w.\-]'), '_')}';
        if (vault) {
          final tmp = File('${Directory.systemTemp.path}${Platform.pathSeparator}$name');
          await tmp.writeAsBytes(bytes);
          final kindItem = MediaItem(
            id: item.id,
            siteId: item.siteId,
            siteName: item.siteName,
            title: item.title,
            thumbnailUrl: item.thumbnailUrl,
            pageUrl: item.pageUrl,
            mediaUrl: u,
            kind: r.kind,
          );
          await Vault.shared.add(tmp, kindItem, name.split('.').last);
          saved++;
          continue;
        }
        final file = File('${(await _folder()).path}${Platform.pathSeparator}$name');
        await file.writeAsBytes(bytes);
        if (Platform.isAndroid) {
          // The gallery is the only place on Android where the user can find the file.
          if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
            show('Allow access to photos to save downloads', success: false);
            return false;
          }
          if (r.kind == MediaKind.video) {
            await Gal.putVideo(file.path, album: 'iNUTT');
          } else {
            await Gal.putImage(file.path, album: 'iNUTT');
          }
          try {
            await file.delete();
          } catch (_) {}
        }
        saved++;
      }
      if (batch == null) {
        final count = saved > 1 ? ' ($saved)' : '';
        show(
          vault
              ? 'Saved to the vault$count'
              : (Platform.isWindows ? 'Saved to Downloads › iNUTT Downloads$count' : 'Saved to gallery › iNUTT$count'),
        );
      }
      return true;
    } catch (e) {
      if (batch == null) show('Download failed', success: false);
      return false;
    } finally {
      active.remove(item.id);
      notifyListeners();
    }
  }
}
