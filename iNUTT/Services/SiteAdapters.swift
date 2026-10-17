import Foundation
import WebKit

/// Things adult and tube sites need before they show their content: age-gate cookies, the
/// KVS player's scrambled video links, JSON feeds, and pages that only exist as an app API.
enum SiteAdapters {

    // MARK: Age gates

    /// Cookies that common age gates set once you confirm you are 18. Harmless on other sites.
    static let ageCookies: [(String, String)] = [
        ("accessAgeDisclaimerPH", "1"), ("accessAgeDisclaimerUK", "1"), ("accessPH", "1"), ("age_verified", "1"),
        ("ageVerified", "1"), ("age_gate", "1"), ("agecheck", "1"), ("kt_agecheck", "1"), ("over18", "1"),
        ("adult", "1"), ("disclaimer", "1"), ("warning", "1"), ("mature", "1"), ("is_adult", "1"),
        ("ageConfirmed", "true"), ("age_confirmed", "1"), ("confirmed_age", "1"), ("nsfw", "1"), ("verifyAge", "1"),
    ]

    private static var cookiedDomains = Set<String>()
    private static let lock = NSLock()

    static func cookies(for url: URL) -> [HTTPCookie] {
        let domain = HTML.registrableDomain(url.host)
        guard !domain.isEmpty else { return [] }
        return ageCookies.compactMap { name, value in
            HTTPCookie(properties: [.domain: "." + domain, .path: "/", .name: name, .value: value,
                                    .expires: Date().addingTimeInterval(365 * 86400)])
        }
    }

    /// Puts the age cookies into the app's cookie jar for this site, once per launch.
    static func prepare(_ url: URL) {
        let domain = HTML.registrableDomain(url.host)
        lock.lock()
        let fresh = cookiedDomains.insert(domain).inserted
        lock.unlock()
        guard fresh else { return }
        for c in cookies(for: url) where HTTPCookieStorage.shared.cookies(for: url)?.contains(where: { $0.name == c.name }) != true {
            HTTPCookieStorage.shared.setCookie(c)
        }
    }

    /// The same cookies for the off-screen browser.
    @MainActor
    static func prepare(_ url: URL, store: WKHTTPCookieStore) async {
        for c in cookies(for: url) { await store.setCookie(c) }
    }

    /// Clicks "I am 18 / Enter / Agree" on age and consent overlays, once per page.
    static let ageGateScript = #"""
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
    """#

    // MARK: KVS players

    /// Many tube sites run KVS, whose player hides the real file behind `function/0/` and a license code.
    static func kvsRealURL(_ raw: String, license: String?) -> String {
        let prefix = "function/0/"
        guard raw.hasPrefix(prefix) else { return raw }
        let s = String(raw.dropFirst(prefix.count))
        guard let license, var comps = URLComponents(string: s) else { return s }
        let token = kvsToken(license)
        var parts = comps.path.components(separatedBy: "/")
        guard parts.count > 3, parts[3].count >= 32, token.count >= 32 else { return s }
        let hash = Array(parts[3].prefix(32))
        var indices = Array(0..<32)
        var accum = 0
        for src in (0..<32).reversed() {
            accum += token[src]
            let dest = (src + accum) % 32
            indices.swapAt(src, dest)
        }
        parts[3] = String(indices.map { hash[$0] }) + parts[3].dropFirst(32)
        comps.path = parts.joined(separator: "/")
        return comps.string ?? s
    }

    private static func kvsToken(_ license: String) -> [Int] {
        let lic = license.replacingOccurrences(of: "$", with: "")
        let values = lic.compactMap { $0.wholeNumberValue }
        guard values.count == lic.count, values.count >= 4 else { return [] }
        let mod = lic.replacingOccurrences(of: "0", with: "1")
        let center = mod.count / 2
        guard let front = Int(mod.prefix(center + 1)), let back = Int(mod.dropFirst(center)) else { return [] }
        let modlicense = String(String(4 * abs(front - back)).prefix(center + 1))
        var out: [Int] = []
        for (index, ch) in modlicense.enumerated() {
            guard let current = ch.wholeNumberValue else { continue }
            for offset in 0..<4 where index + offset < values.count {
                out.append((values[index + offset] + current) % 10)
            }
        }
        return out
    }

    /// Video files of a KVS player page, with their quality labels.
    static func kvsVideos(in html: String) -> [(String, String?)] {
        let license = HTML.firstMatch(#"license_code\s*:\s*['"]([^'"]+)['"]"#, in: html)
        var out: [(String, String?)] = []
        for m in HTML.matches(#"\b(video_url|video_alt_url\d*)\s*:\s*['"]([^'"]+)['"]"#, in: html, limit: 10) {
            guard let key = m[1], let raw = m[2] else { continue }
            let label = HTML.firstMatch(NSRegularExpression.escapedPattern(for: key) + #"_text\s*:\s*['"]([^'"]+)['"]"#, in: html)
            out.append((kvsRealURL(raw, license: license), label))
        }
        return out
    }

    // MARK: JSON feeds

    /// Any JSON listing: every object holding a video or image file becomes an item.
    static func parseJSONListing(_ data: Data, base: URL, site: Site, categoryName: String?) -> ScrapeResult {
        var result = ScrapeResult()
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return result }
        var seen = Set<String>()

        func str(_ v: Any?) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func url(_ s: String?) -> URL? { HTML.resolve(s, base: base) }

        func visit(_ node: Any, depth: Int) {
            guard depth < 8, result.items.count < 300 else { return }
            if let arr = node as? [Any] {
                for v in arr { visit(v, depth: depth + 1) }
                return
            }
            guard let obj = node as? [String: Any] else { return }
            var video: URL?
            var image: URL?
            var page: URL?
            var title = ""
            for (k, v) in obj {
                let key = k.lowercased()
                if let s = str(v) {
                    let lower = s.lowercased()
                    if video == nil, lower.hasPrefix("http") || lower.hasPrefix("/"),
                       lower.contains(".m3u8") || lower.contains(".mp4") || lower.contains(".webm") || (key.contains("stream") && key.contains("video")) {
                        video = url(s)
                    } else if image == nil, lower.hasPrefix("http") || lower.hasPrefix("/"),
                              key.contains("thumb") || key.contains("poster") || key.contains("cover") || key.contains("preview")
                                || key.contains("image") || lower.range(of: #"\.(jpe?g|png|webp|gif)(\?|$)"#, options: .regularExpression) != nil {
                        image = url(s)
                    } else if page == nil, ["url", "link", "permalink", "href", "page_url", "pageurl"].contains(key), lower.hasPrefix("http") || lower.hasPrefix("/") {
                        page = url(s)
                    } else if title.isEmpty, ["title", "label", "name", "description", "caption"].contains(key) {
                        title = s
                    }
                } else {
                    visit(v, depth: depth + 1)
                }
            }
            guard video != nil || image != nil else { return }
            let media = video ?? image
            let key = media?.absoluteString ?? ""
            guard seen.insert(key).inserted else { return }
            let kind: MediaKind = video != nil ? .video : (MediaKind.guess(from: image) == .gif ? .gif : .image)
            result.items.append(MediaItem(siteID: site.id, siteName: site.name, title: Scraper.cleanTitle(title, duration: nil),
                                          thumbnailURL: image, mediaURL: media, pageURL: video == nil ? page : nil,
                                          kind: kind, categoryName: categoryName))
        }
        visit(root, depth: 0)
        return result
    }

    static func looksLikeJSON(_ data: Data) -> Bool {
        guard let first = data.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }) else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    // MARK: App-only sites

    /// FikFap is an app shell; its feed comes from its public API.
    static func isFikFap(_ url: URL) -> Bool { url.host?.lowercased().hasSuffix("fikfap.com") == true }

    private static let anonymousID = UUID().uuidString.lowercased()

    static func fikfapFeed(site: Site, after: String?) async throws -> ScrapeResult {
        var comps = URLComponents(string: "https://api.fikfap.com/posts")!
        comps.queryItems = [URLQueryItem(name: "amount", value: "21")] + (after.map { [URLQueryItem(name: "afterId", value: $0)] } ?? [])
        var req = URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        req.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://fikfap.com", forHTTPHeaderField: "Origin")
        req.setValue("https://fikfap.com/", forHTTPHeaderField: "Referer")
        req.setValue(anonymousID, forHTTPHeaderField: "Authorization-Anonymous")
        req.setValue("false", forHTTPHeaderField: "IsLoggedIn")
        req.setValue("false", forHTTPHeaderField: "IsPWA")
        let (data, resp) = try await Net.session.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 { throw NetError.badStatus(code) }
        guard let posts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !posts.isEmpty else { throw NetError.empty }
        var result = ScrapeResult()
        var lastID: String?
        for p in posts {
            guard let s = p["videoStreamUrl"] as? String, let v = URL(string: s) else { continue }
            let thumb = (p["thumbnailStreamUrl"] as? String).flatMap(URL.init(string:))
            let id = (p["postId"] as? Int).map(String.init) ?? (p["postId"] as? String)
            lastID = id ?? lastID
            var item = MediaItem(siteID: site.id, siteName: site.name, title: (p["label"] as? String) ?? "",
                                 thumbnailURL: thumb, mediaURL: v, pageURL: URL(string: "https://fikfap.com/"), kind: .video)
            item.id = MediaItem.hash(v.absoluteString)
            result.items.append(item)
        }
        if result.items.isEmpty { throw NetError.empty }
        if let lastID, var next = URLComponents(url: site.url, resolvingAgainstBaseURL: false) {
            next.queryItems = [URLQueryItem(name: "inuttAfter", value: lastID)]
            result.nextPage = next.url
        }
        return result
    }
}
