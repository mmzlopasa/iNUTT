import Foundation
import CryptoKit

struct VaultEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var siteName: String
    var kind: MediaKind
    var ext: String
    var size: Int64
    var thumbnailURL: URL?
    var addedAt = Date()
    /// The same file's name on every device, set when it came from another device through sync.
    var syncID: String?

    var syncKey: String { syncID ?? id.uuidString }
}

/// Downloads kept inside the app, encrypted with a key that never leaves this device's keychain.
/// Nothing in here shows up in Photos or the Files app.
@MainActor
final class Vault: ObservableObject {
    static let shared = Vault()
    @Published private(set) var entries: [VaultEntry] = []

    /// Files are sealed in 1 MB pieces so big videos never have to fit in memory at once.
    nonisolated static let chunk = 1 << 20

    nonisolated static let dir: URL = {
        let d = Disk.dir.appendingPathComponent("Vault", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = d
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? v.setResourceValues(rv)
        return d
    }()

    private static let openDir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("vault-open", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private init() { entries = Disk.load([VaultEntry].self, "vault.json") ?? [] }

    nonisolated private static var key: SymmetricKey {
        if let s = Keychain.get("vaultKey"), let d = Data(base64Encoded: s) { return SymmetricKey(data: d) }
        let k = SymmetricKey(size: .bits256)
        Keychain.set(k.withUnsafeBytes { Data($0) }.base64EncodedString(), for: "vaultKey")
        return k
    }

    var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }

    /// Encrypts a downloaded file into the vault and deletes the plain copy.
    func add(file: URL, item: MediaItem, kind: MediaKind, ext: String) async throws {
        var entry = VaultEntry(title: item.displayTitle, siteName: item.siteName, kind: kind, ext: ext, size: 0,
                               thumbnailURL: item.thumbnailURL)
        let dest = Self.dir.appendingPathComponent(entry.id.uuidString)
        entry.size = try await Task.detached(priority: .utility) {
            defer { try? FileManager.default.removeItem(at: file) }
            return try Self.seal(file, to: dest)
        }.value
        entries.insert(entry, at: 0)
        save()
    }

    /// A plain copy to show or play. Removed when the vault closes or the app goes to the background.
    func open(_ e: VaultEntry) async throws -> URL {
        let src = Self.dir.appendingPathComponent(e.id.uuidString)
        let out = Self.openDir.appendingPathComponent(e.id.uuidString).appendingPathExtension(e.ext)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try await Task.detached(priority: .userInitiated) { try Self.unseal(src, to: out) }.value
        return out
    }

    /// Used by sync: a file that came from another device, already decrypted to `file`.
    func add(file: URL, entry: VaultEntry) async throws {
        var e = entry
        let dest = Self.dir.appendingPathComponent(e.id.uuidString)
        e.size = try await Task.detached(priority: .utility) {
            defer { try? FileManager.default.removeItem(at: file) }
            return try Self.seal(file, to: dest)
        }.value
        entries.append(e)
        entries.sort { $0.addedAt > $1.addedAt }
        save()
    }

    func delete(_ e: VaultEntry) {
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(e.id.uuidString))
        entries.removeAll { $0.id == e.id }
        save()
    }

    /// Removes every plain copy made for viewing.
    func closeOpenFiles() {
        try? FileManager.default.removeItem(at: Self.openDir)
        try? FileManager.default.createDirectory(at: Self.openDir, withIntermediateDirectories: true)
    }

    private func save() { Disk.save(entries, "vault.json") }

    // MARK: Crypto

    nonisolated private static func seal(_ src: URL, to dest: URL) throws -> Int64 {
        let k = key
        guard let input = InputStream(url: src) else { throw CocoaError(.fileReadNoSuchFile) }
        input.open()
        defer { input.close() }
        FileManager.default.createFile(atPath: dest.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        var buf = [UInt8](repeating: 0, count: chunk)
        var total: Int64 = 0
        while true {
            let n = input.read(&buf, maxLength: chunk)
            if n < 0 { throw input.streamError ?? CocoaError(.fileReadUnknown) }
            if n == 0 { break }
            let box = try AES.GCM.seal(Data(buf[0..<n]), using: k)
            guard let combined = box.combined else { throw CocoaError(.fileWriteUnknown) }
            var len = UInt32(combined.count).bigEndian
            out.write(Data(bytes: &len, count: 4))
            out.write(combined)
            total += Int64(n)
        }
        return total
    }

    nonisolated private static func unseal(_ src: URL, to dest: URL) throws {
        let k = key
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: dest.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        while let head = try input.read(upToCount: 4), head.count == 4 {
            let len = head.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard let body = try input.read(upToCount: len), body.count == len else { throw CocoaError(.fileReadCorruptFile) }
            out.write(try AES.GCM.open(AES.GCM.SealedBox(combined: body), using: k))
        }
    }
}
