import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'extras.dart';
import 'stores.dart';
import 'site_adapters.dart';

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
    // Adult sites show their content only once the age gate has been passed.
    // Plus whatever you signed in to in the in-app browser.
    final login = CookieJar.headerFor(url);
    req.headers.set(HttpHeaders.cookieHeader, login == null ? SiteAdapters.cookieHeader : '${SiteAdapters.cookieHeader}; $login');
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

  /// Streams a file straight to disk. Returns its size.
  static Future<int> download(Uri url, File dest, {Uri? referer}) async {
    final req = await _client.getUrl(url).timeout(const Duration(seconds: 25));
    req.headers.set(HttpHeaders.userAgentHeader, userAgent);
    if (referer != null) req.headers.set('Referer', referer.toString());
    final login = CookieJar.headerFor(url);
    if (login != null) req.headers.set(HttpHeaders.cookieHeader, login);
    final resp = await req.close().timeout(const Duration(seconds: 25));
    if (resp.statusCode >= 400) {
      await resp.drain<void>();
      throw NetException('The site returned error ${resp.statusCode}.');
    }
    final tmp = File('${dest.path}.part');
    final sink = tmp.openWrite();
    var n = 0;
    try {
      await for (final chunk in resp) {
        n += chunk.length;
        sink.add(chunk);
      }
      await sink.close();
    } catch (_) {
      await sink.close();
      try {
        await tmp.delete();
      } catch (_) {}
      rethrow;
    }
    await tmp.rename(dest.path);
    return n;
  }

  /// Reddit JSON, trying www and old.reddit.com; adult subreddits need the over18 cookie.
  static Future<List<int>> redditJson(Uri jsonUrl) async {
    Object lastError = NetException('Reddit did not answer.');
    for (final host in ['www.reddit.com', 'old.reddit.com']) {
      try {
        final r = await fetch(
          jsonUrl.replace(host: host),
          ua: redditUserAgent,
          headers: {'Accept': 'application/json', 'Cookie': 'over18=1'},
        );
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
  static Map<String, String> playerHeaders(Uri? referer, [Uri? media]) => {
    'User-Agent': userAgent,
    if (media != null && CookieJar.headerFor(media) != null) 'Cookie': CookieJar.headerFor(media)!,
    if (referer != null) 'Referer': referer.toString(),
    // CDNs that check where a stream is played from also look at the origin.
    if (referer != null && referer.hasScheme) 'Origin': '${referer.scheme}://${referer.host}',
  };
}

enum RenderPriority { user, background }

/// The one browser engine every web view and cookie call shares. On Windows it has to exist before
/// the first of them: the plugin's built-in default is made lazily, and several sites loading at once
/// on launch would use it before it is ready and crash the app. Null on Windows without WebView2.
class WebEnv {
  static Future<WebViewEnvironment?>? _env;

  static Future<WebViewEnvironment?> get() => _env ??= _create();

  static Future<WebViewEnvironment?> _create() async {
    if (!Platform.isWindows) return null;
    try {
      if (await WebViewEnvironment.getAvailableVersion() == null) return null;
      return await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(userDataFolder: '${Disk.dir.path}${Platform.pathSeparator}WebView2'),
      );
    } catch (e) {
      debugPrint('WebView2 unavailable: $e');
      return null;
    }
  }

  /// Whether web views can be used at all here.
  static Future<bool> available() async => !Platform.isWindows || await get() != null;

  /// The cookie jar of that engine, or null when there is no engine.
  static Future<CookieManager?> cookies() async {
    if (!await available()) return null;
    return CookieManager.instance(webViewEnvironment: await get());
  }
}

/// Renders JavaScript-heavy pages off screen and returns the final DOM. Nothing of it is ever shown.
/// What the user tapped runs in its own lane, so it never waits behind background refreshes.
class PageRenderer {
  static final PageRenderer shared = PageRenderer._();
  PageRenderer._();

  final _active = {RenderPriority.user: 0, RenderPriority.background: 0};
  // On Windows the hidden browser works on the same thread that draws the app, so fewer run at once.
  static final _limits = {
    RenderPriority.user: Platform.isWindows ? 2 : 3,
    RenderPriority.background: Platform.isWindows ? 1 : 2,
  };

  /// Background pages wait while the user is waiting for something.
  int _userWaiting = 0;
  DateTime _lastInput = DateTime.fromMillisecondsSinceEpoch(0);

  /// Windows: a click or scroll just happened; background pages hold off until the app is idle again.
  void noteInput() => _lastInput = DateTime.now();

  bool get _busy => Platform.isWindows && DateTime.now().difference(_lastInput) < const Duration(milliseconds: 1500);

  Future<void> _acquire(RenderPriority p) async {
    if (p == RenderPriority.user) _userWaiting++;
    while (_active[p]! >= _limits[p]! || (p == RenderPriority.background && (_userWaiting > 0 || _busy))) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (p == RenderPriority.user) _userWaiting--;
    _active[p] = _active[p]! + 1;
  }

  void _release(RenderPriority p) => _active[p] = _active[p]! - 1;

  /// An off-screen web view that starts loading `url`. `loaded` completes when the page finished or failed.
  Future<(HeadlessInAppWebView, Completer<bool>)> _open(Uri url, {required bool media}) async {
    final loaded = Completer<bool>();
    // Adult sites show their content only once the age gate has been passed.
    if (!await WebEnv.available()) throw StateError('No web engine on this computer');
    try {
      final jar = (await WebEnv.cookies())!;
      final domain = '.${url.host.split('.').reversed.take(2).toList().reversed.join('.')}';
      for (final e in SiteAdapters.ageCookies.entries) {
        await jar.setCookie(url: WebUri.uri(url), name: e.key, value: e.value, domain: domain, path: '/');
      }
    } catch (_) {}
    final web = HeadlessInAppWebView(
      webViewEnvironment: await WebEnv.get(),
      initialUrlRequest: URLRequest(url: WebUri.uri(url)),
      initialSize: const Size(390, 844),
      initialSettings: InAppWebViewSettings(
        userAgent: Net.userAgent,
        mediaPlaybackRequiresUserGesture: !media,
        allowsInlineMediaPlayback: true,
        javaScriptEnabled: true,
        blockNetworkImage: !media,
      ),
      onLoadStop: (c, _) {
        if (!loaded.isCompleted) loaded.complete(true);
      },
      onReceivedError: (c, req, err) {
        if (req.isForMainFrame == true && !loaded.isCompleted) loaded.complete(false);
      },
    );
    await web.run();
    return (web, loaded);
  }

  Future<void> _close(HeadlessInAppWebView web) async {
    try {
      await web.dispose();
    } catch (_) {}
  }

  Future<dynamic> _js(HeadlessInAppWebView web, String source) async {
    try {
      return await web.webViewController?.evaluateJavascript(source: source);
    } catch (_) {
      return null;
    }
  }

  /// The final DOM of a listing page.
  Future<String?> render(Uri url, {double settle = 1.5, RenderPriority priority = RenderPriority.background}) async {
    await _acquire(priority);
    HeadlessInAppWebView? web;
    try {
      final (w, loaded) = await _open(url, media: false);
      web = w;
      final ok = await loaded.future.timeout(const Duration(seconds: 14), onTimeout: () => false);
      if (!ok && await w.webViewController?.getUrl() == null) return null;
      if (await _js(w, SiteAdapters.ageGateScript) == 2) {
        await Future<void>.delayed(const Duration(milliseconds: 2500));
      }
      // Trigger lazy-loaded content.
      for (var i = 0; i < 3; i++) {
        await _js(w, 'window.scrollTo(0, document.body.scrollHeight); 1');
        await Future<void>.delayed(Duration(milliseconds: (settle / 3 * 1000).round()));
      }
      final html = await _js(w, 'document.documentElement.outerHTML');
      return html is String ? html : null;
    } catch (e) {
      debugPrint('render failed: $e');
      return null;
    } finally {
      if (web != null) await _close(web);
      _release(priority);
    }
  }

  /// Opens one video's page and returns as soon as the page reveals its video file, instead of waiting
  /// for the whole page. Falls back to the page's HTML when no video shows up in time.
  Future<(CapturedVideo?, String?)> renderMedia(Uri url) async {
    await _acquire(RenderPriority.user);
    HeadlessInAppWebView? web;
    try {
      final (w, _) = await _open(url, media: true);
      web = w;
      final started = DateTime.now();
      while (DateTime.now().difference(started).inMilliseconds < 9000) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await _js(w, SiteAdapters.ageGateScript);
        await _js(w, _playScript);
        final list = await _collect(w, url);
        for (final v in list) {
          if (!isAd(v.url)) return (v, null);
        }
      }
      final html = await _js(w, 'document.documentElement.outerHTML');
      return (null, html is String ? html : null);
    } catch (e) {
      debugPrint('renderMedia failed: $e');
      return (null, null);
    } finally {
      if (web != null) await _close(web);
      _release(RenderPriority.user);
    }
  }

  /// Opens a TikTok-style page off screen, swipes through its feed and collects every video it loads:
  /// `<video>` sources and video files the page requests. `onFound` gets each new batch right away;
  /// `cancelled` stops early.
  Future<List<CapturedVideo>> captureVideos(
    Uri url, {
    int rounds = 10,
    void Function(List<CapturedVideo>)? onFound,
    bool Function()? cancelled,
  }) async {
    await _acquire(RenderPriority.user);
    HeadlessInAppWebView? web;
    final found = <CapturedVideo>[];
    final keys = <String>{};
    void take(List<CapturedVideo> list) {
      final fresh = <CapturedVideo>[];
      for (final v in list) {
        if (!isAd(v.url) && keys.add(videoKey(v.url))) fresh.add(v);
      }
      if (fresh.isNotEmpty) {
        found.addAll(fresh);
        onFound?.call(fresh);
      }
    }

    bool stop() => cancelled?.call() ?? false;
    try {
      final (w, _) = await _open(url, media: true);
      web = w;
      // Collect while the page is still loading; many feeds show their first video early.
      final started = DateTime.now();
      while (DateTime.now().difference(started).inMilliseconds < 10000 && !stop()) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await _js(w, SiteAdapters.ageGateScript);
        await _js(w, _playScript);
        take(await _collect(w, url));
        if (found.isNotEmpty && DateTime.now().difference(started).inMilliseconds > 2500) break;
      }
      for (var i = 0; i < rounds && !stop(); i++) {
        await _js(w, _swipeScript);
        await Future<void>.delayed(const Duration(milliseconds: 800));
        take(await _collect(w, url));
      }
    } catch (e) {
      debugPrint('capture failed: $e');
    } finally {
      if (web != null) await _close(web);
      _release(RenderPriority.user);
    }
    return found;
  }

  Future<List<CapturedVideo>> _collect(HeadlessInAppWebView web, Uri url) async {
    final json = await _js(web, _collectScript);
    if (json is! String) return const [];
    final Object? list;
    try {
      list = jsonDecode(json);
    } catch (_) {
      return const [];
    }
    if (list is! List) return const [];
    Uri base = url;
    try {
      base = (await web.webViewController?.getUrl()) ?? url;
    } catch (_) {}
    final out = <CapturedVideo>[];
    for (final v in list.whereType<Map>()) {
      final raw = v['u'] as String?;
      final u = raw == null ? null : Uri.tryParse(raw);
      if (u == null) continue;
      final abs = base.resolveUri(u);
      if (abs.scheme != 'http' && abs.scheme != 'https') continue;
      final p = v['p'] as String? ?? '';
      final pu = p.isEmpty ? null : Uri.tryParse(p);
      out.add(CapturedVideo(abs, pu == null ? null : base.resolveUri(pu), v['t'] as String? ?? ''));
    }
    return out;
  }

  /// Pre-roll and tracking clips that pages load next to the real video.
  static bool isAd(Uri u) {
    final s = u.toString().toLowerCase();
    const marks = [
      '/ads/',
      'doubleclick',
      'googlesyndication',
      'imasdk',
      'adserver',
      '/vast',
      'preroll',
      'pre-roll',
      'exoclick',
      'trafficjunky',
      'juicyads',
    ];
    return marks.any(s.contains);
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

  static const _playScript = r"""
(function(){
  document.querySelectorAll('video').forEach(function(v){ v.muted=true; v.preload='auto'; try{ var p=v.play(); if(p&&p.catch)p.catch(function(){}); }catch(e){} });
  var b=document.querySelector('.vjs-big-play-button,.ytp-large-play-button,.play-button,[class*=play-btn],[class*=playButton],[aria-label*=Play i]');
  if(b&&!window.__inuttClicked){ window.__inuttClicked=1; try{ b.click(); }catch(e){} }
  return 1;
})()
""";

  static const _collectScript = r"""
(function(){
  var out=[], seen={};
  function add(u,p,t){ if(!u||u.indexOf('blob:')===0||u.indexOf('data:')===0||seen[u])return; seen[u]=1; out.push({u:String(u),p:String(p||''),t:String(t||'')}); }
  document.querySelectorAll('video').forEach(function(v){
    var p=v.poster||v.getAttribute('data-poster')||'';
    var box=v.closest('article,li,section,[class*=item],[class*=card],[class*=reel],[class*=short],[class*=video],[class*=post]');
    var t=box&&box.innerText?box.innerText.trim().split('\n')[0].slice(0,140):'';
    add(v.currentSrc||v.src||v.getAttribute('data-src'),p,t);
    v.querySelectorAll('source').forEach(function(s){ add(s.src||s.getAttribute('data-src'),p,t); });
  });
  ['og:video:secure_url','og:video:url','og:video'].forEach(function(n){
    var m=document.querySelector('meta[property="'+n+'"],meta[name="'+n+'"]');
    if(m&&/\.(mp4|m3u8|webm|mov)(\?|#|$)/i.test(m.content||'')) add(m.content,'','');
  });
  (performance.getEntriesByType('resource')||[]).forEach(function(e){
    var n=e.name; if(/\.(mp4|m3u8|webm|mov)(\?|#|$)/i.test(n)&&!/\.(ts|m4s)(\?|#|$)/i.test(n)) add(n,'','');
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
  document.querySelectorAll('video').forEach(function(v){ v.muted=true; var r=v.getBoundingClientRect(); if(r.top<h&&r.bottom>0){ try{ var p=v.play(); if(p&&p.catch)p.catch(function(){}); }catch(e){} } });
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
