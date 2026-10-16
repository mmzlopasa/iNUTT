import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class NetException implements Exception {
  final String message;
  NetException(this.message);
  @override
  String toString() => message;
}

class FetchResult {
  final List<int> bytes;
  final Uri finalUrl;
  final String? charset;
  FetchResult(this.bytes, this.finalUrl, this.charset);

  String get text {
    final cs = charset?.toLowerCase();
    if (cs != null && (cs.contains('8859') || cs.contains('latin'))) return latin1.decode(bytes, allowInvalid: true);
    return utf8.decode(bytes, allowMalformed: true);
  }
}

class Net {
  static const userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36';

  /// Reddit asks apps for a descriptive user agent and answers browsers less reliably.
  static const redditUserAgent = 'android:dev.scyde.inutt:v1.0 (by /u/inutt_app)';

  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 6
    ..autoUncompress = true;

  static Future<FetchResult> fetch(Uri url, {Uri? referer, Map<String, String>? headers, String? ua}) async {
    final req = await _client.getUrl(url).timeout(const Duration(seconds: 25));
    req.followRedirects = true;
    req.maxRedirects = 8;
    req.headers.set(HttpHeaders.userAgentHeader, ua ?? userAgent);
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
    req.headers.set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml,application/xml;q=0.9,application/json;q=0.8,*/*;q=0.7');
    if (referer != null) req.headers.set('Referer', referer.toString());
    headers?.forEach(req.headers.set);
    final resp = await req.close().timeout(const Duration(seconds: 25));
    if (resp.statusCode >= 400) {
      await resp.drain<void>();
      throw NetException('The site returned error ${resp.statusCode}.');
    }
    final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b)).timeout(const Duration(seconds: 60));
    if (bytes.isEmpty) throw NetException('The page is empty.');
    var finalUrl = url;
    for (final r in resp.redirects) {
      finalUrl = finalUrl.resolveUri(r.location);
    }
    return FetchResult(bytes, finalUrl, resp.headers.contentType?.charset);
  }

  static Future<List<int>> bytes(Uri url, {Uri? referer}) async => (await fetch(url, referer: referer)).bytes;

  /// Reddit JSON, trying www and old.reddit.com; adult subreddits need the over18 cookie.
  static Future<List<int>> redditJson(Uri jsonUrl) async {
    Object lastError = NetException('Reddit did not answer.');
    for (final host in ['www.reddit.com', 'old.reddit.com']) {
      try {
        final r = await fetch(jsonUrl.replace(host: host),
            ua: redditUserAgent, headers: {'Accept': 'application/json', 'Cookie': 'over18=1'});
        // Blocked requests come back as an HTML page.
        final first = r.bytes.firstWhere((b) => b != 0x20 && b != 0x0A && b != 0x0D && b != 0x09, orElse: () => 0);
        if (first == 0x7B || first == 0x5B) return r.bytes;
        lastError = NetException('Reddit refused the request.');
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError;
  }

  /// Headers the video player should send so hot-link protected media plays.
  static Map<String, String> playerHeaders(Uri? referer) => {
        'User-Agent': userAgent,
        if (referer != null) 'Referer': referer.toString(),
      };
}

/// Renders JavaScript-heavy pages off screen and returns the final DOM. Nothing of it is ever shown.
class PageRenderer {
  static final PageRenderer shared = PageRenderer._();
  PageRenderer._();

  Future<void> _queue = Future.value();

  Future<String?> render(Uri url, {double settle = 1.5}) {
    final c = Completer<String?>();
    _queue = _queue.then((_) async => c.complete(await _render(url, settle)), onError: (_) => c.complete(null));
    return c.future;
  }

  Future<String?> _render(Uri url, double settle) async {
    final done = Completer<String?>();
    HeadlessInAppWebView? web;
    Timer? deadline;
    Future<void> grab(InAppWebViewController c) async {
      await Future<void>.delayed(Duration(milliseconds: (settle * 1000).round()));
      try {
        // Scroll once so lazy grids load their first screens.
        await c.evaluateJavascript(source: 'window.scrollTo(0, document.body.scrollHeight / 2);');
        await Future<void>.delayed(const Duration(milliseconds: 600));
        final html = await c.evaluateJavascript(source: 'document.documentElement.outerHTML');
        if (!done.isCompleted) done.complete(html is String ? html : null);
      } catch (_) {
        if (!done.isCompleted) done.complete(null);
      }
    }

    try {
      web = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri.uri(url)),
        initialSettings: InAppWebViewSettings(
          userAgent: Net.userAgent,
          mediaPlaybackRequiresUserGesture: true,
          javaScriptEnabled: true,
          blockNetworkImage: true,
        ),
        onLoadStop: (c, _) => grab(c),
        onReceivedError: (c, req, err) {
          if (req.isForMainFrame == true && !done.isCompleted) done.complete(null);
        },
      );
      deadline = Timer(const Duration(seconds: 20), () {
        if (!done.isCompleted) done.complete(null);
      });
      await web.run();
      return await done.future;
    } catch (e) {
      debugPrint('render failed: $e');
      return null;
    } finally {
      deadline?.cancel();
      try {
        await web?.dispose();
      } catch (_) {}
    }
  }
}
