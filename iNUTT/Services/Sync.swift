import CommonCrypto
import CryptoKit
import Combine
import Foundation
import UIKit

/// Everything in the app (sites, forums, favorites, collections, Watch later, history, searches, blocked
/// words, resume points, taste, settings and, on GitHub, the vault) stays the same on all your
/// devices through one encrypted file: in a private GitHub repository, or in a folder you pick
/// (iCloud Drive, or Google Drive through the Files app). The file is encrypted with your sync
/// passphrase, so GitHub or the cloud only ever sees noise. The same file works with iNUTT on Android
/// and Windows. Changes are sent a moment after you make them, and other devices' changes are checked
/// for while the app is open.
@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()
    static let fileName = "iNUTT-sync.inutt"

    @Published private(set) var folderName: String?
    @Published private(set) var githubRepo: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var status: String?
    @Published private(set) var syncing = false
    /// What a long sync is doing, e.g. moving vault files.
    @Published private(set) var progress: String?
    private var scheduled: Task<Void, Never>?
    private var scheduledAt = Date.distantFuture

    private let d = UserDefaults.standard
    private var keyCache: (salt: Data, pass: String, key: SymmetricKey)?
    private var lastRun = Date.distantPast
    private var again = false
    /// True while a sync writes merged lists back, so those writes don't start another sync.
    private var applying = false
    private var subs: Set<AnyCancellable> = []
    /// The GitHub file as last read, so an unchanged file is answered by GitHub with "not modified".
    private var remoteCache: (etag: String, data: Data?, sha: String?)?

    struct Collection: Codable { var name: String; var items: [Backup.Item] }
    struct SyncSite: Codable { var name: String; var url: URL; var searchTemplate: String?; var renderMode: String?; var enabled: Bool? }
    struct SyncForum: Codable { var name: String; var url: URL }

    struct Payload: Codable {
        var app = "iNUTT-sync"
        var version = 1
        var device: String
        var updatedAt: String
        var favorites: [Backup.Item]
        var watchLater: [Backup.Item]
        var collections: [Collection]
        // Older files don't have these.
        var sites: [SyncSite]?
        var forums: [SyncForum]?
        var history: [SyncHistory]?
        var searches: [String]?
        var blocked: [String]?
        var resume: [SyncResume]?
        var taste: SyncTaste?
        var settings: SyncSettings?
        var vault: [SyncVault]?
    }

    struct Envelope: Codable {
        var app = "iNUTT-sync"
        var v = 1
        var salt: String
        var nonce: String
        var data: String
    }

    enum SyncError: LocalizedError {
        case noPlace, noPassphrase, wrongPassphrase, unreadable, conflict, github(String)
        var errorDescription: String? {
            switch self {
            case .noPlace: return "Connect GitHub or pick a sync folder first."
            case .noPassphrase: return "Set a sync passphrase first."
            case .wrongPassphrase: return "The passphrase doesn't match the one used on your other device."
            case .unreadable: return "The sync file can't be read."
            case .conflict: return "Another device saved at the same moment; try again."
            case .github(let m): return m
            }
        }
    }

    private init() {
        folderName = d.string(forKey: "syncFolderName")
        githubRepo = d.string(forKey: "syncGitHubRepo")
        lastSync = d.object(forKey: "syncLast") as? Date
        watchChanges()
        // Other devices' changes arrive while the app is open, too.
        Timer.publish(every: 45, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard UIApplication.shared.applicationState == .active else { return }
                self?.syncIfNeeded()
            }
            .store(in: &subs)
    }

    private var githubToken: String? { Keychain.get("syncGitHubToken").flatMap { $0.isEmpty ? nil : $0 } }
    private var hasPlace: Bool { d.data(forKey: "syncFolder") != nil || (githubRepo != nil && githubToken != nil) }
    var isConfigured: Bool { hasPlace && hasPassphrase }
    var hasPassphrase: Bool { !(Keychain.get("syncPassphrase") ?? "").isEmpty }
    /// Where the file is kept, for the settings screen.
    var placeName: String? { githubRepo.map { "GitHub · " + $0 } ?? folderName }

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
        clearGitHub()
        d.set(data, forKey: "syncFolder")
        d.set(url.lastPathComponent, forKey: "syncFolderName")
        folderName = url.lastPathComponent
        d.removeObject(forKey: "syncBase")
        status = nil
    }

    /// Checks the token and repository, then keeps the file there. Returns an error to show, or nil.
    func connectGitHub(repo raw: String, token rawToken: String) async -> String? {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let repo = Self.repoName(raw) else { return "Write the repository as owner/name." }
        guard !token.isEmpty else { return "Paste a GitHub token." }
        var req = Self.github("repos/" + repo, token: token)
        req.httpMethod = "GET"
        guard let answer = try? await URLSession.shared.data(for: req), let http = answer.1 as? HTTPURLResponse else {
            return "GitHub can't be reached right now."
        }
        let data = answer.0
        switch http.statusCode {
        case 200: break
        case 401: return "GitHub refused the token."
        case 403, 404: return "The repository wasn't found, or the token has no access to it."
        default: return "GitHub answered \(http.statusCode)."
        }
        let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if info?["private"] as? Bool == false { return "That repository is public. Use a private one." }
        if let perms = info?["permissions"] as? [String: Any], perms["push"] as? Bool == false {
            return "The token can read the repository but not save to it."
        }
        d.removeObject(forKey: "syncFolder")
        d.removeObject(forKey: "syncFolderName")
        folderName = nil
        Keychain.set(token, for: "syncGitHubToken")
        d.set(repo, forKey: "syncGitHubRepo")
        githubRepo = repo
        d.removeObject(forKey: "syncBase")
        remoteCache = nil
        status = nil
        return nil
    }

    /// "owner/name", from that or from a github.com link.
    static func repoName(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://", "www.", "github.com/"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        return parts[0] + "/" + parts[1]
    }

    private func clearGitHub() {
        Keychain.set(nil, for: "syncGitHubToken")
        d.removeObject(forKey: "syncGitHubRepo")
        githubRepo = nil
        remoteCache = nil
    }

    func stop() {
        d.removeObject(forKey: "syncFolder")
        d.removeObject(forKey: "syncFolderName")
        d.removeObject(forKey: "syncBase")
        clearGitHub()
        folderName = nil
        status = nil
    }

    /// Runs on launch, when the app opens or leaves and every 45 s while open; at most once every half minute.
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
        guard isConfigured else { return }
        guard !syncing else {
            again = true
            return
        }
        syncing = true
        lastRun = Date()
        do {
            do {
                try await run()
            } catch SyncError.conflict {
                // Another device saved in between: read its version and merge again.
                remoteCache = nil
                try await run()
            }
            lastSync = Date()
            d.set(lastSync, forKey: "syncLast")
            status = nil
        } catch {
            status = error.localizedDescription
        }
        syncing = false
        if again {
            again = false
            Task { await sync() }
        }
    }

    /// Something you added or removed goes out a moment later, without waiting for the next check.
    /// History and resume points change on every video, so those wait half a minute and go together.
    private func watchChanges() {
        let stores: [AnyPublisher<Void, Never>] = [
            Library.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            WatchLater.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            CollectionStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SiteStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            ForumStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            ResumeStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            Vault.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(stores)
            .filter { [weak self] in self?.applying == false }
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.isConfigured else { return }
                let base = Set(self.d.stringArray(forKey: "syncBase") ?? [])
                let changed = self.localKeys().symmetricDifference(base)
                let settingsChanged = self.settingsSnapshot.map { $0 != AppSettings.shared.syncValues } ?? false
                guard !changed.isEmpty || settingsChanged else { return }
                let minor = !settingsChanged && changed.allSatisfy { $0.hasPrefix("h:") || $0.hasPrefix("p:") }
                self.schedule(after: minor ? 30 : 1.5)
            }
            .store(in: &subs)
    }

    /// Runs a sync after `seconds`, unless one is already due sooner.
    private func schedule(after seconds: Double) {
        let at = Date().addingTimeInterval(seconds)
        guard scheduled == nil || at < scheduledAt else { return }
        scheduled?.cancel()
        scheduledAt = at
        scheduled = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.scheduled = nil
            self.scheduledAt = .distantFuture
            await self.sync()
        }
    }

    private var settingsSnapshot: SyncSettings? {
        d.data(forKey: "syncSettings").flatMap { try? JSONDecoder().decode(SyncSettings.self, from: $0) }
    }

    /// Vault files travel only through GitHub; a folder sync leaves the vault on each device.
    private var syncsVault: Bool { githubRepo != nil }

    // MARK: Merge

    private func localKeys() -> Set<String> {
        var k = Self.keys(favorites: Library.shared.favorites, later: WatchLater.shared.items, collections: CollectionStore.shared.collections,
                          sites: SiteStore.shared.sites.map(\.url), forums: ForumStore.shared.forums.map(\.url))
        k.formUnion(Self.extraKeys(history: Library.shared.history.prefix(Self.historyLimit).map(\.item.id),
                                   searches: AppSettings.shared.recentSearches, blocked: AppSettings.shared.blockedWords,
                                   resume: Array(ResumeStore.shared.points.keys),
                                   vault: syncsVault ? Vault.shared.entries.map(\.syncKey) : []))
        return k
    }

    private static func extraKeys(history: [String], searches: [String], blocked: [String], resume: [String], vault: [String]) -> Set<String> {
        var k = Set<String>()
        for i in history { k.insert("h:" + i) }
        for q in searches { k.insert("q:" + q.lowercased()) }
        for w in blocked { k.insert("b:" + w.lowercased()) }
        for i in resume { k.insert("p:" + i) }
        for v in vault { k.insert("v:" + v) }
        return k
    }

    /// One entry per thing that can be on a list: sites, forums, favorites, Watch later, each collection and its items.
    private static func keys(favorites: [MediaItem], later: [MediaItem], collections: [MediaCollection],
                             sites: [URL], forums: [URL]) -> Set<String> {
        var k = Set<String>()
        for i in favorites { k.insert("f:" + i.id) }
        for i in later { k.insert("w:" + i.id) }
        for c in collections {
            let n = c.name.lowercased()
            k.insert("C:" + n)
            for i in c.items { k.insert("c:" + n + "\u{1}" + i.id) }
        }
        for u in sites { k.insert("s:" + u.matchKey) }
        for u in forums { k.insert("F:" + u.matchKey) }
        return k
    }

    private func run() async throws {
        guard let pass = Keychain.get("syncPassphrase"), !pass.isEmpty else { throw SyncError.noPassphrase }
        let remoteFile = try await read()
        var remote: Payload?
        var salt = Data()
        if let raw = remoteFile.data {
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
        let siteStore = SiteStore.shared, forumStore = ForumStore.shared
        let rFav = (remote?.favorites ?? []).compactMap(Backup.unpack)
        let rLater = (remote?.watchLater ?? []).compactMap(Backup.unpack)
        let rCols = (remote?.collections ?? []).map { MediaCollection(name: $0.name, items: $0.items.compactMap(Backup.unpack)) }
        let rSites = remote?.sites ?? []
        let rForums = remote?.forums ?? []
        let rHistory: [HistoryEntry] = (remote?.history ?? []).compactMap { h in
            Backup.unpack(h.item).map { HistoryEntry(item: $0, viewedAt: Self.date(h.at)) }
        }
        let rResume: [String: ResumePoint] = Dictionary((remote?.resume ?? []).compactMap { r in
            Backup.unpack(r.item).map { ($0.id, ResumePoint(item: $0, seconds: r.seconds, duration: r.duration, updatedAt: Self.date(r.at))) }
        }, uniquingKeysWith: { a, b in a.updatedAt > b.updatedAt ? a : b })
        let rSearches = remote?.searches ?? []
        let rBlocked = remote?.blocked ?? []
        let rVault = remote?.vault ?? []

        let local = localKeys()
        var theirs = Self.keys(favorites: rFav, later: rLater, collections: rCols, sites: rSites.map(\.url), forums: rForums.map(\.url))
        theirs.formUnion(Self.extraKeys(history: rHistory.map(\.item.id), searches: rSearches, blocked: rBlocked,
                                        resume: Array(rResume.keys), vault: syncsVault ? rVault.map(\.id) : []))
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
        // Sites and forums: yours keep their settings and order; ones added elsewhere come after them.
        var newSites = siteStore.sites.filter { merged.contains("s:" + $0.url.matchKey) }
        for r in rSites where merged.contains("s:" + r.url.matchKey) && !newSites.contains(where: { $0.url.matchKey == r.url.matchKey }) {
            newSites.append(Site(name: r.name, url: r.url, searchTemplate: r.searchTemplate,
                                 renderMode: r.renderMode.flatMap(RenderMode.init(rawValue:)) ?? .auto, enabled: r.enabled ?? true))
        }
        var newForums = forumStore.forums.filter { merged.contains("F:" + $0.url.matchKey) }
        for r in rForums where merged.contains("F:" + r.url.matchKey) && !newForums.contains(where: { $0.url.matchKey == r.url.matchKey }) {
            newForums.append(Forum(name: r.name, url: r.url))
        }
        let addedSites = newSites.filter { s in !siteStore.sites.contains { $0.id == s.id } }

        // History: newest view of each item wins; entries past what travels stay as they are.
        let settings = AppSettings.shared
        var views: [String: HistoryEntry] = [:]
        for h in lib.history.prefix(Self.historyLimit) + rHistory where merged.contains("h:" + h.item.id) {
            if let old = views[h.item.id], old.viewedAt >= h.viewedAt { continue }
            views[h.item.id] = h
        }
        let top = views.values.sorted { $0.viewedAt > $1.viewedAt }
        let topIDs = Set(top.map(\.item.id))
        let older = lib.history.dropFirst(Self.historyLimit).filter { !topIDs.contains($0.item.id) }
        let newHistory = Array((top + older).prefix(Limits.maxHistory))

        func words(_ mine: [String], _ other: [String], prefix: String) -> [String] {
            var seen = Set<String>()
            return (mine + other).filter { merged.contains(prefix + $0.lowercased()) && seen.insert($0.lowercased()).inserted }
        }
        let newSearches = Array(words(settings.recentSearches, rSearches, prefix: "q:").prefix(Self.searchLimit))
        let newBlocked = words(settings.blockedWords, rBlocked, prefix: "b:")

        var newResume: [String: ResumePoint] = [:]
        for (id, p) in ResumeStore.shared.points.merging(rResume, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
            where merged.contains("p:" + id) {
            newResume[id] = p
        }

        // Taste: the stronger of the two for each thing learned.
        let taste = Taste.shared
        let rTaste = remote?.taste
        let newTaste = SyncTaste(weights: taste.weights.merging(rTaste?.weights ?? [:]) { max($0, $1) },
                                 signals: max(taste.signals, rTaste?.signals ?? 0))

        // Settings: whichever device changed them last.
        let mine = settings.syncValues
        let snapshot = settingsSnapshot
        let lastAt = d.double(forKey: "syncSettingsAt")
        var newSettings: SyncSettings
        var adopt = false
        if let r = remote?.settings, let at = r.at, snapshot == nil || (mine == snapshot && at > lastAt) {
            newSettings = r
            adopt = true
        } else if snapshot == nil || mine != snapshot || remote?.settings == nil {
            newSettings = mine
            newSettings.at = Self.ms(Date())
        } else {
            newSettings = remote?.settings ?? mine
        }

        // Vault: files added here go up before the list says they exist; files from elsewhere come down after.
        var newVault: [SyncVault] = rVault
        var vaultDownloads: [SyncVault] = []
        if syncsVault, let repo = githubRepo, let token = githubToken {
            let key = await key(pass, salt: salt)
            let have = Set(rVault.map(\.id))
            newVault = rVault.filter { merged.contains("v:" + $0.id) }
            for gone in rVault where !merged.contains("v:" + gone.id) {
                await deleteVaultFiles(gone.id, repo: repo, token: token)
            }
            let uploads = Vault.shared.entries.filter { merged.contains("v:" + $0.syncKey) && !have.contains($0.syncKey) }
            for (n, e) in uploads.enumerated() {
                progress = "Uploading vault \(n + 1) of \(uploads.count)…"
                if let v = try? await uploadVault(e, key: key, repo: repo, token: token) { newVault.append(v) }
            }
            progress = nil
            let local = Set(Vault.shared.entries.map(\.syncKey))
            vaultDownloads = newVault.filter { !local.contains($0.id) }
        }

        applying = true
        lib.replaceFavorites(newFav)
        later.replaceAll(newLater)
        cols.replaceAll(newCols)
        siteStore.replaceAll(newSites)
        forumStore.replaceAll(newForums)
        lib.replaceHistory(newHistory)
        if newSearches != settings.recentSearches { settings.recentSearches = newSearches }
        if newBlocked != settings.blockedWords { settings.blockedWords = newBlocked }
        ResumeStore.shared.replaceAll(newResume)
        taste.replace(weights: newTaste.weights, signals: newTaste.signals)
        if adopt { settings.apply(newSettings) }
        if syncsVault {
            for e in Vault.shared.entries where !merged.contains("v:" + e.syncKey) { Vault.shared.delete(e) }
        }
        if let data = try? JSONEncoder().encode(newSettings.withoutTime) { d.set(data, forKey: "syncSettings") }
        d.set(newSettings.at ?? 0, forKey: "syncSettingsAt")
        applying = false
        if !addedSites.isEmpty {
            Task { for s in addedSites { await FeedEngine.shared.refreshForHome(s, allowRender: true) } }
        }

        var state = Self.keys(favorites: newFav, later: newLater, collections: newCols,
                              sites: newSites.map(\.url), forums: newForums.map(\.url))
        let syncedHistory = newHistory.prefix(Self.historyLimit)
        state.formUnion(Self.extraKeys(history: syncedHistory.map(\.item.id), searches: newSearches, blocked: newBlocked,
                                       resume: Array(newResume.keys), vault: syncsVault ? newVault.map(\.id) : []))
        // Also written when only an order, a position or a value changed.
        let historyMoved = syncedHistory.prefix(20).map { "\($0.item.id)@\(Self.ms($0.viewedAt))" }
            != rHistory.prefix(20).map { "\($0.item.id)@\(Self.ms($0.viewedAt))" }
        let resumeMoved = newResume.mapValues { Self.ms($0.updatedAt) } != rResume.mapValues { Self.ms($0.updatedAt) }
        let other = historyMoved || resumeMoved || newTaste != rTaste || newSettings != remote?.settings || newVault != rVault
        if state != theirs || remote == nil || other {
            let payload = Payload(device: UIDevice.current.name, updatedAt: ISO8601DateFormatter().string(from: Date()),
                                  favorites: newFav.map { Backup.pack($0, withID: true) },
                                  watchLater: newLater.map { Backup.pack($0, withID: true) },
                                  collections: newCols.map { Collection(name: $0.name, items: $0.items.map { Backup.pack($0, withID: true) }) },
                                  sites: newSites.map { SyncSite(name: $0.name, url: $0.url, searchTemplate: $0.searchTemplate,
                                                                 renderMode: $0.renderMode.rawValue, enabled: $0.enabled) },
                                  forums: newForums.map { SyncForum(name: $0.name, url: $0.url) },
                                  history: syncedHistory.map { SyncHistory(item: Backup.pack($0.item, withID: true), at: Self.ms($0.viewedAt)) },
                                  searches: newSearches, blocked: newBlocked,
                                  resume: newResume.values.map { SyncResume(item: Backup.pack($0.item, withID: true), seconds: $0.seconds,
                                                                            duration: $0.duration, at: Self.ms($0.updatedAt)) },
                                  taste: newTaste, settings: newSettings, vault: newVault)
            let key = await key(pass, salt: salt)
            let box = try AES.GCM.seal(try JSONEncoder().encode(payload), using: key)
            let env = Envelope(salt: salt.base64EncodedString(), nonce: Data(box.nonce).base64EncodedString(),
                               data: (box.ciphertext + box.tag).base64EncodedString())
            try await write(try JSONEncoder().encode(env), over: remoteFile.version)
        }
        d.set(Array(state), forKey: "syncBase")

        if !vaultDownloads.isEmpty, let repo = githubRepo, let token = githubToken {
            let key = await key(pass, salt: salt)
            var failed: [String] = []
            for (n, v) in vaultDownloads.enumerated() {
                progress = "Downloading vault \(n + 1) of \(vaultDownloads.count)…"
                do { try await downloadVault(v, key: key, repo: repo, token: token) } catch { failed.append("v:" + v.id) }
            }
            progress = nil
            // A file that didn't come down is fetched next time, not taken as removed here.
            if !failed.isEmpty { d.set(Array(state.subtracting(failed)), forKey: "syncBase") }
        }
    }

    // MARK: Vault files on GitHub

    private func uploadVault(_ e: VaultEntry, key: SymmetricKey, repo: String, token: String) async throws -> SyncVault {
        let plain = try await Vault.shared.open(e)
        let handle = try FileHandle(forReadingFrom: plain)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: plain)
        }
        var part = 0
        while true {
            let piece = try handle.read(upToCount: Self.vaultPart) ?? Data()
            if piece.isEmpty && part > 0 { break }
            let sealed = try SyncSeal.seal(piece, key: key)
            try await putFile("vault/\(e.syncKey)/\(part)", sealed, repo: repo, token: token)
            part += 1
            if piece.count < Self.vaultPart { break }
        }
        return SyncVault(id: e.syncKey, title: e.title, siteName: e.siteName, kind: e.kind.rawValue, ext: e.ext, size: e.size,
                         thumb: e.thumbnailURL?.absoluteString, addedAt: Self.ms(e.addedAt), parts: part)
    }

    private func downloadVault(_ v: SyncVault, key: SymmetricKey, repo: String, token: String) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sync-" + v.id)
        FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        let out = try FileHandle(forWritingTo: tmp)
        do {
            for part in 0..<max(1, v.parts) {
                var req = Self.github("repos/\(repo)/contents/vault/\(v.id)/\(part)", token: token)
                req.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
                req.timeoutInterval = 120
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SyncError.unreadable }
                out.write(try SyncSeal.open(data, key: key))
            }
            try out.close()
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        let entry = VaultEntry(title: v.title, siteName: v.siteName, kind: MediaKind(rawValue: v.kind) ?? .video, ext: v.ext,
                               size: v.size, thumbnailURL: v.thumb.flatMap(URL.init(string:)), addedAt: Self.date(v.addedAt), syncID: v.id)
        try await Vault.shared.add(file: tmp, entry: entry)
    }

    private func putFile(_ path: String, _ data: Data, repo: String, token: String) async throws {
        var req = Self.github("repos/\(repo)/contents/\(path)", token: token)
        req.httpMethod = "PUT"
        req.timeoutInterval = 300
        var body: [String: Any] = ["message": "iNUTT vault", "content": data.base64EncodedString()]
        // A part left by an upload that was cut off is replaced.
        var head = Self.github("repos/\(repo)/contents/\(path)", token: token)
        head.httpMethod = "GET"
        if let found = try? await URLSession.shared.data(for: head), (found.1 as? HTTPURLResponse)?.statusCode == 200,
           let sha = (try? JSONSerialization.jsonObject(with: found.0) as? [String: Any])?["sha"] as? String {
            body["sha"] = sha
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard [200, 201].contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else { throw SyncError.github("A vault file couldn't be saved to GitHub.") }
    }

    private func deleteVaultFiles(_ id: String, repo: String, token: String) async {
        let list = Self.github("repos/\(repo)/contents/vault/\(id)", token: token)
        guard let answer = try? await URLSession.shared.data(for: list), (answer.1 as? HTTPURLResponse)?.statusCode == 200,
              let files = (try? JSONSerialization.jsonObject(with: answer.0)) as? [[String: Any]] else { return }
        for f in files {
            guard let path = f["path"] as? String, let sha = f["sha"] as? String else { continue }
            var req = Self.github("repos/\(repo)/contents/" + path, token: token)
            req.httpMethod = "DELETE"
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["message": "iNUTT vault", "sha": sha])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    // MARK: Key

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

    // MARK: Where the file is kept

    /// The file's bytes (nil when there is none yet) and, on GitHub, the version to replace.
    private func read() async throws -> (data: Data?, version: String?) {
        if let repo = githubRepo, let token = githubToken {
            return try await readGitHub(repo: repo, token: token)
        }
        guard let bookmark = d.data(forKey: "syncFolder") else { throw SyncError.noPlace }
        return (try await Task.detached { try Self.readFile(bookmark) }.value, nil)
    }

    private func write(_ data: Data, over version: String?) async throws {
        if let repo = githubRepo, let token = githubToken {
            return try await writeGitHub(data, repo: repo, token: token, sha: version)
        }
        guard let bookmark = d.data(forKey: "syncFolder") else { throw SyncError.noPlace }
        try await Task.detached { try Self.writeFile(bookmark, data: data) }.value
    }

    private static func github(_ path: String, token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.github.com/" + path)!, cachePolicy: .reloadIgnoringLocalCacheData)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("iNUTT", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        return req
    }

    private func readGitHub(repo: String, token: String) async throws -> (data: Data?, version: String?) {
        var req = Self.github("repos/\(repo)/contents/\(Self.fileName)", token: token)
        if let c = remoteCache { req.setValue(c.etag, forHTTPHeaderField: "If-None-Match") }
        let (body, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 304:
            if let c = remoteCache { return (c.data, c.sha) }
            remoteCache = nil
            return try await readGitHub(repo: repo, token: token)
        case 404:
            remoteCache = nil
            return (nil, nil)
        case 401: throw SyncError.github("GitHub refused the token. Connect GitHub again in Sync.")
        case 200: break
        default: throw SyncError.github("GitHub answered \(http?.statusCode ?? 0).")
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let sha = json["sha"] as? String else {
            throw SyncError.unreadable
        }
        var data: Data?
        if let content = json["content"] as? String, !content.isEmpty {
            data = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: ""))
        } else {
            // Files over 1 MB come without their content; fetch it on its own.
            var raw = Self.github("repos/\(repo)/git/blobs/\(sha)", token: token)
            raw.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
            data = try await URLSession.shared.data(for: raw).0
        }
        guard let data else { throw SyncError.unreadable }
        if let etag = http?.value(forHTTPHeaderField: "ETag") { remoteCache = (etag, data, sha) }
        return (data, sha)
    }

    private func writeGitHub(_ data: Data, repo: String, token: String, sha: String?) async throws {
        var req = Self.github("repos/\(repo)/contents/\(Self.fileName)", token: token)
        req.httpMethod = "PUT"
        var body: [String: Any] = ["message": "iNUTT sync from \(UIDevice.current.name)", "content": data.base64EncodedString()]
        if let sha { body["sha"] = sha }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        remoteCache = nil
        switch code {
        case 200, 201: return
        case 409, 422: throw SyncError.conflict
        case 401: throw SyncError.github("GitHub refused the token. Connect GitHub again in Sync.")
        case 403, 404: throw SyncError.github("The token can't save to that repository.")
        default: throw SyncError.github("GitHub answered \(code) while saving.")
        }
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
