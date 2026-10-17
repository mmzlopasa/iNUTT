import Foundation
import SwiftUI
import Combine

enum Disk {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iNUTT", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static let queue = DispatchQueue(label: "inutt.disk", qos: .utility)

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(T.self, from: data)
    }

    /// Encodes and writes in the background, in order, so saving never stalls scrolling.
    static func save<T: Encodable>(_ value: T, _ name: String) {
        let url = dir.appendingPathComponent(name)
        queue.async {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .secondsSince1970
            guard let data = try? enc.encode(value) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

// MARK: - Sites

@MainActor
final class SiteStore: ObservableObject {
    static let shared = SiteStore()

    @Published private(set) var sites: [Site] = []

    private init() {
        sites = Disk.load([Site].self, "sites.json") ?? []
    }

    var enabledSites: [Site] { sites.filter(\.enabled) }
    var canAdd: Bool { sites.count < Limits.maxSites }

    func site(_ id: UUID) -> Site? { sites.first { $0.id == id } }

    @discardableResult
    func add(_ site: Site) -> Bool {
        guard canAdd else { return false }
        if sites.contains(where: { $0.url.absoluteString.lowercased() == site.url.absoluteString.lowercased() }) { return false }
        sites.append(site)
        persist()
        return true
    }

    func update(_ site: Site) {
        guard let i = sites.firstIndex(where: { $0.id == site.id }) else { return }
        sites[i] = site
        persist()
    }

    func remove(_ ids: Set<UUID>) {
        sites.removeAll { ids.contains($0.id) }
        persist()
    }

    func move(from: IndexSet, to: Int) {
        sites.move(fromOffsets: from, toOffset: to)
        persist()
    }

    private func persist() { Disk.save(sites, "sites.json") }

    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // "r/pics", "/r/pics", "u/name" and "reddit.com/..." all mean Reddit.
        let lower = s.lowercased()
        if lower.hasPrefix("r/") || lower.hasPrefix("u/") || lower.hasPrefix("user/") { s = "https://www.reddit.com/" + s }
        else if lower.hasPrefix("/r/") || lower.hasPrefix("/u/") { s = "https://www.reddit.com" + s }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        guard let u = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              let host = u.host, host.contains(".") else { return nil }
        return u
    }
}

// MARK: - Favorites & history

/// Ids of everything opened before, so cards can show it without redrawing on every history change.
@MainActor
final class SeenMarks: ObservableObject {
    static let shared = SeenMarks()
    @Published fileprivate(set) var ids = Set<String>()
    func contains(_ item: MediaItem) -> Bool { ids.contains(item.id) }
}

/// Only the set of favorite ids, so grid cards redraw on a favorite change and not on every history record.
@MainActor
final class FavoriteMarks: ObservableObject {
    static let shared = FavoriteMarks()
    @Published fileprivate(set) var ids = Set<String>()
    func contains(_ item: MediaItem) -> Bool { ids.contains(item.id) }
}

@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var favorites: [MediaItem] = []
    /// Not published directly: while the viewer or Reels is open, screens underneath are not
    /// redrawn for every swipe; they catch up once when it closes.
    private(set) var history: [HistoryEntry] = []
    private var hold = 0
    private var dirty = false
    private var pendingSeen = Set<String>()
    private var historySave: DispatchWorkItem?

    func holdUpdates() { hold += 1 }
    var isHolding: Bool { hold > 0 }

    func releaseUpdates() {
        hold = max(0, hold - 1)
        guard hold == 0 else { return }
        ResumeStore.shared.flush()
        WatchLater.shared.flush()
        guard dirty else { return }
        dirty = false
        if !pendingSeen.isEmpty {
            SeenMarks.shared.ids.formUnion(pendingSeen)
            pendingSeen = []
        }
        objectWillChange.send()
    }

    private func historyChanged() {
        // Saving 2000 entries on every swipe is wasted work; once things settle is enough.
        historySave?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Disk.save(self.history, "history.json")
        }
        historySave = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
        if hold > 0 { dirty = true } else { objectWillChange.send() }
    }
    private var favoriteIDs = Set<String>() { didSet { FavoriteMarks.shared.ids = favoriteIDs } }

    private init() {
        favorites = Disk.load([MediaItem].self, "favorites.json") ?? []
        history = Disk.load([HistoryEntry].self, "history.json") ?? []
        favoriteIDs = Set(favorites.map(\.id))
        FavoriteMarks.shared.ids = favoriteIDs
        SeenMarks.shared.ids = Set(history.map(\.item.id))
    }

    func isFavorite(_ item: MediaItem) -> Bool { favoriteIDs.contains(item.id) }

    func toggleFavorite(_ item: MediaItem) {
        if favoriteIDs.contains(item.id) {
            favorites.removeAll { $0.id == item.id }
            favoriteIDs.remove(item.id)
        } else {
            favorites.insert(item, at: 0)
            favoriteIDs.insert(item.id)
        }
        Disk.save(favorites, "favorites.json")
        if AppSettings.shared.offlineFavorites { OfflineStore.shared.sync() }
    }

    func record(_ item: MediaItem) {
        guard AppSettings.shared.historyEnabled, !AppSettings.shared.privateMode else { return }
        history.removeAll { $0.item.id == item.id }
        history.insert(HistoryEntry(item: item, viewedAt: Date()), at: 0)
        if !SeenMarks.shared.ids.contains(item.id) {
            if hold > 0 { pendingSeen.insert(item.id) } else { SeenMarks.shared.ids.insert(item.id) }
        }
        if history.count > Limits.maxHistory { history.removeLast(history.count - Limits.maxHistory) }
        historyChanged()
    }

    func removeHistory(_ ids: Set<UUID>) {
        history.removeAll { ids.contains($0.id) }
        SeenMarks.shared.ids = Set(history.map(\.item.id))
        historyChanged()
    }

    func clearHistory() {
        history = []
        pendingSeen = []
        SeenMarks.shared.ids = []
        historyChanged()
    }

    /// Used by backup restore.
    func mergeFavorites(_ items: [MediaItem]) {
        let fresh = items.filter { !favoriteIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        favorites += fresh
        favoriteIDs.formUnion(fresh.map(\.id))
        Disk.save(favorites, "favorites.json")
    }

    /// Keeps stored copies in sync when an item's kind is discovered on open.
    func refreshItem(_ item: MediaItem) {
        if let i = favorites.firstIndex(where: { $0.id == item.id }), favorites[i].kind != item.kind {
            favorites[i].kind = item.kind
            Disk.save(favorites, "favorites.json")
        }
    }
}

// MARK: - Blocked words

/// Hides items whose title, category or link contains a blocked word. Read from any thread.
enum Blocklist {
    private static let lock = NSLock()
    private static var words: [String] = []

    static func update(_ list: [String]) {
        let w = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        lock.withLock { words = w }
    }

    static var isEmpty: Bool { lock.withLock { words.isEmpty } }

    static func blocks(_ item: MediaItem) -> Bool {
        let w = lock.withLock { words }
        guard !w.isEmpty else { return false }
        let hay = [item.title, item.categoryName ?? "", item.pageURL?.path ?? "", item.mediaURL?.path ?? ""]
            .joined(separator: " ").lowercased()
        return w.contains { hay.contains($0) }
    }

    static func filter(_ items: [MediaItem]) -> [MediaItem] {
        isEmpty ? items : items.filter { !blocks($0) }
    }
}

// MARK: - Collections

struct MediaCollection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var items: [MediaItem] = []
    var createdAt = Date()
}

/// Your own folders of saved items, next to Favorites.
@MainActor
final class CollectionStore: ObservableObject {
    static let shared = CollectionStore()
    @Published private(set) var collections: [MediaCollection] = []

    private init() { collections = Disk.load([MediaCollection].self, "collections.json") ?? [] }

    @discardableResult
    func create(_ name: String, with item: MediaItem? = nil) -> MediaCollection? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        var c = MediaCollection(name: n)
        if let item { c.items = [item] }
        collections.append(c)
        save()
        return c
    }

    func contains(_ item: MediaItem, in id: UUID) -> Bool {
        collections.first { $0.id == id }?.items.contains { $0.id == item.id } ?? false
    }

    /// Adds the item, or takes it out when it is already there. Returns true when it was added.
    @discardableResult
    func toggle(_ item: MediaItem, in id: UUID) -> Bool {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return false }
        defer { save() }
        if let j = collections[i].items.firstIndex(where: { $0.id == item.id }) {
            collections[i].items.remove(at: j)
            return false
        }
        collections[i].items.insert(item, at: 0)
        return true
    }

    func rename(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[i].name = n
        save()
    }

    func delete(_ id: UUID) {
        collections.removeAll { $0.id == id }
        save()
    }

    /// Used by backup restore.
    func merge(_ incoming: [MediaCollection]) {
        for c in incoming {
            if let i = collections.firstIndex(where: { $0.name.caseInsensitiveCompare(c.name) == .orderedSame }) {
                let have = Set(collections[i].items.map(\.id))
                collections[i].items += c.items.filter { !have.contains($0.id) }
            } else {
                collections.append(c)
            }
        }
        save()
    }

    private func save() { Disk.save(collections, "collections.json") }
}

// MARK: - Settings

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var faceIDEnabled: Bool { didSet { d.set(faceIDEnabled, forKey: "faceID") } }
    @Published var pinEnabled: Bool { didSet { d.set(pinEnabled, forKey: "pinEnabled") } }
    @Published var lockOnBackground: Bool { didSet { d.set(lockOnBackground, forKey: "lockOnBackground") } }
    @Published var historyEnabled: Bool { didSet { d.set(historyEnabled, forKey: "historyEnabled") } }
    @Published var autoplay: Bool { didSet { d.set(autoplay, forKey: "autoplay") } }
    @Published var loopVideos: Bool { didSet { d.set(loopVideos, forKey: "loopVideos") } }
    @Published var startMuted: Bool { didSet { d.set(startMuted, forKey: "startMuted") } }
    @Published var maxQuality: Int { didSet { d.set(maxQuality, forKey: "maxQuality") } }
    @Published var saveToPhotos: Bool { didSet { d.set(saveToPhotos, forKey: "saveToPhotos") } }
    @Published var backgroundRefresh: Bool { didSet { d.set(backgroundRefresh, forKey: "backgroundRefresh") } }
    @Published var hideInSwitcher: Bool { didSet { d.set(hideInSwitcher, forKey: "hideInSwitcher") } }
    @Published var recentSearches: [String] { didSet { d.set(recentSearches, forKey: "recentSearches") } }
    /// The one site the Reels tab plays from.
    @Published var reelsSource: String { didSet { d.set(reelsSource, forKey: "reelsSource") } }
    /// Reels move on to the next video when one ends.
    @Published var reelsAutoNext: Bool { didSet { d.set(reelsAutoNext, forKey: "reelsAutoNext") } }
    /// Home leaves out what you have already opened.
    @Published var hideSeen: Bool { didSet { d.set(hideSeen, forKey: "hideSeen") } }
    /// Words that hide an item everywhere (title, category or link).
    @Published var blockedWords: [String] {
        didSet {
            d.set(blockedWords, forKey: "blockedWords")
            Blocklist.update(blockedWords)
            FeedEngine.shared.filtersChanged()
        }
    }
    @Published var slideshowSeconds: Int { didSet { d.set(slideshowSeconds, forKey: "slideshowSeconds") } }
    @Published var slideshowRandom: Bool { didSet { d.set(slideshowRandom, forKey: "slideshowRandom") } }
    /// Downloads go into the encrypted vault inside the app instead of Photos and Files.
    @Published var vaultDownloads: Bool { didSet { d.set(vaultDownloads, forKey: "vaultDownloads") } }
    @Published var shakeToLock: Bool { didSet { d.set(shakeToLock, forKey: "shakeToLock") } }
    /// Nothing is remembered: no history, no seen marks, no resume points, no recent searches.
    @Published var privateMode: Bool { didSet { d.set(privateMode, forKey: "privateMode") } }
    /// Favorites are downloaded on Wi-Fi so they open offline.
    @Published var offlineFavorites: Bool { didSet { d.set(offlineFavorites, forKey: "offlineFavorites") } }
    @Published var offlineCollections: [String] { didSet { d.set(offlineCollections, forKey: "offlineCollections") } }
    @Published var notifyNew: Bool { didSet { d.set(notifyNew, forKey: "notifyNew") } }
    /// Notifications say only that something is new, never which site.
    @Published var notifyDiscreet: Bool { didSet { d.set(notifyDiscreet, forKey: "notifyDiscreet") } }
    @Published var watchedSites: [String] { didSet { d.set(watchedSites, forKey: "watchedSites") } }
    @Published var watchedForums: [String] { didSet { d.set(watchedForums, forKey: "watchedForums") } }

    private init() {
        d.register(defaults: [
            "lockOnBackground": true, "historyEnabled": true, "autoplay": true, "loopVideos": true,
            "maxQuality": 2160, "saveToPhotos": true, "backgroundRefresh": true, "hideInSwitcher": true,
            "slideshowSeconds": 5, "notifyDiscreet": true
        ])
        faceIDEnabled = d.bool(forKey: "faceID")
        pinEnabled = d.bool(forKey: "pinEnabled")
        lockOnBackground = d.bool(forKey: "lockOnBackground")
        historyEnabled = d.bool(forKey: "historyEnabled")
        autoplay = d.bool(forKey: "autoplay")
        loopVideos = d.bool(forKey: "loopVideos")
        startMuted = d.bool(forKey: "startMuted")
        maxQuality = d.integer(forKey: "maxQuality")
        saveToPhotos = d.bool(forKey: "saveToPhotos")
        backgroundRefresh = d.bool(forKey: "backgroundRefresh")
        hideInSwitcher = d.bool(forKey: "hideInSwitcher")
        recentSearches = d.stringArray(forKey: "recentSearches") ?? []
        reelsSource = d.string(forKey: "reelsSource") ?? ""
        reelsAutoNext = d.bool(forKey: "reelsAutoNext")
        hideSeen = d.bool(forKey: "hideSeen")
        blockedWords = d.stringArray(forKey: "blockedWords") ?? []
        slideshowSeconds = d.integer(forKey: "slideshowSeconds")
        slideshowRandom = d.bool(forKey: "slideshowRandom")
        vaultDownloads = d.bool(forKey: "vaultDownloads")
        shakeToLock = d.bool(forKey: "shakeToLock")
        privateMode = d.bool(forKey: "privateMode")
        offlineFavorites = d.bool(forKey: "offlineFavorites")
        offlineCollections = d.stringArray(forKey: "offlineCollections") ?? []
        notifyNew = d.bool(forKey: "notifyNew")
        notifyDiscreet = d.bool(forKey: "notifyDiscreet")
        watchedSites = d.stringArray(forKey: "watchedSites") ?? []
        watchedForums = d.stringArray(forKey: "watchedForums") ?? []
        Blocklist.update(blockedWords)
    }

    /// Follows a site or forum for new-content notifications. Returns true when it is now followed.
    @discardableResult
    func toggleWatch(_ id: UUID, forum: Bool) -> Bool {
        var list = forum ? watchedForums : watchedSites
        let on: Bool
        if let i = list.firstIndex(of: id.uuidString) { list.remove(at: i); on = false } else { list.append(id.uuidString); on = true }
        if forum { watchedForums = list } else { watchedSites = list }
        if on && !notifyNew { notifyNew = true }
        return on
    }

    func addRecentSearch(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !privateMode else { return }
        var r = recentSearches.filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        r.insert(t, at: 0)
        recentSearches = Array(r.prefix(15))
    }
}
