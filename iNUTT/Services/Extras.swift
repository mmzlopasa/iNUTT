import Foundation
import Network
import UserNotifications
import WebKit

// MARK: - Continue watching

struct ResumePoint: Codable, Hashable {
    var item: MediaItem
    var seconds: Double
    var duration: Double
    var updatedAt: Date
    var progress: Double { duration > 0 ? min(1, seconds / duration) : 0 }
}

/// Where you stopped in each video, so it carries on from there and shows up under Continue watching.
@MainActor
final class ResumeStore: ObservableObject {
    static let shared = ResumeStore()
    private(set) var points: [String: ResumePoint] = [:]
    private var saveWork: DispatchWorkItem?
    private var pending = false

    private init() { points = Disk.load([String: ResumePoint].self, "resume.json") ?? [:] }

    /// Unfinished videos, most recent first.
    var continueWatching: [ResumePoint] {
        points.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The position to start from, when there is one worth resuming.
    func position(for id: String) -> Double? {
        guard let p = points[id], p.seconds > 5 else { return nil }
        if p.duration > 0 && p.seconds > p.duration - 8 { return nil }
        return p.seconds
    }

    func update(_ item: MediaItem, seconds: Double, duration: Double) {
        guard !AppSettings.shared.privateMode, seconds.isFinite, seconds > 0 else { return }
        let d = duration.isFinite ? duration : 0
        if d > 0 && (seconds >= d * 0.95 || d - seconds < 8) {
            finished(item)
            return
        }
        guard seconds > 5 else { return }
        points[item.id] = ResumePoint(item: item, seconds: seconds, duration: d, updatedAt: Date())
        if points.count > 60, let oldest = points.values.min(by: { $0.updatedAt < $1.updatedAt }) {
            points[oldest.item.id] = nil
        }
        changed()
    }

    /// Watched to the end: off the Continue watching row and out of Watch later.
    func finished(_ item: MediaItem) {
        WatchLater.shared.remove(item)
        guard points.removeValue(forKey: item.id) != nil else { return }
        changed()
    }

    func remove(_ id: String) {
        guard points.removeValue(forKey: id) != nil else { return }
        changed()
    }

    func clear() {
        points = [:]
        changed()
    }

    /// Screens under the viewer catch up once it closes.
    func flush() {
        guard pending else { return }
        pending = false
        objectWillChange.send()
    }

    private func changed() {
        if Library.shared.isHolding { pending = true } else { objectWillChange.send() }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Disk.save(self.points, "resume.json")
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }
}

// MARK: - Watch later

/// A queue separate from favorites. Pictures leave it once you have looked at them, videos once watched to the end.
@MainActor
final class WatchLater: ObservableObject {
    static let shared = WatchLater()
    private(set) var items: [MediaItem] = []
    private var ids = Set<String>()
    private var pending = false

    private init() {
        items = Disk.load([MediaItem].self, "watchLater.json") ?? []
        ids = Set(items.map(\.id))
    }

    func contains(_ item: MediaItem) -> Bool { ids.contains(item.id) }

    func toggle(_ item: MediaItem) {
        if ids.contains(item.id) { remove(item) } else {
            items.insert(item, at: 0)
            ids.insert(item.id)
            changed()
        }
    }

    func remove(_ item: MediaItem) { remove(ids: [item.id]) }

    func remove(ids gone: Set<String>) {
        let hit = gone.intersection(ids)
        guard !hit.isEmpty else { return }
        items.removeAll { hit.contains($0.id) }
        ids.subtract(hit)
        changed()
    }

    func clear() {
        items = []
        ids = []
        changed()
    }

    func flush() {
        guard pending else { return }
        pending = false
        objectWillChange.send()
    }

    private func changed() {
        if Library.shared.isHolding { pending = true } else { objectWillChange.send() }
        Disk.save(items, "watchLater.json")
    }
}

// MARK: - Login carries over

enum CookieSync {
    /// Sign-ins from the in-app browser are used by Home, Sites, Search and the player as well.
    @MainActor
    static func pull() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let jar = HTTPCookieStorage.shared
        jar.cookieAcceptPolicy = .always
        for c in cookies { jar.setCookie(c) }
    }
}

// MARK: - Offline

/// Favorites and chosen collections downloaded on Wi-Fi, so they open without a connection.
@MainActor
final class OfflineStore: ObservableObject {
    static let shared = OfflineStore()

    struct Entry: Codable { var file: String; var kind: MediaKind; var size: Int64 }

    @Published private(set) var entries: [String: Entry] = [:]
    @Published private(set) var syncing = false
    @Published private(set) var onWiFi = false
    private let monitor = NWPathMonitor()
    private var syncAgain = false

    nonisolated static let dir: URL = {
        let d = Disk.dir.appendingPathComponent("Offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = d
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? v.setResourceValues(rv)
        return d
    }()

    private init() {
        entries = Disk.load([String: Entry].self, "offline.json") ?? [:]
        monitor.pathUpdateHandler = { path in
            let wifi = path.status == .satisfied && !path.isExpensive
            Task { @MainActor in
                let was = OfflineStore.shared.onWiFi
                OfflineStore.shared.onWiFi = wifi
                if wifi && !was { OfflineStore.shared.sync() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "inutt.offline.path"))
    }

    var totalSize: Int64 { entries.values.reduce(0) { $0 + $1.size } }

    /// The downloaded copy of an item, when there is one.
    func file(for id: String) -> (URL, MediaKind)? {
        guard let e = entries[id] else { return nil }
        let u = Self.dir.appendingPathComponent(e.file)
        return FileManager.default.fileExists(atPath: u.path) ? (u, e.kind) : nil
    }

    func isOfflineCollection(_ id: UUID) -> Bool { AppSettings.shared.offlineCollections.contains(id.uuidString) }

    func toggleCollection(_ id: UUID) {
        var s = AppSettings.shared.offlineCollections
        if let i = s.firstIndex(of: id.uuidString) { s.remove(at: i) } else { s.append(id.uuidString) }
        AppSettings.shared.offlineCollections = s
        sync()
    }

    private var wanted: [MediaItem] {
        var out: [MediaItem] = []
        var seen = Set<String>()
        if AppSettings.shared.offlineFavorites {
            for i in Library.shared.favorites where seen.insert(i.id).inserted { out.append(i) }
        }
        let cols = Set(AppSettings.shared.offlineCollections)
        for c in CollectionStore.shared.collections where cols.contains(c.id.uuidString) {
            for i in c.items where seen.insert(i.id).inserted { out.append(i) }
        }
        return out.filter { $0.isListing != true }
    }

    /// Downloads what is missing (Wi-Fi only) and removes what is no longer wanted.
    func sync() {
        guard !syncing else { syncAgain = true; return }
        let want = wanted
        let keep = Set(want.map(\.id))
        for (id, e) in entries where !keep.contains(id) {
            try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(e.file))
            entries[id] = nil
        }
        save()
        let missing = want.filter { entries[$0.id] == nil }
        guard onWiFi, !missing.isEmpty else { return }
        syncing = true
        Task {
            for item in missing {
                guard onWiFi, wanted.contains(where: { $0.id == item.id }) else { continue }
                await fetch(item)
            }
            syncing = false
            if syncAgain { syncAgain = false; sync() }
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: Self.dir)
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        entries = [:]
        save()
    }

    private func fetch(_ item: MediaItem) async {
        guard let media = await FeedEngine.shared.resolve(item, priority: .background),
              !media.isListing, !media.url.isFileURL, !media.url.absoluteString.contains(".m3u8") else { return }
        var req = Net.request(media.url, referer: media.referer)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        guard let (tmp, resp) = try? await Net.session.download(for: req),
              ((resp as? HTTPURLResponse)?.statusCode ?? 200) < 400 else { return }
        let ext = DownloadManager.fileExtension(for: media, response: resp)
        let name = item.id + "." + ext
        let dest = Self.dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        let kind: MediaKind = media.kind == .video ? .video : (ext == "gif" ? .gif : .image)
        entries[item.id] = Entry(file: name, kind: kind, size: size)
        save()
    }

    private func save() { Disk.save(entries, "offline.json") }
}

// MARK: - New-content notifications

/// Checks the sites and forums you follow in the background and tells you when something new is there.
@MainActor
enum NewContentWatcher {
    private static var seen: [String: [String]] = Disk.load([String: [String]].self, "watch.json") ?? [:]

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Returns what is new per followed site or forum, and remembers it so it is counted once.
    static func check() async -> [(String, Int)] {
        let s = AppSettings.shared
        guard s.notifyNew else { return [] }
        await CookieSync.pull()
        var found: [(String, Int)] = []
        for site in SiteStore.shared.sites where s.watchedSites.contains(site.id.uuidString) {
            guard let r = try? await FeedEngine.fetchListing(url: site.url, base: site.url, site: site, categoryName: nil, allowRender: false) else { continue }
            let ids = Blocklist.filter(r.items).filter { $0.isListing != true }.map(\.id)
            let n = note("s:" + site.id.uuidString, ids)
            if n > 0 { found.append((site.name, n)) }
        }
        for f in ForumStore.shared.forums where s.watchedForums.contains(f.id.uuidString) {
            let page = f.lastURL ?? f.url
            guard let (data, resp) = try? await Net.fetch(page) else { continue }
            let html = Net.text(data, response: resp)
            let keys = await Task.detached { NewContentWatcher.forumKeys(html, base: page) }.value
            let n = note("f:" + f.id.uuidString, keys)
            if n > 0 { found.append((f.name, n)) }
        }
        Disk.save(seen, "watch.json")
        return found
    }

    /// Counts keys not seen before. The first look only sets the starting point.
    private static func note(_ key: String, _ ids: [String]) -> Int {
        guard !ids.isEmpty else { return 0 }
        let before = seen[key]
        let known = Set(before ?? [])
        let fresh = ids.filter { !known.contains($0) }
        var merged = fresh + (before ?? [])
        if merged.count > 300 { merged.removeLast(merged.count - 300) }
        seen[key] = merged
        return before == nil ? 0 : fresh.count
    }

    /// Pictures, videos and thread links of a forum page.
    nonisolated static func forumKeys(_ html: String, base: URL) -> [String] {
        var out = Scraper.rawMediaURLs(in: html, base: base).map(\.absoluteString)
        for m in HTML.matches(#"href=["']([^"']*(?:thread|topic|showthread|/t/|viewtopic)[^"']*)["']"#, in: html, limit: 400) {
            if let u = HTML.resolve(m[1], base: base) { out.append(u.matchKey) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    static func checkAndNotify() async {
        let found = await check()
        guard !found.isEmpty else { return }
        let total = found.reduce(0) { $0 + $1.1 }
        let c = UNMutableNotificationContent()
        c.title = "iNUTT"
        if AppSettings.shared.notifyDiscreet {
            c.body = "New content is waiting"
        } else {
            c.body = found.prefix(4).map { "\($0.0): \($0.1) new" }.joined(separator: " · ")
        }
        c.sound = .default
        c.badge = NSNumber(value: total)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "new-content", content: c, trigger: nil))
    }
}
