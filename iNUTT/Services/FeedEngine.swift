import Foundation
import BackgroundTasks

/// Loads, caches and refreshes content from every site. Cached feeds are shown instantly on launch.
@MainActor
final class FeedEngine: ObservableObject {
    static let shared = FeedEngine()
    static let refreshTaskID = "dev.scyde.inutt.refresh"

    // Many sites refresh at once; screens are told about changes at most a few times a second
    // instead of after every single update, which kept them busy and made scrolling stutter.
    private(set) var feeds: [String: [MediaItem]] = [:] { didSet { version &+= 1; changed() } }
    private(set) var loading: Set<String> = [] { didSet { changed() } }
    private(set) var errors: [String: String] = [:] { didSet { changed() } }
    private var version = 0
    private var changePending = false
    private var homeCache: [UUID: (version: Int, items: [MediaItem])] = [:]
    private var mixedCache: (version: Int, sites: [UUID], items: [MediaItem])?

    private func changed() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.changePending = false
            self.objectWillChange.send()
        }
    }
    @Published private(set) var isRefreshingAll = false
    @Published private(set) var lastRefresh: Date?

    private var nextPages: [String: URL] = [:]
    private var resolvedCache: [String: ResolvedMedia] = [:]
    private var resolvedAt: [String: Date] = [:]
    /// Per feed: whether its thumbnail tiles turned out to be categories (checked once per launch).
    private var listingProbe: [String: Bool] = [:]
    private var saveWork: DispatchWorkItem?

    private struct ResolvedEntry: Codable { var media: ResolvedMedia; var at: Date }

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
        // Known files from earlier sessions; video links often expire, so only recent ones.
        if let saved = Disk.load([String: ResolvedEntry].self, "resolved.json") {
            let fresh = Date().addingTimeInterval(-6 * 3600)
            for (k, e) in saved where e.at > fresh {
                resolvedCache[k] = e.media
                resolvedAt[k] = e.at
            }
        }
    }

    static func key(_ site: Site, _ category: SiteCategory? = nil) -> String {
        if let category { return site.id.uuidString + "|" + category.url.absoluteString }
        return site.id.uuidString
    }

    func items(_ site: Site, _ category: SiteCategory? = nil) -> [MediaItem] { feeds[Self.key(site, category)] ?? [] }
    func hasMore(_ site: Site, _ category: SiteCategory? = nil) -> Bool { nextPages[Self.key(site, category)] != nil }

    /// All cached items across enabled sites, interleaved so no site dominates.
    /// What a site contributes to Home and its Latest section: real media, never category covers.
    /// When the site's own page only lists categories, its newest items come from those categories.
    func homeItems(_ site: Site) -> [MediaItem] {
        if let c = homeCache[site.id], c.version == version { return c.items }
        let items = computeHomeItems(site)
        homeCache[site.id] = (version, items)
        return items
    }

    private func computeHomeItems(_ site: Site) -> [MediaItem] {
        let covers = Set(site.categories.compactMap { $0.thumbnailURL?.absoluteString })
        let root = (feeds[Self.key(site)] ?? []).filter { i in
            i.isListing != true && !(i.thumbnailURL.map { covers.contains($0.absoluteString) } ?? false)
                && site.category(matching: i.pageURL) == nil
        }
        guard !site.categories.isEmpty, Self.needsCategoryFeeds(root) else { return root }
        let lists = site.categories.map { feeds[Self.key(site, $0)] ?? [] }.filter { !$0.isEmpty }
        if lists.isEmpty { return root.filter(Self.isMedia) }
        var out = root.filter(Self.isMedia)
        var seen = Set(out.map(\.id))
        let maxLen = lists.map(\.count).max() ?? 0
        for i in 0..<maxLen {
            for l in lists where i < l.count && l[i].isListing != true {
                if seen.insert(l[i].id).inserted { out.append(l[i]) }
            }
        }
        return out
    }

    /// Clearly a video, GIF or direct media file rather than a picture linking to another page.
    nonisolated static func isMedia(_ i: MediaItem) -> Bool {
        i.kind == .video || i.kind == .gif || i.duration != nil || i.mediaURL != nil
    }

    /// The root page shows (almost) no real media, so its content lives in the categories.
    nonisolated static func needsCategoryFeeds(_ root: [MediaItem]) -> Bool {
        root.filter(isMedia).count < 6
    }

    func mixedFeed(_ sites: [Site]) -> [MediaItem] {
        let ids = sites.map(\.id)
        if let c = mixedCache, c.version == version, c.sites == ids { return c.items }
        let lists = sites.map { homeItems($0) }
        var out: [MediaItem] = []
        var seen = Set<String>()
        let maxLen = lists.map(\.count).max() ?? 0
        for i in 0..<maxLen {
            for l in lists where i < l.count {
                if l[i].isListing != true, seen.insert(l[i].id).inserted { out.append(l[i]) }
            }
        }
        mixedCache = (version, ids, out)
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
                group.addTask { await self.refreshForHome(s, allowRender: allowRender) }
                running += 1
            }
            while await group.next() != nil {
                if let s = it.next() {
                    group.addTask { await self.refreshForHome(s, allowRender: allowRender) }
                }
            }
        }
        lastRefresh = Date()
        scheduleSave()
        prefetchThumbnails()
    }

    /// Refreshes a site and, when its page only lists categories, the first few categories too.
    func refreshForHome(_ site: Site, allowRender: Bool) async {
        await refresh(site, nil, allowRender: allowRender)
        guard let s = SiteStore.shared.site(site.id), !s.categories.isEmpty,
              Self.needsCategoryFeeds(feeds[Self.key(s)] ?? []) else { return }
        for c in s.categories.prefix(4) {
            await refresh(s, c, allowRender: allowRender)
        }
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
            // The site was removed while it loaded.
            guard SiteStore.shared.site(site.id) != nil else { return }
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

    /// Next pages for the Home feed: each site's own page, or the categories its Home items come from.
    func loadMoreHome(_ sites: [Site]) async {
        var jobs: [(Site, SiteCategory?)] = []
        for site in sites.prefix(12) {
            if nextPages[Self.key(site)] != nil { jobs.append((site, nil)) }
            if !site.categories.isEmpty, Self.needsCategoryFeeds(feeds[Self.key(site)] ?? []) {
                for c in site.categories.prefix(3) where nextPages[Self.key(site, c)] != nil { jobs.append((site, c)) }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for (site, c) in jobs { group.addTask { await self.loadMore(site, c) } }
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
        resolvedAt = [:]
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

    private var inflight: [String: Task<ResolvedMedia?, Never>] = [:]
    private var prefetchQueue: [MediaItem] = []
    private var prefetching = 0

    /// Finds the playable file behind an item. `.user` is for what is on screen now; it may open
    /// the page in a hidden web view. Results are kept (also on disk) so the next tap is instant.
    func resolve(_ item: MediaItem, priority: PageRenderer.Priority = .user) async -> ResolvedMedia? {
        if let r = resolvedCache[item.id] { return r }
        // Share work with a prefetch of the same item that is already running.
        if let t = inflight[item.id] {
            if let r = await t.value { return r }
            if let r = resolvedCache[item.id] { return r }
        }
        let task = Task { await self.resolveUncached(item, allowRender: true, priority: priority) }
        inflight[item.id] = task
        let r = await task.value
        inflight[item.id] = nil
        if let r { remember(item, r) }
        // Nothing playable: show the thumbnail, but keep trying next time.
        if r == nil, let thumb = item.thumbnailURL {
            return ResolvedMedia(url: thumb, kind: item.kind == .gif ? .gif : .image, referer: item.pageURL)
        }
        return r
    }

    /// Resolves items as they scroll into view, without opening hidden web views, so most taps
    /// find their file already known. The newest requests go first.
    func prefetch(_ item: MediaItem) {
        guard item.isListing != true, item.mediaURL == nil, item.pageURL != nil,
              resolvedCache[item.id] == nil, inflight[item.id] == nil else { return }
        prefetchQueue.removeAll { $0.id == item.id }
        prefetchQueue.append(item)
        if prefetchQueue.count > 40 { prefetchQueue.removeFirst(prefetchQueue.count - 40) }
        pumpPrefetch()
    }

    private func pumpPrefetch() {
        while prefetching < 3, let item = prefetchQueue.popLast() {
            guard resolvedCache[item.id] == nil, inflight[item.id] == nil else { continue }
            prefetching += 1
            let task = Task { await self.resolveUncached(item, allowRender: false, priority: .background) }
            inflight[item.id] = task
            Task {
                let r = await task.value
                self.inflight[item.id] = nil
                if let r { self.remember(item, r) }
                self.prefetching -= 1
                self.pumpPrefetch()
            }
        }
    }

    private func remember(_ item: MediaItem, _ r: ResolvedMedia) {
        resolvedCache[item.id] = r
        resolvedAt[item.id] = Date()
        if r.isListing { markListing(item) } else if r.kind != item.kind { updateKind(item, to: r.kind) }
        scheduleSave()
    }

    /// Returns nil when nothing playable was found (or, without rendering, when the page needs it).
    private func resolveUncached(_ item: MediaItem, allowRender: Bool, priority: PageRenderer.Priority) async -> ResolvedMedia? {
        let maxQ = AppSettings.shared.maxQuality
        if let g = item.gallery, g.count > 1 {
            return ResolvedMedia(url: g[0], kind: .image, gallery: g, referer: nil)
        }
        if let m = item.mediaURL {
            var url = m
            var kind = MediaKind.guess(from: m) ?? item.kind
            if m.pathExtension.lowercased() == "gifv", let mp4 = URL(string: m.absoluteString.replacingOccurrences(of: ".gifv", with: ".mp4")) {
                url = mp4; kind = .video
            }
            return ResolvedMedia(url: url, kind: kind, referer: item.pageURL ?? item.mediaURL)
        }
        guard let page = item.pageURL else { return nil }
        if Scraper.isReddit(page) {
            let site = SiteStore.shared.site(item.siteID) ?? Site(name: item.siteName, url: page)
            guard let data = try? await Net.redditJSON(Scraper.redditJSONURL(for: page) ?? page) else { return nil }
            let post = await Task.detached { Scraper.parseReddit(data: data, listingURL: page, site: site, categoryName: nil).items.first }.value
            if let g = post?.gallery, g.count > 1 { return ResolvedMedia(url: g[0], kind: .image, gallery: g, referer: nil) }
            if let m = post?.mediaURL { return ResolvedMedia(url: m, kind: post?.kind ?? .image, referer: nil) }
            return nil
        }

        let site = SiteStore.shared.site(item.siteID)
        let expectsVideo = item.kind == .video || item.duration != nil
        var result: ResolvedMedia?
        if site?.renderMode != .full, let (data, resp) = try? await Net.fetch(page) {
            let finalURL = resp?.url ?? page
            let checkListing = item.kind != .video && item.duration == nil
            // Parsing big pages takes time; keep it off the main thread so scrolling stays smooth.
            let (isListing, detail) = await Task.detached { () -> (Bool, ResolvedMedia?) in
                let html = Net.text(data, response: resp)
                if checkListing, let site, Self.isListingHTML(html, url: finalURL, site: site) { return (true, nil) }
                return (false, Scraper.resolveDetail(html: html, pageURL: finalURL, maxHeight: maxQ))
            }.value
            if isListing { return ResolvedMedia(url: page, kind: .image, referer: page, isListing: true) }
            result = detail
        }
        let needsRender = result == nil || (expectsVideo && result?.kind != .video) || site?.renderMode == .full
        guard needsRender else { return result }
        guard allowRender else { return nil }
        let (video, html) = await PageRenderer.shared.renderMedia(page)
        if let v = video {
            return ResolvedMedia(url: v.url, kind: .video, gallery: v.poster.map { [$0] } ?? [], referer: page)
        }
        if let html {
            let r2 = await Task.detached { Scraper.resolveDetail(html: html, pageURL: page, maxHeight: maxQ) }.value
            if let r2, result == nil || r2.kind == .video { result = r2 }
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
        var entries: [String: ResolvedEntry] = [:]
        for (k, at) in resolvedAt.sorted(by: { $0.value > $1.value }).prefix(3000) {
            if let m = resolvedCache[k] { entries[k] = ResolvedEntry(media: m, at: at) }
        }
        Disk.save(entries, "resolved.json")
    }
}
