import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

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

  /// Opens a TikTok-style page off screen, swipes through its feed and collects every video it loads:
  /// `<video>` sources and video files the page requests. `rounds` is how many screens to swipe.
  Future<List<CapturedVideo>> captureVideos(Uri url, {int rounds = 10}) {
    final c = Completer<List<CapturedVideo>>();
    _queue = _queue.then((_) async => c.complete(await _capture(url, rounds)), onError: (_) => c.complete(const []));
    return c.future;
  }

  Future<List<CapturedVideo>> _capture(Uri url, int rounds) async {
    final loaded = Completer<InAppWebViewController?>();
    HeadlessInAppWebView? web;
    final found = <CapturedVideo>[];
    final keys = <String>{};
    try {
      web = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri.uri(url)),
        initialSize: const Size(390, 844),
        initialSettings: InAppWebViewSettings(
          userAgent: Net.userAgent,
          mediaPlaybackRequiresUserGesture: false,
          allowsInlineMediaPlayback: true,
          javaScriptEnabled: true,
        ),
        onLoadStop: (c, _) {
          if (!loaded.isCompleted) loaded.complete(c);
        },
        onReceivedError: (c, req, err) {
          if (req.isForMainFrame == true && !loaded.isCompleted) loaded.complete(null);
        },
      );
      await web.run();
      final c = await loaded.future.timeout(const Duration(seconds: 18), onTimeout: () => web?.webViewController);
      if (c == null) return found;
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      for (var round = 0; round <= rounds; round++) {
        if (round > 0) {
          await c.evaluateJavascript(source: _swipeScript);
          await Future<void>.delayed(const Duration(milliseconds: 900));
        }
        final page = await c.getUrl();
        final json = await c.evaluateJavascript(source: _collectScript);
        if (json is! String) continue;
        final list = jsonDecode(json);
        if (list is! List) continue;
        for (final v in list.whereType<Map>()) {
          final raw = v['u'] as String?;
          if (raw == null) continue;
          final base = page ?? url;
          final u = Uri.tryParse(raw);
          if (u == null) continue;
          final abs = base.resolveUri(u);
          final key = videoKey(abs);
          if (!keys.add(key)) continue;
          final p = v['p'] as String? ?? '';
          final pu = p.isEmpty ? null : Uri.tryParse(p);
          found.add(CapturedVideo(abs, pu == null ? null : base.resolveUri(pu), v['t'] as String? ?? ''));
        }
      }
    } catch (e) {
      debugPrint('capture failed: $e');
    } finally {
      try {
        await web?.dispose();
      } catch (_) {}
    }
    return found;
  }

  /// HLS variants of one video share a folder; count them once.
  static String videoKey(Uri u) {
    final path = u.path;
    if (path.toLowerCase().endsWith('.m3u8')) {
      final i = path.lastIndexOf('/');
      return u.host + (i > 0 ? path.substring(0, i) : path);
    }
    return u.host + path;
  }

  static const _collectScript = r"""
(function(){
  var out=[], seen={};
  function add(u,p,t){ if(!u||u.indexOf('blob:')===0||u.indexOf('data:')===0||seen[u])return; seen[u]=1; out.push({u:String(u),p:String(p||''),t:String(t||'')}); }
  document.querySelectorAll('video').forEach(function(v){
    v.muted=true; v.preload='auto';
    var p=v.poster||v.getAttribute('data-poster')||'';
    var box=v.closest('article,li,section,[class*=item],[class*=card],[class*=reel],[class*=short],[class*=video],[class*=post]');
    var t=box&&box.innerText?box.innerText.trim().split('\n')[0].slice(0,140):'';
    add(v.currentSrc||v.src||v.getAttribute('data-src'),p,t);
    v.querySelectorAll('source').forEach(function(s){ add(s.src||s.getAttribute('data-src'),p,t); });
  });
  (performance.getEntriesByType('resource')||[]).forEach(function(e){
    var n=e.name; if(/\.(mp4|m3u8|webm|mov)(\?|#|$)/i.test(n)) add(n,'','');
  });
  return JSON.stringify(out);
})()
""";

  static const _swipeScript = r"""
(function(){
  var h=window.innerHeight;
  document.querySelectorAll('*').forEach(function(e){
    var s=getComputedStyle(e);
    if((s.overflowY==='auto'||s.overflowY==='scroll')&&e.scrollHeight>e.clientHeight+50) e.scrollTop+=e.clientHeight||h;
  });
  window.scrollBy(0,h);
  document.querySelectorAll('video').forEach(function(v){ v.muted=true; var r=v.getBoundingClientRect(); if(r.top<h&&r.bottom>0){ try{v.play();}catch(e){} } });
  return 1;
})()
""";
}

/// One video found while playing through a page.
class CapturedVideo {
  final Uri url;
  final Uri? poster;
  final String title;
  const CapturedVideo(this.url, this.poster, this.title);
}
