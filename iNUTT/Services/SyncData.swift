import CryptoKit
import Foundation

/// The parts of the sync file beyond the lists of sites, forums and saved items: history, searches,
/// blocked words, resume points, taste, settings and the vault. Android and Windows write the same shapes.
extension SyncManager {
    struct SyncHistory: Codable { var item: Backup.Item; var at: Double }
    struct SyncResume: Codable { var item: Backup.Item; var seconds: Double; var duration: Double; var at: Double }
    struct SyncTaste: Codable, Equatable { var weights: [String: Double]; var signals: Int }

    /// Vault files themselves are kept next to the sync file on GitHub, in parts, sealed with the sync key.
    struct SyncVault: Codable, Equatable {
        var id: String
        var title: String
        var siteName: String
        var kind: String
        var ext: String
        var size: Int64
        var thumb: String?
        var addedAt: Double
        var parts: Int
    }

    /// Settings that mean the same on every device. Lock settings stay per device.
    struct SyncSettings: Codable, Equatable {
        var at: Double?
        var autoplay: Bool?
        var loopVideos: Bool?
        var startMuted: Bool?
        var maxQuality: Int?
        var historyEnabled: Bool?
        var reelsSource: String?
        var reelsAutoNext: Bool?
        var hideSeen: Bool?
        var slideshowSeconds: Int?
        var slideshowRandom: Bool?
        var vaultDownloads: Bool?
        var privateMode: Bool?
        var offlineFavorites: Bool?
        var hideDuplicates: Bool?
        var smartMix: Bool?
        var notifyNew: Bool?
        var notifyDiscreet: Bool?
        var hideInSwitcher: Bool?
        var lockOnBackground: Bool?

        var withoutTime: SyncSettings {
            var c = self
            c.at = nil
            return c
        }
    }

    /// How much history travels; older entries stay on the device they were made on.
    static let historyLimit = 500
    static let searchLimit = 15
    /// Plain bytes per vault part on GitHub, so no single upload gets large.
    static let vaultPart = 8 << 20

    static func ms(_ d: Date) -> Double { (d.timeIntervalSince1970 * 1000).rounded() }
    static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}

extension AppSettings {
    var syncValues: SyncManager.SyncSettings {
        SyncManager.SyncSettings(
            autoplay: autoplay, loopVideos: loopVideos, startMuted: startMuted, maxQuality: maxQuality,
            historyEnabled: historyEnabled, reelsSource: reelsSource, reelsAutoNext: reelsAutoNext, hideSeen: hideSeen,
            slideshowSeconds: slideshowSeconds, slideshowRandom: slideshowRandom, vaultDownloads: vaultDownloads,
            privateMode: privateMode, offlineFavorites: offlineFavorites, hideDuplicates: hideDuplicates, smartMix: smartMix,
            notifyNew: notifyNew, notifyDiscreet: notifyDiscreet, hideInSwitcher: hideInSwitcher, lockOnBackground: lockOnBackground)
    }

    func apply(_ s: SyncManager.SyncSettings) {
        func set<T: Equatable>(_ path: ReferenceWritableKeyPath<AppSettings, T>, _ v: T?) {
            if let v, self[keyPath: path] != v { self[keyPath: path] = v }
        }
        set(\.autoplay, s.autoplay)
        set(\.loopVideos, s.loopVideos)
        set(\.startMuted, s.startMuted)
        set(\.maxQuality, s.maxQuality)
        set(\.historyEnabled, s.historyEnabled)
        set(\.reelsSource, s.reelsSource)
        set(\.reelsAutoNext, s.reelsAutoNext)
        set(\.hideSeen, s.hideSeen)
        set(\.slideshowSeconds, s.slideshowSeconds)
        set(\.slideshowRandom, s.slideshowRandom)
        set(\.vaultDownloads, s.vaultDownloads)
        set(\.privateMode, s.privateMode)
        set(\.offlineFavorites, s.offlineFavorites)
        set(\.hideDuplicates, s.hideDuplicates)
        set(\.smartMix, s.smartMix)
        set(\.notifyNew, s.notifyNew)
        set(\.notifyDiscreet, s.notifyDiscreet)
        set(\.hideInSwitcher, s.hideInSwitcher)
        set(\.lockOnBackground, s.lockOnBackground)
    }
}

// MARK: - Sealing with the sync key

/// The vault's own format (1 MB pieces, each AES-GCM sealed and length-prefixed), but with the sync
/// key, so another device with the same passphrase can open it.
enum SyncSeal {
    static func seal(_ plain: Data, key: SymmetricKey) throws -> Data {
        var out = Data()
        var i = 0
        while i < plain.count {
            let end = min(i + Vault.chunk, plain.count)
            guard let combined = try AES.GCM.seal(plain[i..<end], using: key).combined else { throw CocoaError(.fileWriteUnknown) }
            var len = UInt32(combined.count).bigEndian
            out.append(Data(bytes: &len, count: 4))
            out.append(combined)
            i = end
        }
        return out
    }

    static func open(_ sealed: Data, key: SymmetricKey) throws -> Data {
        var out = Data()
        var i = sealed.startIndex
        while i + 4 <= sealed.endIndex {
            let len = sealed[i..<i + 4].reduce(0) { ($0 << 8) | Int($1) }
            i += 4
            guard i + len <= sealed.endIndex else { throw CocoaError(.fileReadCorruptFile) }
            out.append(try AES.GCM.open(AES.GCM.SealedBox(combined: sealed[i..<i + len]), using: key))
            i += len
        }
        return out
    }
}
