import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'html.dart';
import 'models.dart';
import 'net.dart';
import 'scraper.dart';

/// Things adult and tube sites need before they show their content: age-gate cookies, the
/// KVS player's scrambled video links, JSON feeds, and pages that only exist as an app API.
class SiteAdapters {
  /// Cookies that common age gates set once you confirm you are 18. Harmless on other sites.
  static const ageCookies = {
    'accessAgeDisclaimerPH': '1',
    'accessAgeDisclaimerUK': '1',
    'accessPH': '1',
    'age_verified': '1',
    'ageVerified': '1',
    'age_gate': '1',
    'agecheck': '1',
    'kt_agecheck': '1',
    'over18': '1',
    'adult': '1',
    'disclaimer': '1',
    'warning': '1',
    'mature': '1',
    'is_adult': '1',
    'ageConfirmed': 'true',
    'age_confirmed': '1',
    'confirmed_age': '1',
    'nsfw': '1',
    'verifyAge': '1',
  };

  static String get cookieHeader => ageCookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// Clicks "I am 18 / Enter / Agree" on age and consent overlays, once per page.
  /// Returns 2 when it clicked something.
  static const ageGateScript = r"""
(function(){
  try{ if(window.performance&&performance.setResourceTimingBufferSize) performance.setResourceTimingBufferSize(5000); }catch(e){}
  if(window.__inuttGate) return 1;
  var re=/(i am|i'm|i’m)\s*(18|over|an adult|of legal)|^\s*(enter|enter site|yes|agree|i agree|accept|continue|ok|confirm|18\+)\s*[!.»>]*\s*$|over 18|18 or older|18\+ enter/i;
  var boxRe=/age|adult|disclaimer|gate|consent|warning|modal|overlay|popup|dialog|verify|18/i;
  var els=document.querySelectorAll('button,a,[role=button],input[type=button],input[type=submit],div[onclick],span[onclick]');
  for(var i=0;i<els.length;i++){
    var e=els[i]; var t=(e.innerText||e.value||'').trim();
    if(!t||t.length>40||!re.test(t)) continue;
    var hint='';
    for(var n=e, k=0; n&&k<6; n=n.parentElement, k++) hint+=' '+(n.className||'')+' '+(n.id||'');
    if(!/18|adult/i.test(t) && !boxRe.test(hint)) continue;
    window.__inuttGate=1;
    try{ e.click(); }catch(x){}
    return 2;
  }
  return 1;
})()
""";

  // KVS players

  /// Many tube sites run KVS, whose player hides the real file behind `function/0/` and a license code.
  static String kvsRealUrl(String raw, String? license) {
    const prefix = 'function/0/';
    if (!raw.startsWith(prefix)) return raw;
    final s = raw.substring(prefix.length);
    final u = Uri.tryParse(s);
    if (license == null || u == null) return s;
    final token = _kvsToken(license);
    final parts = u.path.split('/');
    if (parts.length <= 3 || parts[3].length < 32 || token.length < 32) return s;
    final hash = parts[3].substring(0, 32);
    final indices = List<int>.generate(32, (i) => i);
    var accum = 0;
    for (var src = 31; src >= 0; src--) {
      accum += token[src];
      final dest = (src + accum) % 32;
      final t = indices[src];
      indices[src] = indices[dest];
      indices[dest] = t;
    }
    parts[3] = indices.map((i) => hash[i]).join() + parts[3].substring(32);
    return u.replace(path: parts.join('/')).toString();
  }

  static List<int> _kvsToken(String license) {
    final lic = license.replaceAll(r'$', '');
    if (lic.length < 4 || !RegExp(r'^\d+$').hasMatch(lic)) return const [];
    final values = lic.split('').map(int.parse).toList();
    final mod = lic.replaceAll('0', '1');
    final center = mod.length ~/ 2;
    final front = int.tryParse(mod.substring(0, min(center + 1, mod.length)));
    final back = int.tryParse(mod.substring(center));
    if (front == null || back == null) return const [];
    final full = (4 * (front - back).abs()).toString();
    final modlicense = full.substring(0, min(center + 1, full.length));
    final out = <int>[];
    for (var index = 0; index < modlicense.length; index++) {
      final current = int.parse(modlicense[index]);
      for (var offset = 0; offset < 4; offset++) {
        if (index + offset < values.length) out.add((values[index + offset] + current) % 10);
      }
    }
    return out;
  }

  /// Video files of a KVS player page, with their quality labels.
  static List<(String, String?)> kvsVideos(String html) {
    final license = Html.first(r'''license_code\s*:\s*['"]([^'"]+)['"]''', html);
    final out = <(String, String?)>[];
    for (final m in Html.matches(r'''\b(video_url|video_alt_url\d*)\s*:\s*['"]([^'"]+)['"]''', html, limit: 10)) {
      final key = m[1];
      final raw = m[2];
      if (key == null || raw == null) continue;
      final label = Html.first(
        '${RegExp.escape(key)}'
        r'''_text\s*:\s*['"]([^'"]+)['"]''',
        html,
      );
      out.add((kvsRealUrl(raw, license), label));
    }
    return out;
  }

  // JSON feeds

  static bool looksLikeJson(List<int> bytes) {
    for (final b in bytes) {
      if (b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09) continue;
      return b == 0x7B || b == 0x5B;
    }
    return false;
  }

  /// Any JSON listing: every object holding a video or image file becomes an item.
  static ScrapeResult parseJsonListing(String text, Uri base, Site site, String? categoryName) {
    final result = ScrapeResult();
    final Object? root;
    try {
      root = jsonDecode(text);
    } catch (_) {
      return result;
    }
    final seen = <String>{};
    final imageRe = RegExp(r'\.(jpe?g|png|webp|gif)(\?|$)');

    void visit(Object? node, int depth) {
      if (depth >= 8 || result.items.length >= 300) return;
      if (node is List) {
        for (final v in node) {
          visit(v, depth + 1);
        }
        return;
      }
      if (node is! Map) return;
      Uri? video, image, page;
      var title = '';
      node.forEach((k, v) {
        final key = k.toString().toLowerCase();
        if (v is String && v.isNotEmpty) {
          final lower = v.toLowerCase();
          final isLink = lower.startsWith('http') || lower.startsWith('/');
          if (video == null &&
              isLink &&
              (lower.contains('.m3u8') ||
                  lower.contains('.mp4') ||
                  lower.contains('.webm') ||
                  (key.contains('stream') && key.contains('video')))) {
            video = Html.resolve(v, base);
          } else if (image == null &&
              isLink &&
              (key.contains('thumb') ||
                  key.contains('poster') ||
                  key.contains('cover') ||
                  key.contains('preview') ||
                  key.contains('image') ||
                  imageRe.hasMatch(lower))) {
            image = Html.resolve(v, base);
          } else if (page == null && isLink && const ['url', 'link', 'permalink', 'href', 'page_url', 'pageurl'].contains(key)) {
            page = Html.resolve(v, base);
          } else if (title.isEmpty && const ['title', 'label', 'name', 'description', 'caption'].contains(key)) {
            title = v;
          }
        } else {
          visit(v, depth + 1);
        }
      });
      if (video == null && image == null) return;
      final media = video ?? image;
      if (!seen.add(media.toString())) return;
      final kind = video != null ? MediaKind.video : (MediaKind.guess(image) == MediaKind.gif ? MediaKind.gif : MediaKind.image);
      result.items.add(
        MediaItem(
          siteId: site.id,
          siteName: site.name,
          title: Scraper.cleanTitle(title),
          thumbnailUrl: image,
          mediaUrl: media,
          pageUrl: video == null ? page : null,
          kind: kind,
          categoryName: categoryName,
        ),
      );
    }

    visit(root, 0);
    return result;
  }

  // App-only sites

  /// FikFap is an app shell; its feed comes from its public API.
  static bool isFikFap(Uri url) => url.host.toLowerCase().endsWith('fikfap.com');

  static final String _anonymousId = _uuid();

  static String _uuid() {
    final r = Random.secure();
    String hex(int n) => List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}';
  }

  static Future<ScrapeResult> fikfapFeed(Site site, String? after) async {
    final url = Uri.https('api.fikfap.com', '/posts', {'amount': '21', 'afterId': ?after});
    final f = await Net.fetch(
      url,
      headers: {
        HttpHeaders.acceptHeader: 'application/json',
        'Origin': 'https://fikfap.com',
        'Referer': 'https://fikfap.com/',
        'Authorization-Anonymous': _anonymousId,
        'IsLoggedIn': 'false',
        'IsPWA': 'false',
      },
    );
    final posts = jsonDecode(f.text);
    if (posts is! List || posts.isEmpty) throw NetException('The page is empty.');
    final result = ScrapeResult();
    String? lastId;
    for (final p in posts.whereType<Map>()) {
      final v = Uri.tryParse(p['videoStreamUrl'] as String? ?? '');
      if (v == null || !v.hasScheme) continue;
      final thumb = Uri.tryParse(p['thumbnailStreamUrl'] as String? ?? '');
      final id = p['postId']?.toString();
      if (id != null) lastId = id;
      result.items.add(
        MediaItem(
          id: hashKey(v.toString()),
          siteId: site.id,
          siteName: site.name,
          title: p['label'] as String? ?? '',
          thumbnailUrl: thumb != null && thumb.hasScheme ? thumb : null,
          mediaUrl: v,
          pageUrl: Uri.parse('https://fikfap.com/'),
          kind: MediaKind.video,
        ),
      );
    }
    if (result.items.isEmpty) throw NetException('The page is empty.');
    if (lastId != null) result.nextPage = site.url.replace(queryParameters: {'inuttAfter': lastId});
    return result;
  }
}
