import Foundation
import CryptoKit

enum MediaKind: String, Codable, CaseIterable, Hashable {
    case image, gif, video

    var label: String {
        switch self {
        case .image: return "Images"
        case .gif: return "GIFs"
        case .video: return "Videos"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .gif: return "sparkles.rectangle.stack"
        case .video: return "play.rectangle.fill"
        }
    }

    static func guess(from url: URL?) -> MediaKind? {
        guard let ext = url?.pathExtension.lowercased(), !ext.isEmpty else { return nil }
        switch ext {
        case "gif", "gifv": return .gif
        case "mp4", "m4v", "mov", "m3u8", "webm", "ts": return .video
        case "jpg", "jpeg", "png", "webp", "heic", "avif", "bmp": return .image
        default: return nil
        }
    }
}

struct MediaItem: Codable, Identifiable, Hashable {
    var id: String
    var siteID: UUID
    var siteName: String
    var title: String
    var thumbnailURL: URL?
    /// Direct media URL when it is known without opening the detail page.
    var mediaURL: URL?
    /// Page that holds the real media (resolved lazily when opened).
    var pageURL: URL?
    var kind: MediaKind
    var duration: String?
    var categoryName: String?
    var addedAt: Date
    /// True when the link leads to a list of more items (a category or album), not to one media file.
    var isListing: Bool?
    /// Every image of a multi-image post (Reddit galleries).
    var gallery: [URL]?

    init(siteID: UUID, siteName: String, title: String, thumbnailURL: URL?, mediaURL: URL?, pageURL: URL?,
         kind: MediaKind, duration: String? = nil, categoryName: String? = nil, addedAt: Date = Date()) {
        let key = (pageURL ?? mediaURL ?? thumbnailURL)?.absoluteString ?? UUID().uuidString
        self.id = MediaItem.hash(key)
        self.siteID = siteID
        self.siteName = siteName
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.mediaURL = mediaURL
        self.pageURL = pageURL
        self.kind = kind
        self.duration = duration
        self.categoryName = categoryName
        self.addedAt = addedAt
    }

    static func hash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    var displayTitle: String {
        title.isEmpty ? siteName : title
    }

    var referer: URL? { pageURL ?? thumbnailURL }

    /// The category this item opens when it is a listing tile.
    var asCategory: SiteCategory? {
        guard let p = pageURL else { return nil }
        let name = title.isEmpty ? p.lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized : title
        return SiteCategory(name: name, url: p, thumbnailURL: thumbnailURL)
    }
}

struct SiteCategory: Codable, Identifiable, Hashable {
    var name: String
    var url: URL
    var thumbnailURL: URL?
    var id: String { url.absoluteString }
}

enum RenderMode: String, Codable, CaseIterable, Identifiable {
    case auto, fast, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .fast: return "Fast (HTML)"
        case .full: return "Full (JavaScript)"
        }
    }
}

struct Site: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: URL
    var searchTemplate: String?
    var renderMode: RenderMode = .auto
    var enabled: Bool = true
    var iconURL: URL?
    var categories: [SiteCategory] = []
    var lastRefreshed: Date?
    var addedAt: Date = Date()

    var host: String { url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString }
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var item: MediaItem
    var viewedAt: Date
}

/// Result of opening an item: the real, playable media.
struct ResolvedMedia: Hashable, Codable {
    var url: URL
    var kind: MediaKind
    /// Extra images when the page is a gallery.
    var gallery: [URL] = []
    var referer: URL?
    /// The page turned out to be a category / listing page rather than a single media item.
    var isListing = false
}

extension URL {
    /// Compares links regardless of scheme, "www.", case and a trailing slash.
    var matchKey: String {
        var s = (host ?? "").lowercased().replacingOccurrences(of: "www.", with: "") + path.lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        if let q = query, !q.isEmpty { s += "?" + q }
        return s
    }
}

extension Site {
    /// The category a link points to, when it is one of this site's categories.
    func category(matching url: URL?) -> SiteCategory? {
        guard let key = url?.matchKey else { return nil }
        return categories.first { $0.url.matchKey == key }
    }
}

enum Limits {
    static let maxSites = 50
    static let maxItemsPerFeed = 400
    static let maxHistory = 2000
}
