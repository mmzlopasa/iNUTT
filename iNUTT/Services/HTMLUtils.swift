import Foundation

/// Small, dependency-free helpers for pulling structure out of HTML with regular expressions.
enum HTML {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> NSRegularExpression {
        let key = "\(options.rawValue)|\(pattern)"
        lock.lock(); defer { lock.unlock() }
        if let r = cache[key] { return r }
        // Patterns are compile-time constants; a failure here is a programming error.
        let r = try! NSRegularExpression(pattern: pattern, options: options)
        cache[key] = r
        return r
    }

    /// All matches; each element holds the capture groups (index 0 = whole match).
    static func matches(_ pattern: String, in text: String, limit: Int = .max,
                        options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> [[String?]] {
        let ns = text as NSString
        let re = regex(pattern, options)
        var out: [[String?]] = []
        re.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            guard let m else { return }
            var groups: [String?] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
            }
            out.append(groups)
            if out.count >= limit { stop.pointee = true }
        }
        return out
    }

    static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let m = matches(pattern, in: text, limit: 1).first, m.count > group else { return nil }
        return m[group]
    }

    static func attributes(_ tag: String) -> [String: String] {
        var attrs: [String: String] = [:]
        for m in matches(#"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#, in: tag) {
            guard let name = m[1]?.lowercased() else { continue }
            let value = m[2] ?? m[3] ?? m[4] ?? ""
            if attrs[name] == nil { attrs[name] = decodeEntities(value) }
        }
        return attrs
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var r = s
        let named: [String: String] = [
            "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">",
            "&nbsp;": " ", "&#039;": "'", "&ndash;": "–", "&mdash;": "—", "&hellip;": "…",
            "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”"
        ]
        for (k, v) in named { r = r.replacingOccurrences(of: k, with: v) }
        // numeric entities
        if r.contains("&#") {
            for m in matches(#"&#(x?)([0-9a-fA-F]+);"#, in: r) {
                guard let whole = m[0], let digits = m[2] else { continue }
                let radix = (m[1]?.isEmpty == false) ? 16 : 10
                if let code = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(code) {
                    r = r.replacingOccurrences(of: whole, with: String(Character(scalar)))
                }
            }
        }
        return r
    }

    static func stripTags(_ s: String) -> String {
        var t = regex(#"<(script|style)\b.*?</\1>"#).stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        t = regex(#"<[^>]+>"#).stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: " ")
        t = decodeEntities(t)
        return t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func resolve(_ raw: String?, base: URL) -> URL? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        s = decodeEntities(s).replacingOccurrences(of: "\\/", with: "/")
        let lower = s.lowercased()
        if lower.hasPrefix("data:") || lower.hasPrefix("javascript:") || lower.hasPrefix("mailto:")
            || lower.hasPrefix("tel:") || lower.hasPrefix("#") || lower.hasPrefix("about:") || lower.hasPrefix("blob:") {
            return nil
        }
        if let u = URL(string: s, relativeTo: base)?.absoluteURL, u.scheme?.hasPrefix("http") == true { return u }
        if let enc = s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let u = URL(string: enc, relativeTo: base)?.absoluteURL, u.scheme?.hasPrefix("http") == true { return u }
        return nil
    }

    /// Picks the best candidate from a srcset, preferring the largest width up to `maxWidth`.
    static func bestFromSrcset(_ srcset: String, base: URL, maxWidth: Int = 3840) -> URL? {
        var best: (URL, Double)?
        var fallback: (URL, Double)?
        for part in srcset.components(separatedBy: ",") {
            let bits = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard let first = bits.first, let url = resolve(String(first), base: base) else { continue }
            var score = 1.0
            if bits.count > 1 {
                let d = bits[1].lowercased()
                if d.hasSuffix("w"), let v = Double(d.dropLast()) { score = v }
                else if d.hasSuffix("x"), let v = Double(d.dropLast()) { score = v * 1000 }
            }
            if score <= Double(maxWidth) {
                if best == nil || score > best!.1 { best = (url, score) }
            } else if fallback == nil || score < fallback!.1 {
                fallback = (url, score)
            }
        }
        return best?.0 ?? fallback?.0
    }

    static func registrableDomain(_ host: String?) -> String {
        guard let host else { return "" }
        let parts = host.lowercased().split(separator: ".")
        guard parts.count > 2 else { return parts.joined(separator: ".") }
        let twoLevelTLDs: Set<String> = ["co.uk", "com.au", "co.jp", "com.br", "com.hr", "co.nz", "com.tr", "com.mx"]
        let lastTwo = parts.suffix(2).joined(separator: ".")
        if twoLevelTLDs.contains(lastTwo) { return parts.suffix(3).joined(separator: ".") }
        return lastTwo
    }
}
