import Foundation

/// One file with your sites, forums, favorites, collections and blocked words. The same format is
/// used on iOS, Android and Windows, so a backup from one restores on the others.
enum Backup {
    struct Item: Codable {
        var title: String
        var siteName: String
        var thumbnailUrl: String?
        var mediaUrl: String?
        var pageUrl: String?
        var kind: String
        var duration: String?
        var categoryName: String?
    }

    struct SiteEntry: Codable {
        var name: String
        var url: String
        var enabled: Bool?
        var searchTemplate: String?
        var renderMode: String?
    }

    struct ForumEntry: Codable { var name: String; var url: String }
    struct CollectionEntry: Codable { var name: String; var items: [Item] }
    struct SettingsEntry: Codable { var blockedWords: [String]?; var reelsSource: String? }

    struct File: Codable {
        var app = "iNUTT"
        var version = 1
        var exportedAt: String
        var sites: [SiteEntry]
        var forums: [ForumEntry]?
        var favorites: [Item]?
        var collections: [CollectionEntry]?
        var settings: SettingsEntry?
    }

    struct Summary { var sites = 0, forums = 0, favorites = 0, collections = 0 }

    private static func pack(_ i: MediaItem) -> Item {
        Item(title: i.title, siteName: i.siteName, thumbnailUrl: i.thumbnailURL?.absoluteString,
             mediaUrl: i.mediaURL?.absoluteString, pageUrl: i.pageURL?.absoluteString, kind: i.kind.rawValue,
             duration: i.duration, categoryName: i.categoryName)
    }

    @MainActor
    private static func unpack(_ i: Item) -> MediaItem? {
        let thumb = i.thumbnailUrl.flatMap(URL.init(string:))
        let media = i.mediaUrl.flatMap(URL.init(string:))
        let page = i.pageUrl.flatMap(URL.init(string:))
        guard thumb != nil || media != nil || page != nil else { return nil }
        let site = SiteStore.shared.sites.first { $0.name == i.siteName }
        return MediaItem(siteID: site?.id ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xF0, 0xB0, 0x01)),
                         siteName: i.siteName, title: i.title, thumbnailURL: thumb, mediaURL: media, pageURL: page,
                         kind: MediaKind(rawValue: i.kind) ?? .image, duration: i.duration, categoryName: i.categoryName)
    }

    /// Writes a backup file to share or save, and returns where it is.
    @MainActor
    static func export() throws -> URL {
        let f = File(
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            sites: SiteStore.shared.sites.map {
                SiteEntry(name: $0.name, url: $0.url.absoluteString, enabled: $0.enabled,
                          searchTemplate: $0.searchTemplate, renderMode: $0.renderMode.rawValue)
            },
            forums: ForumStore.shared.forums.map { ForumEntry(name: $0.name, url: $0.url.absoluteString) },
            favorites: Library.shared.favorites.map(pack),
            collections: CollectionStore.shared.collections.map { CollectionEntry(name: $0.name, items: $0.items.map(pack)) },
            settings: SettingsEntry(blockedWords: AppSettings.shared.blockedWords, reelsSource: AppSettings.shared.reelsSource))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let day = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iNUTT-backup-\(day).json")
        try enc.encode(f).write(to: url, options: .atomic)
        return url
    }

    /// Adds everything from a backup to what is already here; nothing is removed.
    @MainActor
    static func restore(_ data: Data) throws -> Summary {
        let f = try JSONDecoder().decode(File.self, from: data)
        var s = Summary()
        for e in f.sites {
            guard let u = URL(string: e.url) else { continue }
            var site = Site(name: e.name, url: u)
            site.enabled = e.enabled ?? true
            site.searchTemplate = e.searchTemplate
            site.renderMode = e.renderMode.flatMap(RenderMode.init(rawValue:)) ?? .auto
            if SiteStore.shared.add(site) { s.sites += 1 }
        }
        let haveForums = Set(ForumStore.shared.forums.map { $0.url.absoluteString.lowercased() })
        for e in f.forums ?? [] where !haveForums.contains(e.url.lowercased()) {
            if ForumStore.shared.add(name: e.name, link: e.url) { s.forums += 1 }
        }
        let favs = (f.favorites ?? []).compactMap(unpack)
        let before = Library.shared.favorites.count
        Library.shared.mergeFavorites(favs)
        s.favorites = Library.shared.favorites.count - before
        let cols = (f.collections ?? []).map { MediaCollection(name: $0.name, items: $0.items.compactMap(unpack)) }
        CollectionStore.shared.merge(cols)
        s.collections = cols.count
        if let words = f.settings?.blockedWords, !words.isEmpty {
            var merged = AppSettings.shared.blockedWords
            for w in words where !merged.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) { merged.append(w) }
            AppSettings.shared.blockedWords = merged
        }
        if let r = f.settings?.reelsSource, !r.isEmpty, AppSettings.shared.reelsSource.isEmpty {
            AppSettings.shared.reelsSource = r
        }
        if s.sites > 0 { Task { await FeedEngine.shared.refreshAll() } }
        return s
    }
}
