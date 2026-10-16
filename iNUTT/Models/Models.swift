import Foundation
import CryptoKit

enum MediaKind: String, Codable, CaseIterable, Hashable {
    case image, gif, video

    var label: String {
        switch self {
        case .image: return "Images"
        case .gif: return "GIF"
        case .video: return "Video"
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
struct ResolvedMedia: Hashable {
    var url: URL
    var kind: MediaKind
    /// Extra images when the page is a gallery.
    var gallery: [URL] = []
    var referer: URL?
}

enum Limits {
    static let maxSites = 50
    static let maxItemsPerFeed = 400
    static let maxHistory = 2000
}
