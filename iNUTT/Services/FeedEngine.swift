import Foundation
import BackgroundTasks

/// Loads, caches and refreshes content from every site. Cached feeds are shown instantly on launch.
@MainActor
final class FeedEngine: ObservableObject {
    static let shared = FeedEngine()
    static let refreshTaskID = "dev.scyde.inutt.refresh"

    @Published private(set) var feeds: [String: [MediaItem]] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var isRefreshingAll = false
    @Published private(set) var lastRefresh: Date?

    private var nextPages: [String: URL] = [:]
    private var resolvedCache: [String: ResolvedMedia] = [:]
    /// Per feed: whether its thumbnail tiles turned out to be categories (checked once per launch).
    private var listingProbe: [String: Bool] = [:]
    private var saveWork: DispatchWorkItem?

    private struct Snapshot: Codable {
        var feeds: [String: [MediaItem]]
        var nextPages: [String: URL]
        var lastRefresh: Date?
    }

    private init() {
        if let snap = Disk.load(Snapshot.self, "feeds.json") {
            feeds = snap.feeds
            nextPages = snap.nextPages
            lastRefresh = snap.lastRefresh
        }
    }

    static func key(_ site: Site, _ category: SiteCategory? = nil) -> String {
        if let category { return site.id.uuidString + "|" + category.url.absoluteString }
        return site.id.uuidString
    }

    func items(_ site: Site, _ category: SiteCategory? = nil) -> [MediaItem] { feeds[Self.key(site, category)] ?? [] }
    func hasMore(_ site: Site, _ category: SiteCategory? = nil) -> Bool { nextPages[Self.key(site, category)] != nil }

    /// All cached items across enabled sites, interleaved so no site dominates.
    func mixedFeed(_ sites: [Site]) -> [MediaItem] {
        let lists = sites.map { feeds[Self.key($0)] ?? [] }
        var out: [MediaItem] = []
        var seen = Set<String>()
        let maxLen = lists.map(\.count).max() ?? 0
        for i in 0..<maxLen {
            for l in lists where i < l.count {
                if l[i].isListing != true, seen.insert(l[i].id).inserted { out.append(l[i]) }
            }
        }
        return out
    }

    func allCachedItems() -> [MediaItem] {
        var seen = Set<String>()
        return feeds.values.flatMap { $0 }.filter { seen.insert($0.id).inserted }
    }

    // MARK: Refresh

    var isStale: Bool {
        guard let lastRefresh else { return true }
        return Date().timeIntervalSince(lastRefresh) > 8 * 60
    }

    func refreshAll(allowRender: Bool = true) async {
        guard !isRefreshingAll else { return }
        let sites = SiteStore.shared.enabledSites
        guard !sites.isEmpty else { return }
        isRefreshingAll = true
        defer { isRefreshingAll = false }

        await withTaskGroup(of: Void.self) { group in
            var it = sites.makeIterator()
            var running = 0
            while running < 4, let s = it.next() {
                group.addTask { await self.refresh(s, nil, allowRender: allowRender) }
                running += 1
            }
            while await group.next() != nil {
                if let s = it.next() {
                    group.addTask { await self.refresh(s, nil, allowRender: allowRender) }
                }
            }
        }
        lastRefresh = Date()
        scheduleSave()
        prefetchThumbnails()
    }

    func refresh(_ site: Site, _ category: SiteCategory?, allowRender: Bool = true) async {
        let key = Self.key(site, category)
        guard !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        do {
            var r = try await Self.fetchListing(url: category?.url ?? site.url, base: category?.url ?? site.url,
                                                site: site, categoryName: category?.name, allowRender: allowRender)
            var old = feeds[key] ?? []
            // Tiles that open more items (categories, albums) must not be shown as single images.
            var probe = listingProbe[key]
            if probe == nil, allowRender, !Scraper.isReddit(site.url) { probe = await Self.probeListingTiles(r, site: site) }
            if let probe {
                listingProbe[key] = probe
                if probe {
                    let tiles = r.items.filter(Self.isTileCandidate)
                    let tileIDs = Set(tiles.map(\.id))
                    if category == nil {
                        let cats = tiles.compactMap(\.asCategory)
                        let catURLs = Set(cats.map(\.url))
                        r.categories = cats + r.categories.filter { !catURLs.contains($0.url) }
                        r.items.removeAll { tileIDs.contains($0.id) }
                        old.removeAll { $0.isListing == true || tileIDs.contains($0.id) || Self.isTileCandidate($0) }
                    } else {
                        for i in r.items.indices where tileIDs.contains(r.items[i].id) { r.items[i].isListing = true }
                        old.removeAll { tileIDs.contains($0.id) }
                    }
                }
            }
            errors[key] = nil
            // Tiles that link to one of the site's categories open that category, never an image.
            let known = Set((r.categories + (SiteStore.shared.site(site.id)?.categories ?? [])).map(\.url.matchKey))
            if !known.isEmpty {
                if category == nil {
                    r.items.removeAll { $0.pageURL.map { known.contains($0.matchKey) } ?? false }
                    old.removeAll { $0.pageURL.map { known.contains($0.matchKey) } ?? false }
                } else {
                    for i in r.items.indices where r.items[i].pageURL.map({ known.contains($0.matchKey) }) ?? false {
                        r.items[i].isListing = true
                    }
                }
            }
            let newIDs = Set(r.items.map(\.id))
            var merged = r.items + old.filter { !newIDs.contains($0.id) }
            if merged.count > Limits.maxItemsPerFeed { merged = Array(merged.prefix(Limits.maxItemsPerFeed)) }
            feeds[key] = merged
            nextPages[key] = r.nextPage
            if category == nil { updateSiteMeta(site, result: r) }
            scheduleSave()
        } catch {
            if (feeds[key] ?? []).isEmpty { errors[key] = error.localizedDescription }
        }
    }

    func loadMore(_ site: Site, _ category: SiteCategory?) async {
        let key = Self.key(site, category)
        guard let next = nextPages[key], !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        do {
            let r = try await Self.fetchListing(url: next, base: category?.url ?? site.url, site: site,
                                                categoryName: category?.name, allowRender: true)
            var list = feeds[key] ?? []
            let have = Set(list.map(\.id))
            let fresh = r.items.filter { !have.contains($0.id) }
            list += fresh
            feeds[key] = list
            nextPages[key] = (fresh.isEmpty || r.nextPage == next) ? nil : r.nextPage
            scheduleSave()
        } catch {
            nextPages[key] = nil
        }
    }

    private func updateSiteMeta(_ site: Site, result: ScrapeResult) {
        guard var s = SiteStore.shared.site(site.id) else { return }
        var changed = false
        if !result.categories.isEmpty, result.categories != s.categories {
            s.categories = result.categories
            changed = true
        }
        if s.iconURL == nil, let icon = result.iconURL { s.iconURL = icon; changed = true }
        s.lastRefreshed = Date()
        changed = true
        if changed { SiteStore.shared.update(s) }
    }

    func forget(siteID: UUID) {
        for k in feeds.keys where k.hasPrefix(siteID.uuidString) { feeds[k] = nil; nextPages[k] = nil }
        scheduleSave()
    }

    func clearCache() {
        feeds = [:]
        nextPages = [:]
        resolvedCache = [:]
        listingProbe = [:]
        lastRefresh = nil
        scheduleSave()
    }

    // MARK: Fetching

    nonisolated static func fetchListing(url: URL, base: URL, site: Site, categoryName: String?, allowRender: Bool) async throws -> ScrapeResult {
        if Scraper.isReddit(url) {
            let jsonURL = url.path.hasSuffix(".json") ? url : (Scraper.redditJSONURL(for: url) ?? url)
            do {
                let data = try await Net.redditJSON(jsonURL)
                return Scraper.parseReddit(data: data, listingURL: base, site: site, categoryName: categoryName)
            } catch {
                // JSON refused: the RSS feed of the same page still lists images and thumbnails.
                var path = url.path
                if path.hasSuffix(".json") { path.removeLast(5) }
                while path.hasSuffix("/") { path.removeLast() }
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                comps?.host = "www.reddit.com"
                comps?.path = path + "/.rss"
                let keep = comps?.queryItems?.filter { $0.name == "t" || $0.name == "q" || $0.name == "after" }
                comps?.queryItems = keep
                guard let rss = comps?.url, let (data, resp) = try? await Net.fetch(rss) else { throw error }
                var r = Scraper.parseFeed(xml: Net.text(data, response: resp), baseURL: rss, site: site, categoryName: categoryName)
                if r.items.isEmpty { throw error }
                if Scraper.isRedditListing(base) { r.categories = Scraper.redditCategories(for: base) }
                return r
            }
        }
        var result = ScrapeResult()
        var staticOK = false
        if site.renderMode != .full || !allowRender {
            let (data, resp) = try await Net.fetch(url)
            let text = Net.text(data, response: resp)
            let finalURL = resp?.url ?? url
            if Scraper.looksLikeFeed(text) {
                return Scraper.parseFeed(xml: text, baseURL: finalURL, site: site, categoryName: categoryName)
            }
            result = Scraper.parseListing(html: text, baseURL: finalURL, site: site, categoryName: categoryName)
            staticOK = true
        }
        let needsRender = site.renderMode == .full || (site.renderMode == .auto && result.items.count < 6 && result.categories.count < 6)
        if allowRender && needsRender {
            if let html = await PageRenderer.shared.render(url) {
                let r2 = Scraper.parseListing(html: html, baseURL: url, site: site, categoryName: categoryName)
                if r2.items.count > result.items.count {
                    result.items = r2.items
                    result.nextPage = result.nextPage ?? r2.nextPage
                }
                if r2.categories.count > result.categories.count { result.categories = r2.categories }
                if result.iconURL == nil { result.iconURL = r2.iconURL }
                if result.title == nil { result.title = r2.title }
            } else if !staticOK {
                throw NetError.empty
            }
        }
        return result
    }

    // MARK: Category tiles

    /// A tile that opens a page (not a media file) and shows no video duration.
    nonisolated static func isTileCandidate(_ i: MediaItem) -> Bool {
        i.pageURL != nil && i.mediaURL == nil && i.duration == nil && i.kind != .video
    }

    /// Opens up to two tiles of a listing; when they lead to pages full of videos or images,
    /// the tiles are categories (or albums) rather than single media.
    nonisolated static func probeListingTiles(_ r: ScrapeResult, site: Site) async -> Bool? {
        let tiles = r.items.filter(isTileCandidate)
        guard tiles.count >= 4, Double(tiles.count) >= Double(r.items.count) * 0.6 else { return false }
        var listings = 0, checked = 0
        for t in tiles.prefix(2) {
            guard let page = t.pageURL, let isList = await isListingPage(page, site: site) else { continue }
            checked += 1
            if isList { listings += 1 } else { return false }
        }
        return checked == 0 ? nil : listings == checked
    }

    /// True when the page is a grid of many items rather than a page for one video or image.
    nonisolated static func isListingPage(_ url: URL, site: Site) async -> Bool? {
        guard let (data, resp) = try? await Net.fetch(url) else { return nil }
        let html = Net.text(data, response: resp)
        return isListingHTML(html, url: resp?.url ?? url, site: site)
    }

    nonisolated static func isListingHTML(_ html: String, url: URL, site: Site) -> Bool {
        if let type = Scraper.meta("og:type", in: html)?.lowercased(), type.contains("video") { return false }
        if Scraper.meta("og:video", in: html) != nil || Scraper.meta("og:video:url", in: html) != nil { return false }
        if Scraper.resolveDetail(html: html, pageURL: url, maxHeight: 2160)?.kind == .video { return false }
        let r = Scraper.parseListing(html: html, baseURL: url, site: site, categoryName: nil)
        let media = r.items.filter { $0.kind == .video || $0.duration != nil || $0.kind == .gif }.count
        return r.items.count >= 8 && media >= 4
    }

    private func markListing(_ item: MediaItem) {
        for (k, list) in feeds {
            if let i = list.firstIndex(where: { $0.id == item.id }) { feeds[k]?[i].isListing = true }
        }
        scheduleSave()
    }

    // MARK: Resolving

    func cachedResolution(_ item: MediaItem) -> ResolvedMedia? { resolvedCache[item.id] }

    func resolve(_ item: MediaItem) async -> ResolvedMedia? {
        if let r = resolvedCache[item.id] { return r }
        let maxQ = AppSettings.shared.maxQuality
        var result: ResolvedMedia?

        if let g = item.gallery, g.count > 1 {
            result = ResolvedMedia(url: g[0], kind: .image, gallery: g, referer: nil)
        } else if let page = item.pageURL, Scraper.isReddit(page), item.mediaURL == nil,
                  let data = try? await Net.redditJSON(Scraper.redditJSONURL(for: page) ?? page),
                  let post = Scraper.parseReddit(data: data, listingURL: page, site: SiteStore.shared.site(item.siteID) ?? Site(name: item.siteName, url: page), categoryName: nil).items.first,
                  post.mediaURL != nil || post.gallery != nil {
            if let g = post.gallery, g.count > 1 {
                result = ResolvedMedia(url: g[0], kind: .image, gallery: g, referer: nil)
            } else if let m = post.mediaURL {
                result = ResolvedMedia(url: m, kind: post.kind, referer: nil)
            }
        } else if let m = item.mediaURL {
            var url = m
            var kind = MediaKind.guess(from: m) ?? item.kind
            if m.pathExtension.lowercased() == "gifv", let mp4 = URL(string: m.absoluteString.replacingOccurrences(of: ".gifv", with: ".mp4")) {
                url = mp4; kind = .video
            }
            result = ResolvedMedia(url: url, kind: kind, referer: item.pageURL ?? item.mediaURL)
        } else if let page = item.pageURL {
            let site = SiteStore.shared.site(item.siteID)
            if site?.renderMode != .full, let (data, resp) = try? await Net.fetch(page) {
                let html = Net.text(data, response: resp)
                if item.kind != .video, item.duration == nil, let site,
                   Self.isListingHTML(html, url: resp?.url ?? page, site: site) {
                    let r = ResolvedMedia(url: page, kind: .image, referer: page, isListing: true)
                    resolvedCache[item.id] = r
                    markListing(item)
                    return r
                }
                result = Scraper.resolveDetail(html: html, pageURL: resp?.url ?? page, maxHeight: maxQ)
            }
            let wantsVideo = item.kind == .video && result?.kind != .video
            if result == nil || wantsVideo || site?.renderMode == .full {
                if let html = await PageRenderer.shared.render(page, settle: 1.2),
                   let r2 = Scraper.resolveDetail(html: html, pageURL: page, maxHeight: maxQ) {
                    if result == nil || r2.kind == .video { result = r2 }
                }
            }
        }
        if result == nil, let thumb = item.thumbnailURL {
            result = ResolvedMedia(url: thumb, kind: item.kind == .gif ? .gif : .image, referer: item.pageURL)
        }
        if let r = result {
            resolvedCache[item.id] = r
            if r.kind != item.kind { updateKind(item, to: r.kind) }
        }
        return result
    }

    private func updateKind(_ item: MediaItem, to kind: MediaKind) {
        for (k, list) in feeds {
            if let i = list.firstIndex(where: { $0.id == item.id }) {
                feeds[k]?[i].kind = kind
            }
        }
        var copy = item
        copy.kind = kind
        Library.shared.refreshItem(copy)
        scheduleSave()
    }

    // MARK: Search

    func remoteSearch(_ query: String) async -> [MediaItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let sites = SiteStore.shared.enabledSites
        return await withTaskGroup(of: [MediaItem].self) { group in
            for s in sites { group.addTask { await Self.search(q, on: s) } }
            var lists: [[MediaItem]] = []
            for await l in group { lists.append(l) }
            var out: [MediaItem] = []
            let maxLen = lists.map(\.count).max() ?? 0
            for i in 0..<maxLen { for l in lists where i < l.count { out.append(l[i]) } }
            return out
        }
    }

    nonisolated static func search(_ q: String, on site: Site) async -> [MediaItem] {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let pathEnc = q.replacingOccurrences(of: " ", with: "-").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q
        var candidates: [URL] = []
        if Scraper.isReddit(site.url) {
            if let u = Scraper.redditJSONURL(for: site.url, search: q) { candidates.append(u) }
        } else if let t = site.searchTemplate, !t.isEmpty {
            if let u = URL(string: t.replacingOccurrences(of: "{q}", with: enc)) { candidates.append(u) }
        } else {
            let root = site.url.scheme! + "://" + (site.url.host ?? "")
            candidates = ["\(root)/search?q=\(enc)", "\(root)/?s=\(enc)", "\(root)/search/\(pathEnc)/"].compactMap(URL.init(string:))
        }
        for u in candidates {
            if let r = try? await fetchListing(url: u, base: Scraper.isReddit(site.url) ? site.url : u, site: site,
                                               categoryName: nil, allowRender: false),
               r.items.count >= 2 {
                return Array(r.items.prefix(60))
            }
        }
        return []
    }

    // MARK: Background

    func backgroundRefresh() async {
        scheduleBackgroundRefresh()
        await refreshAll(allowRender: false)
        saveNow()
    }

    func scheduleBackgroundRefresh() {
        guard AppSettings.shared.backgroundRefresh else { return }
        let req = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    private func prefetchThumbnails() {
        let sites = SiteStore.shared.enabledSites
        var urls: [(URL, URL?)] = []
        for s in sites {
            for item in (feeds[Self.key(s)] ?? []).prefix(24) {
                if let t = item.thumbnailURL { urls.append((t, item.referer)) }
            }
        }
        ImagePipeline.shared.prefetch(urls)
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveNow() }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func saveNow() {
        Disk.save(Snapshot(feeds: feeds, nextPages: nextPages, lastRefresh: lastRefresh), "feeds.json")
    }
}
