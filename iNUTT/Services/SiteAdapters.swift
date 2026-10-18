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
        let (items, lastID) = try await fikfapPosts(path: "/posts", query: [:], after: after, site: site)
        var result = ScrapeResult()
        result.items = items
        if let lastID, var next = URLComponents(url: site.url, resolvingAgainstBaseURL: false) {
            next.queryItems = [URLQueryItem(name: "inuttAfter", value: lastID)]
            result.nextPage = next.url
        }
        return result
    }

    /// The API's address for one hashtag's videos isn't documented, so the known shapes are tried in
    /// turn; only videos that really carry the hashtag count, so a wrong guess never shows other videos.
    private static let fikfapTagRoutes: [(String) -> (path: String, query: [String: String])] = [
        { ("/hashtags/label/\($0)/posts", [:]) },
        { ("/hashtags/\($0)/posts", [:]) },
        { ("/posts/hashtag/\($0)", [:]) },
        { ("/posts", ["hashtag": $0]) },
        { ("/posts", ["hashtags": $0]) },
    ]
    private static var fikfapTagRoute: Int?

    /// Videos with one hashtag. `after` pages on; the second value is the cursor for the next page.
    static func fikfapTagFeed(_ tag: String, site: Site, after: String?) async throws -> ([MediaItem], String?) {
        let key = tag.lowercased()
        let enc = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? tag
        let order = fikfapTagRoute.map { [$0] } ?? Array(fikfapTagRoutes.indices)
        for i in order {
            let route = fikfapTagRoutes[i](enc)
            guard let page = try? await fikfapPosts(path: route.path, query: route.query, after: after, site: site) else { continue }
            let (items, last) = page
            let matching = items.filter { ($0.tags ?? []).contains { $0.lowercased() == key } }
            if matching.isEmpty && after == nil { continue }
            fikfapTagRoute = i
            return (matching, matching.isEmpty ? nil : last)
        }
        throw NetError.empty
    }

    private static func fikfapPosts(path: String, query: [String: String], after: String?, site: Site) async throws -> ([MediaItem], String?) {
        var comps = URLComponents(string: "https://api.fikfap.com")!
        comps.percentEncodedPath = path
        comps.queryItems = [URLQueryItem(name: "amount", value: "21")] + query.map { URLQueryItem(name: $0.key, value: $0.value) }
            + (after.map { [URLQueryItem(name: "afterId", value: $0)] } ?? [])
        guard let url = comps.url else { throw NetError.empty }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://fikfap.com", forHTTPHeaderField: "Origin")
        req.setValue("https://fikfap.com/", forHTTPHeaderField: "Referer")
        req.setValue(anonymousID, forHTTPHeaderField: "Authorization-Anonymous")
        req.setValue("false", forHTTPHeaderField: "IsLoggedIn")
        req.setValue("false", forHTTPHeaderField: "IsPWA")
        let (data, resp) = try await Net.session.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 { throw NetError.badStatus(code) }
        let json = try? JSONSerialization.jsonObject(with: data)
        let posts = (json as? [[String: Any]])
            ?? ((json as? [String: Any]).flatMap { ($0["posts"] ?? $0["data"] ?? $0["items"]) as? [[String: Any]] })
            ?? []
        var items: [MediaItem] = []
        var lastID: String?
        for p in posts {
            guard let s = p["videoStreamUrl"] as? String, let v = URL(string: s) else { continue }
            let thumb = (p["thumbnailStreamUrl"] as? String).flatMap(URL.init(string:))
            let id = (p["postId"] as? Int).map(String.init) ?? (p["postId"] as? String)
            lastID = id ?? lastID
            var item = MediaItem(siteID: site.id, siteName: site.name, title: (p["label"] as? String) ?? "",
                                 thumbnailURL: thumb, mediaURL: v, pageURL: URL(string: "https://fikfap.com/"), kind: .video)
            item.id = MediaItem.hash(v.absoluteString)
            let tags = fikfapTags(p)
            if !tags.isEmpty { item.tags = tags }
            items.append(item)
        }
        if items.isEmpty { throw NetError.empty }
        return (items, lastID)
    }

    /// A post's hashtags, as a list of names or of objects with a label or name.
    static func fikfapTags(_ p: [String: Any]) -> [String] {
        let raw = (p["hashtags"] ?? p["tags"] ?? p["hashTags"]) as? [Any] ?? []
        return raw.compactMap { t -> String? in
            if let s = t as? String { return s }
            if let d = t as? [String: Any] {
                return (d["label"] ?? d["name"] ?? d["tag"] ?? d["hashtag"]) as? String
            }
            return nil
        }
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
        .filter { !$0.isEmpty }
    }

    // MARK: VSCO

    /// A VSCO profile: vsco.co/name or vsco.co/name/gallery.
    static func isVSCO(_ url: URL) -> Bool {
        guard let h = url.host?.lowercased(), h == "vsco.co" || h.hasSuffix(".vsco.co") else { return false }
        return vscoUser(url) != nil
    }

    static func vscoUser(_ url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let first = parts.first, !["api", "search", "feed", "user", "spaces", "discover"].contains(first.lowercased()) else { return nil }
        return first
    }

    /// Token and site id per profile, read once from its page.
    private final class VSCOKeys: @unchecked Sendable {
        let lock = NSLock()
        var byUser: [String: (token: String, siteID: String)] = [:]
    }
    private static let vscoKeys = VSCOKeys()
    /// The token VSCO's own web page uses for visitors.
    private static let vscoPublicToken = "7356455548d0a1d886db010883388d08be84d0c9"

    static func vscoAbsolute(_ raw: String?) -> URL? {
        guard var s = raw, !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s } else if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        return URL(string: s)
    }

    /// The profile's pictures and videos straight from VSCO's API, newest first, 30 per page.
    static func vscoFeed(site: Site, url: URL) async throws -> ScrapeResult {
        guard let user = vscoUser(site.url) ?? vscoUser(url) else { throw NetError.empty }
        let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "inuttCursor" }?.value
        let profile = URL(string: "https://vsco.co/\(user)/gallery")!
        var result = ScrapeResult()
        var keys = vscoKeys.lock.withLock { vscoKeys.byUser[user.lowercased()] }
        var preloaded: [[String: Any]] = []
        if keys == nil {
            let (data, resp) = try await Net.fetch(profile)
            let html = Net.text(data, response: resp)
            guard let state = vscoState(html) else { throw NetError.empty }
            let token = ((state["users"] as? [String: Any])?["currentUser"] as? [String: Any])?["tkn"] as? String ?? vscoPublicToken
            let sites = (state["sites"] as? [String: Any])?["siteByUsername"] as? [String: Any]
            let entry = (sites?[user] ?? sites?.first { $0.key.caseInsensitiveCompare(user) == .orderedSame }?.value) as? [String: Any]
            let siteInfo = entry?["site"] as? [String: Any]
            if let id = siteInfo?["id"] {
                keys = (token, "\(id)")
                vscoKeys.lock.withLock { vscoKeys.byUser[user.lowercased()] = keys }
            }
            result.title = siteInfo?["name"] as? String
            preloaded = ((state["entities"] as? [String: Any])?["images"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        }
        if let keys {
            var comps = URLComponents(string: "https://vsco.co/api/3.0/medias/profile")!
            comps.queryItems = [URLQueryItem(name: "site_id", value: keys.siteID), URLQueryItem(name: "limit", value: "30")]
                + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            var req = URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalCacheData)
            req.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("Bearer " + keys.token, forHTTPHeaderField: "Authorization")
            req.setValue("web", forHTTPHeaderField: "X-Client-Platform")
            req.setValue("1", forHTTPHeaderField: "X-Client-Build")
            req.setValue(profile.absoluteString, forHTTPHeaderField: "Referer")
            if let (data, resp) = try? await Net.session.data(for: req),
               ((resp as? HTTPURLResponse)?.statusCode ?? 500) < 400,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for m in json["media"] as? [[String: Any]] ?? [] {
                    let type = m["type"] as? String ?? "image"
                    guard let body = m[type] as? [String: Any] else { continue }
                    if let item = vscoItem(body, user: user, site: site) { result.items.append(item) }
                }
                if let next = json["next_cursor"] as? String, !next.isEmpty,
                   var n = URLComponents(url: site.url, resolvingAgainstBaseURL: false) {
                    n.queryItems = [URLQueryItem(name: "inuttCursor", value: next)]
                    result.nextPage = n.url
                }
            }
        }
        // The API refused: the first pictures are in the page itself.
        if result.items.isEmpty && cursor == nil {
            let sorted = preloaded.sorted { ($0["uploadDate"] as? Double ?? 0) > ($1["uploadDate"] as? Double ?? 0) }
            result.items = sorted.compactMap { vscoItem($0, user: user, site: site) }
        }
        if result.items.isEmpty { throw NetError.empty }
        return result
    }

    private static func vscoItem(_ m: [String: Any], user: String, site: Site) -> MediaItem? {
        func str(_ keys: String...) -> String? { keys.lazy.compactMap { m[$0] as? String }.first { !$0.isEmpty } }
        let isVideo = (m["is_video"] as? Bool) ?? (m["isVideo"] as? Bool) ?? false
        let image = vscoAbsolute(str("responsive_url", "responsiveUrl"))
        let video = vscoAbsolute(str("video_url", "videoUrl", "playback_url", "playbackUrl"))
        let poster = vscoAbsolute(str("poster_url", "posterUrl")) ?? image
        let media: URL?
        let kind: MediaKind
        if let video, isVideo || image == nil {
            media = video
            kind = .video
        } else if let image {
            media = image
            kind = image.pathExtension.lowercased() == "gif" ? .gif : .image
        } else { return nil }
        guard let media else { return nil }
        var thumb = poster
        if let p = poster, p.host?.contains("im.vsco.co") == true, var c = URLComponents(url: p, resolvingAgainstBaseURL: false) {
            c.queryItems = [URLQueryItem(name: "w", value: "600")]
            thumb = c.url ?? p
        }
        let id = str("_id", "id")
        let page = vscoAbsolute(str("permalink")) ?? id.flatMap { URL(string: "https://vsco.co/\(user)/media/\($0)") }
        var item = MediaItem(siteID: site.id, siteName: site.name, title: str("description", "caption") ?? "",
                             thumbnailURL: thumb, mediaURL: media, pageURL: page, kind: kind)
        item.id = MediaItem.hash(media.absoluteString)
        return item
    }

    /// The JSON VSCO puts in its pages for the app to start from.
    static func vscoState(_ html: String) -> [String: Any]? {
        guard let start = html.range(of: "__PRELOADED_STATE__ = ") else { return nil }
        let rest = html[start.upperBound...]
        let end = rest.range(of: "</script>")?.lowerBound ?? rest.endIndex
        var json = String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        while json.hasSuffix(";") { json.removeLast() }
        json = json.replacingOccurrences(of: "\":undefined", with: "\":null")
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }
}
