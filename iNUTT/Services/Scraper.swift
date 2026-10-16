import Foundation

struct ScrapeResult {
    var title: String?
    var iconURL: URL?
    var items: [MediaItem] = []
    var categories: [SiteCategory] = []
    var nextPage: URL?
}

/// Turns arbitrary pages (HTML, RSS/Atom, Reddit JSON) into media items and categories.
enum Scraper {

    // MARK: - Listing pages

    static func parseListing(html: String, baseURL: URL, site: Site, categoryName: String?) -> ScrapeResult {
        var result = ScrapeResult()
        result.title = HTML.firstMatch(#"<meta[^>]+property=["']og:site_name["'][^>]+content=["']([^"']+)"#, in: html)
            ?? HTML.firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html).map(HTML.stripTags)
        result.iconURL = iconURL(html: html, base: baseURL)

        let siteDomain = HTML.registrableDomain(site.url.host)
        var seen = Set<String>()
        var items: [MediaItem] = []
        var cardCategories: [SiteCategory] = []
        var seenCategories = Set<String>()

        func add(_ item: MediaItem) {
            let key = (item.pageURL ?? item.mediaURL ?? item.thumbnailURL)?.absoluteString ?? item.id
            guard !seen.contains(key) else { return }
            if let t = item.thumbnailURL?.absoluteString, seen.contains("thumb:" + t) { return }
            seen.insert(key)
            if let t = item.thumbnailURL?.absoluteString { seen.insert("thumb:" + t) }
            items.append(item)
        }

        // 1) Anchors that wrap a thumbnail ("cards").
        for m in HTML.matches(#"<a\b([^>]*)>(.*?)</a>"#, in: html) {
            guard let attrText = m[1], let inner = m[2] else { continue }
            let attrs = HTML.attributes(attrText)
            guard let href = HTML.resolve(attrs["href"], base: baseURL) else { continue }
            let hrefKind = MediaKind.guess(from: href)

            var thumb: URL?
            var alt: String?
            if let imgTag = HTML.firstMatch(#"(<img\b[^>]*>)"#, in: inner) {
                let ia = HTML.attributes(imgTag)
                thumb = bestImage(ia, base: baseURL, preferSmall: true)
                alt = ia["alt"] ?? ia["title"]
            }
            if thumb == nil, let src = HTML.firstMatch(#"<source\b[^>]*(?:data-)?srcset=["']([^"']+)"#, in: inner) {
                thumb = HTML.bestFromSrcset(src, base: baseURL, maxWidth: 800)
            }
            if thumb == nil {
                let bgPattern = #"background(?:-image)?\s*:\s*url\(\s*['"]?([^'")]+)"#
                if let bg = HTML.firstMatch(bgPattern, in: inner) ?? HTML.firstMatch(bgPattern, in: attrText) {
                    thumb = HTML.resolve(bg, base: baseURL)
                }
            }
            if thumb == nil {
                for key in ["data-thumb", "data-poster", "data-image", "data-src"] {
                    if let v = attrs[key], let u = HTML.resolve(v, base: baseURL) { thumb = u; break }
                }
            }
            if thumb == nil, let poster = HTML.firstMatch(#"<video\b[^>]*poster=["']([^"']+)"#, in: inner) {
                thumb = HTML.resolve(poster, base: baseURL)
            }

            if thumb == nil && hrefKind == nil { continue }
            if let t = thumb, isJunkImage(t) { continue }

            // Skip ads / outbound links that are not media.
            if hrefKind == nil, HTML.registrableDomain(href.host) != siteDomain, !isKnownMediaHost(href.host) { continue }
            // Skip links that just point at the listing again.
            if hrefKind == nil, href.path == baseURL.path, href.query == baseURL.query { continue }

            let text = HTML.stripTags(inner)
            let duration = HTML.firstMatch(#"(?<![\d:])((?:\d{1,2}:)?\d{1,2}:\d{2})(?![\d:])"#, in: text)
            // Tiles like "Amateur · 1,234 videos" are categories even when the URL does not say so.
            let countHint = duration == nil && HTML.firstMatch(countHintPattern, in: text, group: 0) != nil
            // Category tiles (a thumbnail linking to a category page) become categories, not media.
            if hrefKind == nil, HTML.registrableDomain(href.host) == siteDomain, isCategoryURL(href) || countHint {
                var name = cleanTitle(attrs["title"] ?? (text.isEmpty ? (alt ?? "") : text), duration: nil)
                name = HTML.regex(countHintPattern).stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "")
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
                if name.isEmpty { name = cleanTitle(alt ?? href.lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized, duration: nil) }
                let key = href.absoluteString.lowercased()
                if !name.isEmpty, name.count <= 60, seenCategories.insert(key).inserted {
                    cardCategories.append(SiteCategory(name: name, url: href, thumbnailURL: thumb))
                }
                continue
            }
            let title = cleanTitle(attrs["title"] ?? alt ?? text, duration: duration)
            let lowerInner = inner.lowercased() + " " + attrText.lowercased()
            let videoHint = duration != nil
                || lowerInner.contains("data-preview") || lowerInner.contains("data-mp4") || lowerInner.contains("data-webm")
                || lowerInner.contains("<video") || lowerInner.contains("play-icon") || lowerInner.contains("duration")
                || isVideoPath(href.path)

            var kind: MediaKind = .image
            if let hk = hrefKind { kind = hk }
            else if MediaKind.guess(from: thumb) == .gif { kind = .gif }
            else if videoHint { kind = .video }

            add(MediaItem(siteID: site.id, siteName: site.name, title: title,
                          thumbnailURL: thumb ?? (hrefKind == .image ? href : nil),
                          mediaURL: hrefKind != nil ? href : nil,
                          pageURL: hrefKind == nil ? href : nil,
                          kind: kind, duration: duration, categoryName: categoryName))
        }

        // 2) Inline videos on the page itself.
        for m in HTML.matches(#"<video\b([^>]*)>(.*?)</video>"#, in: html) {
            let va = HTML.attributes(m[1] ?? "")
            var src = HTML.resolve(va["src"] ?? va["data-src"], base: baseURL)
            if src == nil, let s = HTML.firstMatch(#"<source\b[^>]*src=["']([^"']+)"#, in: m[2] ?? "") {
                src = HTML.resolve(s, base: baseURL)
            }
            guard let url = src else { continue }
            add(MediaItem(siteID: site.id, siteName: site.name, title: va["title"] ?? "",
                          thumbnailURL: HTML.resolve(va["poster"], base: baseURL), mediaURL: url, pageURL: nil,
                          kind: .video, categoryName: categoryName))
        }

        // 3) Gallery pages: standalone large images.
        if items.count < 8 {
            for tag in HTML.matches(#"(<img\b[^>]*>)"#, in: html).compactMap({ $0[1] }) {
                let ia = HTML.attributes(tag)
                guard let full = bestImage(ia, base: baseURL, preferSmall: false), !isJunkImage(full) else { continue }
                if let w = Int(ia["width"] ?? ""), w < 200 { continue }
                if let h = Int(ia["height"] ?? ""), h < 150 { continue }
                let thumb = bestImage(ia, base: baseURL, preferSmall: true) ?? full
                add(MediaItem(siteID: site.id, siteName: site.name, title: ia["alt"] ?? ia["title"] ?? "",
                              thumbnailURL: thumb, mediaURL: full, pageURL: nil,
                              kind: MediaKind.guess(from: full) == .gif ? .gif : .image, categoryName: categoryName))
            }
        }

        // 4) Raw media URLs embedded in scripts / JSON.
        if items.count < 3 {
            for url in rawMediaURLs(in: html, base: baseURL).prefix(60) {
                let k = MediaKind.guess(from: url) ?? .video
                add(MediaItem(siteID: site.id, siteName: site.name, title: "",
                              thumbnailURL: k == .video ? nil : url, mediaURL: url, pageURL: nil,
                              kind: k, categoryName: categoryName))
            }
        }

        result.items = items
        let textCategories = categories(html: html, base: baseURL, siteDomain: siteDomain)
            .filter { !seenCategories.contains($0.url.absoluteString.lowercased()) }
        result.categories = cardCategories + textCategories
        result.nextPage = nextPage(html: html, current: baseURL)
        return result
    }

    // MARK: - Detail pages

    static func resolveDetail(html: String, pageURL: URL, maxHeight: Int) -> ResolvedMedia? {
        // Videos, best first.
        var videos: [(URL, Int)] = []
        func addVideo(_ raw: String?, label: String? = nil) {
            guard let u = HTML.resolve(raw, base: pageURL) else { return }
            let ext = u.pathExtension.lowercased()
            guard ["mp4", "m4v", "mov", "m3u8", "webm"].contains(ext) || u.absoluteString.contains(".m3u8") || u.absoluteString.contains(".mp4") else { return }
            if videos.contains(where: { $0.0 == u }) { return }
            videos.append((u, quality(of: u, label: label)))
        }

        for m in HTML.matches(#"<video\b([^>]*)>(.*?)</video>"#, in: html) {
            let va = HTML.attributes(m[1] ?? "")
            addVideo(va["src"] ?? va["data-src"])
            for s in HTML.matches(#"(<source\b[^>]*>)"#, in: m[2] ?? "") {
                let sa = HTML.attributes(s[1] ?? "")
                addVideo(sa["src"] ?? sa["data-src"], label: sa["size"] ?? sa["label"] ?? sa["res"] ?? sa["data-quality"] ?? sa["title"])
            }
        }
        for key in ["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream"] {
            addVideo(meta(key, in: html))
        }
        // JSON-ish keys commonly used by players.
        let jsonKeys = #"["'](?:contentUrl|file|src|videoUrl|video_url|mp4|hls|hlsUrl|url|source|stream_url|videoSrc)["']\s*:\s*["']([^"']+\.(?:mp4|m3u8|webm|mov)[^"']*)["']"#
        for m in HTML.matches(jsonKeys, in: html, limit: 40) { addVideo(m[1]) }
        for m in HTML.matches(#"<source\b([^>]*)>"#, in: html, limit: 20) {
            let sa = HTML.attributes(m[1] ?? "")
            addVideo(sa["src"], label: sa["size"] ?? sa["label"] ?? sa["res"])
        }
        if videos.isEmpty {
            for u in rawMediaURLs(in: html, base: pageURL) where MediaKind.guess(from: u) == .video { addVideo(u.absoluteString) }
        }

        let poster = HTML.resolve(meta("og:image", in: html), base: pageURL)

        if !videos.isEmpty {
            let mp4s = videos.filter { !$0.0.absoluteString.contains(".m3u8") }
            let hls = videos.filter { $0.0.absoluteString.contains(".m3u8") }
            func pick(_ list: [(URL, Int)]) -> URL? {
                let within = list.filter { $0.1 <= maxHeight }
                return (within.max { $0.1 < $1.1 } ?? list.min { $0.1 < $1.1 })?.0
            }
            // Adaptive HLS already goes up to 4K, so prefer it unless a high quality MP4 exists.
            let best: URL?
            if let m = pick(mp4s), let q = mp4s.first(where: { $0.0 == m })?.1, q >= 720 || hls.isEmpty {
                best = m
            } else {
                best = hls.first?.0 ?? pick(mp4s)
            }
            if let best { return ResolvedMedia(url: best, kind: .video, gallery: poster.map { [$0] } ?? [], referer: pageURL) }
        }

        // Imgur-style .gifv -> mp4
        if let gifv = HTML.firstMatch(#"(https?://[^"'\s>]+\.gifv)"#, in: html), let u = URL(string: gifv.replacingOccurrences(of: ".gifv", with: ".mp4")) {
            return ResolvedMedia(url: u, kind: .video, referer: pageURL)
        }

        // Images (gallery-aware).
        var images: [URL] = []
        for tag in HTML.matches(#"(<img\b[^>]*>)"#, in: html).compactMap({ $0[1] }) {
            let ia = HTML.attributes(tag)
            guard let u = bestImage(ia, base: pageURL, preferSmall: false), !isJunkImage(u) else { continue }
            if let w = Int(ia["width"] ?? ""), w < 300 { continue }
            if let h = Int(ia["height"] ?? ""), h < 200 { continue }
            // If the image is wrapped in a link to a bigger file, prefer that.
            if !images.contains(u) { images.append(u) }
        }
        for m in HTML.matches(#"<a\b[^>]*href=["']([^"']+\.(?:jpe?g|png|webp|gif)(?:\?[^"']*)?)["']"#, in: html, limit: 200) {
            if let u = HTML.resolve(m[1], base: pageURL), !isJunkImage(u), !images.contains(u) { images.append(u) }
        }
        if let og = poster, !images.contains(og) { images.insert(og, at: 0) }
        // Drop obvious thumbnails when larger versions exist.
        let large = images.filter { !$0.absoluteString.lowercased().contains("thumb") }
        let pool = large.isEmpty ? images : large
        guard let first = pool.first else { return nil }
        let kind: MediaKind = MediaKind.guess(from: first) == .gif ? .gif : .image
        return ResolvedMedia(url: first, kind: kind, gallery: pool.count > 1 ? Array(pool.prefix(100)) : [], referer: pageURL)
    }

    // MARK: - RSS / Atom

    static func looksLikeFeed(_ text: String) -> Bool {
        let head = text.prefix(600).lowercased()
        return head.contains("<rss") || head.contains("<feed") || head.contains("<rdf:rdf")
    }

    static func parseFeed(xml: String, baseURL: URL, site: Site, categoryName: String?) -> ScrapeResult {
        var result = ScrapeResult()
        result.title = HTML.firstMatch(#"<title[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>"#, in: xml).map(HTML.stripTags)
        for m in HTML.matches(#"<(item|entry)\b.*?>(.*?)</\1>"#, in: xml, limit: 300) {
            guard let body = m[2] else { continue }
            let title = HTML.firstMatch(#"<title[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>"#, in: body).map(HTML.stripTags) ?? ""
            let link = HTML.firstMatch(#"<link[^>]*>([^<]+)</link>"#, in: body) ?? HTML.firstMatch(#"<link[^>]*href=["']([^"']+)"#, in: body)
            let pageURL = HTML.resolve(link, base: baseURL)
            var media: URL?
            var mediaType: String?
            if let enc = HTML.firstMatch(#"(<(?:enclosure|media:content)\b[^>]*>)"#, in: body) {
                let a = HTML.attributes(enc)
                media = HTML.resolve(a["url"], base: baseURL)
                mediaType = a["type"] ?? a["medium"]
            }
            var thumb = HTML.resolve(HTML.firstMatch(#"<media:thumbnail\b[^>]*url=["']([^"']+)"#, in: body), base: baseURL)
            let decoded = HTML.decodeEntities(body)
            if thumb == nil, let img = HTML.firstMatch(#"<img\b[^>]*src=["']([^"']+)"#, in: decoded) {
                thumb = HTML.resolve(img, base: baseURL)
            }
            var kind = MediaKind.guess(from: media) ?? .image
            if let t = mediaType?.lowercased() {
                if t.contains("video") { kind = .video } else if t.contains("gif") { kind = .gif }
            }
            if media == nil && thumb == nil { continue }
            if thumb == nil, kind != .video { thumb = media }
            result.items.append(MediaItem(siteID: site.id, siteName: site.name, title: title, thumbnailURL: thumb,
                                          mediaURL: media, pageURL: media == nil ? pageURL : pageURL,
                                          kind: kind, categoryName: categoryName))
        }
        return result
    }

    // MARK: - Reddit

    static func isReddit(_ url: URL) -> Bool { url.host?.lowercased().contains("reddit.com") == true }

    static func redditJSONURL(for url: URL, after: String? = nil, search: String? = nil, host: String = "www.reddit.com") -> URL? {
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".json") { path.removeLast(5) }
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        // Keep options such as ?t=week from the original link.
        let kept = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { !["raw_json", "limit", "after", "q", "restrict_sr"].contains($0.name) }
        var query = [URLQueryItem(name: "raw_json", value: "1"), URLQueryItem(name: "limit", value: "100")] + kept
        if let search {
            comps.path = path + "/search.json"
            query += [URLQueryItem(name: "q", value: search), URLQueryItem(name: "restrict_sr", value: path.isEmpty ? "0" : "1")]
        } else {
            comps.path = (path.isEmpty ? "/" : path) + ".json"
        }
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        comps.queryItems = query
        return comps.url
    }

    /// Sort orders shown as categories for a subreddit or user.
    static func redditCategories(for url: URL) -> [SiteCategory] {
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        // Strip a sort the link may already include.
        for sort in ["/hot", "/new", "/top", "/rising", "/controversial"] where path.hasSuffix(sort) { path.removeLast(sort.count) }
        let base = "https://www.reddit.com" + path
        let sorts: [(String, String)] = [("Hot", "/hot/"), ("New", "/new/"), ("Top today", "/top/?t=day"), ("Top this week", "/top/?t=week"),
                                         ("Top this month", "/top/?t=month"), ("Top this year", "/top/?t=year"), ("Top of all time", "/top/?t=all")]
        return sorts.compactMap { name, suffix in URL(string: base + suffix).map { SiteCategory(name: name, url: $0) } }
    }

    /// The playable media of one Reddit post.
    struct RedditMedia {
        var media: URL?
        var kind: MediaKind
        var thumb: URL?
        var gallery: [URL] = []
    }

    static func redditMedia(_ post: [String: Any]) -> RedditMedia? {
        // Crossposts carry their media on the original post.
        var p = post
        if p["media"] == nil || p["media"] is NSNull, p["is_gallery"] as? Bool != true,
           let parent = (p["crosspost_parent_list"] as? [[String: Any]])?.first {
            p = parent
        }
        var thumb: URL?
        if let preview = p["preview"] as? [String: Any], let imgs = preview["images"] as? [[String: Any]], let first = imgs.first {
            if let res = first["resolutions"] as? [[String: Any]], let mid = res.last(where: { ($0["width"] as? Int ?? 0) <= 640 }) ?? res.last {
                thumb = (mid["url"] as? String).flatMap(URL.init(string:))
            }
            if thumb == nil, let src = first["source"] as? [String: Any] { thumb = (src["url"] as? String).flatMap(URL.init(string:)) }
        }
        if thumb == nil, let t = p["thumbnail"] as? String, t.hasPrefix("http") { thumb = URL(string: t) }

        let urlStr = p["url_overridden_by_dest"] as? String ?? p["url"] as? String
        let link = urlStr.flatMap(URL.init(string:))
        var out = RedditMedia(media: link, kind: MediaKind.guess(from: link) ?? .image, thumb: thumb)

        let secure = p["secure_media"] as? [String: Any] ?? p["media"] as? [String: Any]
        if let rv = (p["media"] as? [String: Any])?["reddit_video"] as? [String: Any] ?? secure?["reddit_video"] as? [String: Any] {
            out.media = (rv["hls_url"] as? String ?? rv["fallback_url"] as? String).flatMap(URL.init(string:))
            out.kind = .video
        } else if let preview = p["preview"] as? [String: Any], let rv = preview["reddit_video_preview"] as? [String: Any] {
            out.media = (rv["hls_url"] as? String ?? rv["fallback_url"] as? String).flatMap(URL.init(string:))
            out.kind = .video
        } else if let m = link, m.pathExtension.lowercased() == "gifv" {
            out.media = URL(string: m.absoluteString.replacingOccurrences(of: ".gifv", with: ".mp4"))
            out.kind = .video
        } else if p["is_gallery"] as? Bool == true, let meta = p["media_metadata"] as? [String: Any] {
            let order = ((p["gallery_data"] as? [String: Any])?["items"] as? [[String: Any]])?.compactMap { $0["media_id"] as? String } ?? Array(meta.keys)
            var anyGif = false
            for id in order {
                guard let m = meta[id] as? [String: Any], let s = m["s"] as? [String: Any] else { continue }
                if let u = (s["u"] as? String ?? s["gif"] as? String).flatMap(URL.init(string:)) {
                    out.gallery.append(u)
                    if s["gif"] != nil { anyGif = true }
                }
                if out.thumb == nil, let small = (m["p"] as? [[String: Any]])?.last(where: { ($0["x"] as? Int ?? 0) <= 640 }),
                   let u = (small["u"] as? String).flatMap(URL.init(string:)) { out.thumb = u }
            }
            guard !out.gallery.isEmpty else { return nil }
            out.media = out.gallery[0]
            out.kind = anyGif && out.gallery.count == 1 ? .gif : .image
        } else if let hint = p["post_hint"] as? String, hint == "image", let m = link {
            out.media = m
            out.kind = MediaKind.guess(from: m) ?? .image
        } else if MediaKind.guess(from: link) == nil {
            // Links to other hosts (Redgifs, Imgur pages…): resolved when opened.
            guard out.thumb != nil else { return nil }
            out.media = nil
            let host = link?.host?.lowercased() ?? ""
            if p["post_hint"] as? String == "rich:video" || host.contains("redgifs") || host.contains("gfycat") || host.contains("streamable") || host.contains("youtu") {
                out.kind = .video
            }
        }
        if out.media == nil && out.thumb == nil { return nil }
        return out
    }

    static func parseReddit(data: Data, listingURL: URL, site: Site, categoryName: String?) -> ScrapeResult {
        var result = ScrapeResult()
        let json = try? JSONSerialization.jsonObject(with: data)
        // A post page returns [post listing, comments]; a subreddit returns one listing.
        let listing = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
        guard let d = listing?["data"] as? [String: Any],
              let children = d["children"] as? [[String: Any]] else { return result }
        for child in children {
            guard child["kind"] as? String != "t1", let p = child["data"] as? [String: Any],
                  let rm = redditMedia(p) else { continue }
            let title = HTML.decodeEntities(p["title"] as? String ?? "")
            let permalink = (p["permalink"] as? String).flatMap { URL(string: "https://www.reddit.com" + $0) }
            var item = MediaItem(siteID: site.id, siteName: site.name, title: title,
                                 thumbnailURL: rm.thumb ?? (rm.kind == .video ? nil : rm.media),
                                 mediaURL: rm.media, pageURL: rm.media == nil ? permalink : nil,
                                 kind: rm.kind, categoryName: categoryName ?? (p["subreddit_name_prefixed"] as? String))
            if rm.gallery.count > 1 { item.gallery = rm.gallery }
            if rm.media == nil, let link = (p["url_overridden_by_dest"] as? String).flatMap(URL.init(string:)) {
                // Open the external page directly; it holds the actual media.
                item.pageURL = link
            }
            item.id = MediaItem.hash(permalink?.absoluteString ?? item.id)
            result.items.append(item)
        }
        if let after = d["after"] as? String {
            result.nextPage = redditJSONURL(for: listingURL, after: after)
        }
        if Scraper.isRedditListing(listingURL) {
            result.categories = redditCategories(for: listingURL)
            let parts = listingURL.path.split(separator: "/")
            result.title = parts.prefix(2).joined(separator: "/")
        } else {
            result.title = "Reddit"
        }
        result.iconURL = URL(string: "https://www.redditstatic.com/shreddit/assets/favicon/192x192.png")
        return result
    }

    /// A subreddit or user page (has sort orders), not the front page or a single post.
    static func isRedditListing(_ url: URL) -> Bool {
        let parts = url.path.split(separator: "/").map { $0.lowercased() }
        guard parts.count >= 2, ["r", "u", "user"].contains(parts[0]) else { return false }
        return !parts.contains("comments")
    }

    // MARK: - Helpers

    static func meta(_ property: String, in html: String) -> String? {
        let p = NSRegularExpression.escapedPattern(for: property)
        return HTML.firstMatch(#"<meta[^>]+(?:property|name)=["']"# + p + #"["'][^>]*content=["']([^"']+)"#, in: html)
            ?? HTML.firstMatch(#"<meta[^>]+content=["']([^"']+)["'][^>]*(?:property|name)=["']"# + p + #"["']"#, in: html)
    }

    static func iconURL(html: String, base: URL) -> URL? {
        for rel in ["apple-touch-icon", "icon", "shortcut icon"] {
            let p = NSRegularExpression.escapedPattern(for: rel)
            if let h = HTML.firstMatch(#"<link[^>]+rel=["']"# + p + #"["'][^>]*href=["']([^"']+)"#, in: html)
                ?? HTML.firstMatch(#"<link[^>]+href=["']([^"']+)["'][^>]*rel=["']"# + p + #"["']"#, in: html) {
                return HTML.resolve(h, base: base)
            }
        }
        return URL(string: "/favicon.ico", relativeTo: base)?.absoluteURL
    }

    static func bestImage(_ a: [String: String], base: URL, preferSmall: Bool) -> URL? {
        let srcset = a["data-srcset"] ?? a["srcset"] ?? a["data-lazy-srcset"]
        if let s = srcset, let u = HTML.bestFromSrcset(s, base: base, maxWidth: preferSmall ? 800 : 3840) { return u }
        let order = preferSmall
            ? ["data-src", "data-original", "data-lazy-src", "data-lazy", "data-thumb", "data-url", "src", "data-full", "data-large"]
            : ["data-full", "data-large", "data-zoom-image", "data-hi-res", "data-original", "data-src", "data-lazy-src", "data-lazy", "src"]
        for key in order {
            if let v = a[key], let u = HTML.resolve(v, base: base), !isPlaceholder(u) { return u }
        }
        return nil
    }

    static func isPlaceholder(_ u: URL) -> Bool {
        let s = u.absoluteString.lowercased()
        return s.contains("blank.") || s.contains("placeholder") || s.contains("spacer") || s.contains("1x1")
            || s.contains("transparent.") || s.contains("lazy.") || s.contains("loading.") || s.hasSuffix(".svg")
    }

    static func isJunkImage(_ u: URL) -> Bool {
        if isPlaceholder(u) { return true }
        let s = u.lastPathComponent.lowercased()
        let path = u.path.lowercased()
        for w in ["logo", "favicon", "icon", "avatar", "sprite", "banner", "emoji", "badge", "flag", "/ads/", "pixel", "tracking", "button"] {
            if s.contains(w) || (w.hasPrefix("/") && path.contains(w)) { return true }
        }
        return false
    }

    static func isVideoPath(_ p: String) -> Bool {
        let l = p.lowercased()
        return ["/video", "/videos/", "/watch", "/v/", "/embed/", "/movie", "/clip", "/vod/", "/play/"].contains { l.contains($0) }
    }

    static func isKnownMediaHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return ["imgur.com", "redd.it", "redgifs.com", "gfycat.com", "giphy.com", "tenor.com", "vimeo.com", "streamable.com"].contains { h.hasSuffix($0) }
    }

    static func cleanTitle(_ raw: String, duration: String?) -> String {
        var t = HTML.decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = duration { t = t.replacingOccurrences(of: d, with: "") }
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if t.count > 140 { t = String(t.prefix(140)) + "…" }
        return t
    }

    static func quality(of url: URL, label: String?) -> Int {
        let hay = (label ?? "") + " " + url.absoluteString
        if hay.lowercased().contains("4k") || hay.contains("2160") { return 2160 }
        if hay.contains("1440") { return 1440 }
        if let q = HTML.firstMatch(#"(?<!\d)(2160|1440|1080|720|540|480|360|240)(?:p|_|\b)"#, in: hay), let v = Int(q) { return v }
        if let l = label, let v = Int(l.filter(\.isNumber)), v >= 144, v <= 4320 { return v }
        return 480
    }

    static func rawMediaURLs(in html: String, base: URL) -> [URL] {
        let unescaped = html.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\u002F", with: "/")
        var out: [URL] = []
        for m in HTML.matches(#"(https?://[^"'\s<>()\\]+?\.(?:mp4|m3u8|webm|gif|jpe?g|png|webp)(?:\?[^"'\s<>\\]*)?)(?=["'\s<>\\)])"#, in: unescaped, limit: 400) {
            guard let u = HTML.resolve(m[1], base: base), !isJunkImage(u), !out.contains(u) else { continue }
            out.append(u)
        }
        return out
    }

    static let categoryPathPattern = #"/(categor(?:y|ies)|cats?|tags?|channels?|genres?|collections?|topics?|sections?|niches?|albums?|boards?|playlists?|c|r)/[^/?#]+/?$"#

    /// "1,234 videos", "56 photos", "12.5K clips" on a tile marks it as a category or album.
    static let countHintPattern = #"\b\d[\d.,]*\s*[km]?\+?\s*(?:videos?|clips?|movies?|galleries|gallery|pics|pictures|photos|images|gifs|items|posts|albums?)\b"#

    static func isCategoryURL(_ u: URL) -> Bool {
        let p = u.path as NSString
        return HTML.regex(categoryPathPattern, [.caseInsensitive]).firstMatch(in: u.path, range: NSRange(location: 0, length: p.length)) != nil
    }

    static func categories(html: String, base: URL, siteDomain: String) -> [SiteCategory] {
        var out: [SiteCategory] = []
        var seen = Set<String>()

        func consider(_ href: String?, _ inner: String, strict: Bool) {
            guard let u = HTML.resolve(href, base: base), HTML.registrableDomain(u.host) == siteDomain else { return }
            if u.absoluteString == base.absoluteString { return }
            let name = HTML.stripTags(inner)
            guard name.count >= 2, name.count <= 40, name.rangeOfCharacter(from: .letters) != nil else { return }
            if strict { guard isCategoryURL(u) else { return } }
            let key = u.absoluteString.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            out.append(SiteCategory(name: name, url: u))
        }

        for m in HTML.matches(#"<a\b([^>]*)>(.*?)</a>"#, in: html, limit: 4000) {
            let a = HTML.attributes(m[1] ?? "")
            consider(a["href"], m[2] ?? "", strict: true)
            if out.count >= 120 { break }
        }
        if out.count < 3 {
            for nav in HTML.matches(#"<nav\b[^>]*>(.*?)</nav>"#, in: html, limit: 5) {
                for m in HTML.matches(#"<a\b([^>]*)>(.*?)</a>"#, in: nav[1] ?? "") {
                    let a = HTML.attributes(m[1] ?? "")
                    consider(a["href"], m[2] ?? "", strict: false)
                }
            }
        }
        return out
    }

    static func nextPage(html: String, current: URL) -> URL? {
        if let h = HTML.firstMatch(#"<link[^>]+rel=["']next["'][^>]*href=["']([^"']+)"#, in: html)
            ?? HTML.firstMatch(#"<a\b[^>]*rel=["']next["'][^>]*href=["']([^"']+)"#, in: html)
            ?? HTML.firstMatch(#"<a\b[^>]*href=["']([^"']+)["'][^>]*rel=["']next["']"#, in: html),
           let u = HTML.resolve(h, base: current), u != current { return u }
        for m in HTML.matches(#"<a\b([^>]*)>(.*?)</a>"#, in: html) {
            let a = HTML.attributes(m[1] ?? "")
            let text = HTML.stripTags(m[2] ?? "").lowercased()
            let cls = (a["class"] ?? "") + " " + (a["aria-label"] ?? "")
            let isNext = ["next", "next page", "›", "»", "sljedeća", "sljedeca", "older", "older posts", "next »", "›› ", ">"].contains(text)
                || cls.lowercased().contains("next")
            if isNext, let u = HTML.resolve(a["href"], base: current), u != current { return u }
        }
        // Guess from the current URL's page number.
        let s = current.absoluteString
        if let n = HTML.firstMatch(#"[?&]page=(\d+)"#, in: s), let v = Int(n) {
            return URL(string: s.replacingOccurrences(of: "page=\(v)", with: "page=\(v + 1)"))
        }
        if let n = HTML.firstMatch(#"/page/(\d+)"#, in: s), let v = Int(n) {
            return URL(string: s.replacingOccurrences(of: "/page/\(v)", with: "/page/\(v + 1)"))
        }
        return nil
    }
}
