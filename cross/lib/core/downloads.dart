import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import 'feed_engine.dart';
import 'models.dart';
import 'net.dart';

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
    active.add(item.id);
    notifyListeners();
    try {
      final r = await FeedEngine.shared.resolve(item);
      if (r == null || r.isListing) throw Exception('Nothing to download.');
      final urls = r.gallery.isNotEmpty && r.kind != MediaKind.video ? r.gallery : [r.url];
      var saved = 0;
      for (final u in urls) {
        if (u.toString().contains('.m3u8')) {
          show('Streaming videos can\'t be downloaded.', success: false);
          return;
        }
        final bytes = await Net.bytes(u, referer: r.referer);
        var name = u.pathSegments.isEmpty ? 'media' : u.pathSegments.last;
        if (!name.contains('.')) name += r.kind == MediaKind.video ? '.mp4' : (r.kind == MediaKind.gif ? '.gif' : '.jpg');
        name = '${DateTime.now().millisecondsSinceEpoch}_${name.replaceAll(RegExp(r'[^\w.\-]'), '_')}';
        final file = File('${(await _folder()).path}${Platform.pathSeparator}$name');
        await file.writeAsBytes(bytes);
        if (Platform.isAndroid) {
          // The gallery is the only place on Android where the user can find the file.
          if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
            show('Allow access to photos to save downloads', success: false);
            return;
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
      final count = saved > 1 ? ' ($saved)' : '';
      show(Platform.isWindows ? 'Saved to Downloads › iNUTT Downloads$count' : 'Saved to gallery › iNUTT$count');
    } catch (e) {
      show('Download failed', success: false);
    } finally {
      active.remove(item.id);
      notifyListeners();
    }
  }
}
