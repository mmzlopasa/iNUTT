/// Small, dependency-free helpers for pulling structure out of HTML with regular expressions.
class Html {
  static final Map<String, RegExp> _cache = {};

  static RegExp re(String pattern, {bool dotAll = true}) =>
      _cache.putIfAbsent('$dotAll|$pattern', () => RegExp(pattern, caseSensitive: false, dotAll: dotAll));

  /// All matches; each element holds the capture groups (index 0 = whole match).
  static List<List<String?>> matches(String pattern, String text, {int limit = 1 << 30}) {
    final out = <List<String?>>[];
    for (final m in re(pattern).allMatches(text)) {
      out.add([for (var i = 0; i <= m.groupCount; i++) m.group(i)]);
      if (out.length >= limit) break;
    }
    return out;
  }

  static String? first(String pattern, String text, {int group = 1}) {
    final m = re(pattern).firstMatch(text);
    if (m == null || m.groupCount < group) return null;
    return m.group(group);
  }

  static Map<String, String> attributes(String tag) {
    final attrs = <String, String>{};
    for (final m in matches(r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))''', tag)) {
      final name = m[1]?.toLowerCase();
      if (name == null) continue;
      attrs.putIfAbsent(name, () => decodeEntities(m[2] ?? m[3] ?? m[4] ?? ''));
    }
    return attrs;
  }

  static const _named = {
    '&amp;': '&', '&quot;': '"', '&#39;': "'", '&apos;': "'", '&lt;': '<', '&gt;': '>',
    '&nbsp;': ' ', '&#039;': "'", '&ndash;': '–', '&mdash;': '—', '&hellip;': '…',
    '&rsquo;': '’', '&lsquo;': '‘', '&ldquo;': '“', '&rdquo;': '”',
  };

  static String decodeEntities(String s) {
    if (!s.contains('&')) return s;
    var r = s;
    _named.forEach((k, v) => r = r.replaceAll(k, v));
    if (r.contains('&#')) {
      r = r.replaceAllMapped(re(r'&#(x?)([0-9a-fA-F]+);'), (m) {
        final code = int.tryParse(m[2]!, radix: (m[1] ?? '').isEmpty ? 10 : 16);
        if (code == null || code > 0x10FFFF) return m[0]!;
        return String.fromCharCode(code);
      });
    }
    return r;
  }

  static String collapse(String s) => s.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).join(' ');

  static String stripTags(String s) {
    var t = s.replaceAll(re(r'<(script|style)\b.*?</\1>'), ' ');
    t = t.replaceAll(re(r'<[^>]+>'), ' ');
    return collapse(decodeEntities(t));
  }

  static Uri? resolve(String? raw, Uri base) {
    if (raw == null) return null;
    var s = decodeEntities(raw.trim()).replaceAll(r'\/', '/');
    if (s.isEmpty) return null;
    final lower = s.toLowerCase();
    for (final p in ['data:', 'javascript:', 'mailto:', 'tel:', '#', 'about:', 'blob:']) {
      if (lower.startsWith(p)) return null;
    }
    try {
      final u = base.resolve(s.replaceAll(' ', '%20'));
      if (u.scheme.startsWith('http') && u.host.isNotEmpty) return u;
    } catch (_) {}
    return null;
  }

  /// Picks the best candidate from a srcset, preferring the largest width up to [maxWidth].
  static Uri? bestFromSrcset(String srcset, Uri base, {int maxWidth = 3840}) {
    Uri? best;
    double bestScore = -1;
    Uri? fallback;
    double fallbackScore = double.infinity;
    for (final part in srcset.split(',')) {
      final bits = part.trim().split(RegExp(r'\s+'));
      if (bits.isEmpty) continue;
      final url = resolve(bits.first, base);
      if (url == null) continue;
      var score = 1.0;
      if (bits.length > 1) {
        final d = bits[1].toLowerCase();
        if (d.endsWith('w')) score = double.tryParse(d.substring(0, d.length - 1)) ?? 1;
        if (d.endsWith('x')) score = (double.tryParse(d.substring(0, d.length - 1)) ?? 1) * 1000;
      }
      if (score <= maxWidth) {
        if (score > bestScore) {
          best = url;
          bestScore = score;
        }
      } else if (score < fallbackScore) {
        fallback = url;
        fallbackScore = score;
      }
    }
    return best ?? fallback;
  }

  static String registrableDomain(String? host) {
    if (host == null) return '';
    final parts = host.toLowerCase().split('.');
    if (parts.length <= 2) return parts.join('.');
    const twoLevel = {'co.uk', 'com.au', 'co.jp', 'com.br', 'com.hr', 'co.nz', 'com.tr', 'com.mx'};
    final lastTwo = parts.sublist(parts.length - 2).join('.');
    if (twoLevel.contains(lastTwo)) return parts.sublist(parts.length - 3).join('.');
    return lastTwo;
  }

  static String escape(String s) => RegExp.escape(s);
}
