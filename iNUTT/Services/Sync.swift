import CommonCrypto
import CryptoKit
import Foundation
import UIKit

/// Favorites, collections and Watch later stay the same on all your devices through one file in a folder
/// you pick (iCloud Drive, or Google Drive through the Files app). The file is encrypted with your sync
/// passphrase, so the cloud only ever sees noise. The same file works with iNUTT on Android and Windows.
@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()
    static let fileName = "iNUTT-sync.inutt"

    @Published private(set) var folderName: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var status: String?
    @Published private(set) var syncing = false

    private let d = UserDefaults.standard
    private var keyCache: (salt: Data, pass: String, key: SymmetricKey)?
    private var lastRun = Date.distantPast

    struct Collection: Codable { var name: String; var items: [Backup.Item] }

    struct Payload: Codable {
        var app = "iNUTT-sync"
        var version = 1
        var device: String
        var updatedAt: String
        var favorites: [Backup.Item]
        var watchLater: [Backup.Item]
        var collections: [Collection]
    }

    struct Envelope: Codable {
        var app = "iNUTT-sync"
        var v = 1
        var salt: String
        var nonce: String
        var data: String
    }

    enum SyncError: LocalizedError {
        case noFolder, noPassphrase, wrongPassphrase, unreadable
        var errorDescription: String? {
            switch self {
            case .noFolder: return "Pick a sync folder first."
            case .noPassphrase: return "Set a sync passphrase first."
            case .wrongPassphrase: return "The passphrase doesn't match the one used on your other device."
            case .unreadable: return "The sync file can't be read."
            }
        }
    }

    private init() {
        folderName = d.string(forKey: "syncFolderName")
        lastSync = d.object(forKey: "syncLast") as? Date
    }

    var isConfigured: Bool { d.data(forKey: "syncFolder") != nil && hasPassphrase }
    var hasPassphrase: Bool { !(Keychain.get("syncPassphrase") ?? "").isEmpty }

    func setPassphrase(_ p: String) {
        let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(t.isEmpty ? nil : t, for: "syncPassphrase")
        keyCache = nil
        objectWillChange.send()
    }

    /// Remembers the folder picked in Files; access to it survives restarts through a bookmark.
    func setFolder(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData() else {
            status = "That folder can't be used for sync."
            return
        }
        d.set(data, forKey: "syncFolder")
        d.set(url.lastPathComponent, forKey: "syncFolderName")
        folderName = url.lastPathComponent
        d.removeObject(forKey: "syncBase")
        status = nil
    }

    func stop() {
        d.removeObject(forKey: "syncFolder")
        d.removeObject(forKey: "syncFolderName")
        d.removeObject(forKey: "syncBase")
        folderName = nil
        status = nil
    }

    /// Runs on launch and when the app opens or leaves; at most once every half minute unless asked.
    func syncIfNeeded() {
        guard isConfigured, Date().timeIntervalSince(lastRun) > 30 else { return }
        Task { await sync() }
    }

    func syncInBackground() {
        guard isConfigured else { return }
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task) }
        Task {
            await sync()
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    func sync() async {
        guard isConfigured, !syncing else { return }
        syncing = true
        lastRun = Date()
        defer { syncing = false }
        do {
            try await run()
            lastSync = Date()
            d.set(lastSync, forKey: "syncLast")
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: Merge

    /// One entry per thing that can be on a list: favorites, Watch later, each collection and its items.
    private static func keys(favorites: [MediaItem], later: [MediaItem], collections: [MediaCollection]) -> Set<String> {
        var k = Set<String>()
        for i in favorites { k.insert("f:" + i.id) }
        for i in later { k.insert("w:" + i.id) }
        for c in collections {
            let n = c.name.lowercased()
            k.insert("C:" + n)
            for i in c.items { k.insert("c:" + n + "\u{1}" + i.id) }
        }
        return k
    }

    private func run() async throws {
        guard let bookmark = d.data(forKey: "syncFolder") else { throw SyncError.noFolder }
        guard let pass = Keychain.get("syncPassphrase"), !pass.isEmpty else { throw SyncError.noPassphrase }

        let raw = try await Task.detached { try Self.readFile(bookmark) }.value
        var remote: Payload?
        var salt = Data()
        if let raw {
            guard let env = try? JSONDecoder().decode(Envelope.self, from: raw),
                  let s = Data(base64Encoded: env.salt), let n = Data(base64Encoded: env.nonce),
                  let c = Data(base64Encoded: env.data), c.count > 16 else { throw SyncError.unreadable }
            salt = s
            let key = await key(pass, salt: s)
            guard let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: n), ciphertext: c.dropLast(16), tag: c.suffix(16)),
                  let plain = try? AES.GCM.open(box, using: key) else { throw SyncError.wrongPassphrase }
            guard let p = try? JSONDecoder().decode(Payload.self, from: plain) else { throw SyncError.unreadable }
            remote = p
        } else {
            salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        }

        let lib = Library.shared, later = WatchLater.shared, cols = CollectionStore.shared
        let rFav = (remote?.favorites ?? []).compactMap(Backup.unpack)
        let rLater = (remote?.watchLater ?? []).compactMap(Backup.unpack)
        let rCols = (remote?.collections ?? []).map { MediaCollection(name: $0.name, items: $0.items.compactMap(Backup.unpack)) }

        let local = Self.keys(favorites: lib.favorites, later: later.items, collections: cols.collections)
        let theirs = Self.keys(favorites: rFav, later: rLater, collections: rCols)
        let base = Set(d.stringArray(forKey: "syncBase") ?? [])
        // Three-way merge: kept on both, or newly added on either side since the last sync.
        // Something removed on one side since then is removed everywhere.
        let merged = local.intersection(theirs).union(local.subtracting(base)).union(theirs.subtracting(base))

        func list(_ mine: [MediaItem], _ other: [MediaItem], prefix: String) -> [MediaItem] {
            let have = Set(mine.map(\.id))
            let added = other.filter { !have.contains($0.id) && merged.contains(prefix + $0.id) }
            return added + mine.filter { merged.contains(prefix + $0.id) }
        }
        let newFav = list(lib.favorites, rFav, prefix: "f:")
        let newLater = list(later.items, rLater, prefix: "w:")
        var newCols: [MediaCollection] = []
        for c in cols.collections where merged.contains("C:" + c.name.lowercased()) {
            let n = c.name.lowercased()
            var copy = c
            let other = rCols.first { $0.name.lowercased() == n }?.items ?? []
            copy.items = list(c.items, other, prefix: "c:" + n + "\u{1}")
            newCols.append(copy)
        }
        for r in rCols where merged.contains("C:" + r.name.lowercased())
            && !newCols.contains(where: { $0.name.lowercased() == r.name.lowercased() }) {
            var copy = r
            copy.items = r.items.filter { merged.contains("c:" + r.name.lowercased() + "\u{1}" + $0.id) }
            newCols.append(copy)
        }

        lib.replaceFavorites(newFav)
        later.replaceAll(newLater)
        cols.replaceAll(newCols)

        let state = Self.keys(favorites: newFav, later: newLater, collections: newCols)
        if state != theirs || remote == nil {
            let payload = Payload(device: UIDevice.current.name, updatedAt: ISO8601DateFormatter().string(from: Date()),
                                  favorites: newFav.map { Backup.pack($0, withID: true) },
                                  watchLater: newLater.map { Backup.pack($0, withID: true) },
                                  collections: newCols.map { Collection(name: $0.name, items: $0.items.map { Backup.pack($0, withID: true) }) })
            let key = await key(pass, salt: salt)
            let box = try AES.GCM.seal(try JSONEncoder().encode(payload), using: key)
            let env = Envelope(salt: salt.base64EncodedString(), nonce: Data(box.nonce).base64EncodedString(),
                               data: (box.ciphertext + box.tag).base64EncodedString())
            let out = try JSONEncoder().encode(env)
            try await Task.detached { try Self.writeFile(bookmark, data: out) }.value
        }
        d.set(Array(state), forKey: "syncBase")
    }

    // MARK: Key and files

    /// PBKDF2-SHA256, the same on every platform; worked out once per launch.
    private func key(_ pass: String, salt: Data) async -> SymmetricKey {
        if let c = keyCache, c.salt == salt, c.pass == pass { return c.key }
        let k = await Task.detached { Self.derive(pass, salt: salt) }.value
        keyCache = (salt, pass, k)
        return k
    }

    nonisolated static func derive(_ pass: String, salt: Data) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(pass.utf8)
        _ = salt.withUnsafeBytes { s in
            pw.withUnsafeBufferPointer { p in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     UnsafeRawPointer(p.baseAddress!).assumingMemoryBound(to: Int8.self), pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 100_000, &out, 32)
            }
        }
        return SymmetricKey(data: out)
    }

    private nonisolated static func folder(_ bookmark: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
    }

    nonisolated static func readFile(_ bookmark: Data) throws -> Data? {
        let dir = try folder(bookmark)
        let ok = dir.startAccessingSecurityScopedResource()
        defer { if ok { dir.stopAccessingSecurityScopedResource() } }
        let file = dir.appendingPathComponent(fileName)
        // A file the cloud has not downloaded yet is fetched first.
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        var result: Data?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordError) { u in
            result = try? Data(contentsOf: u)
        }
        return result
    }

    nonisolated static func writeFile(_ bookmark: Data, data: Data) throws {
        let dir = try folder(bookmark)
        let ok = dir.startAccessingSecurityScopedResource()
        defer { if ok { dir.stopAccessingSecurityScopedResource() } }
        let file = dir.appendingPathComponent(fileName)
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordError) { u in
            do { try data.write(to: u, options: .atomic) } catch { writeError = error }
        }
        if let e = coordError ?? writeError { throw e }
    }
}
