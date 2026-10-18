import Foundation
import Photos
import UIKit

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol: String
    var progress: Double?
    var isError = false
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published var toast: Toast?
    @Published private(set) var progress: [String: Double] = [:]

    private var hideWork: DispatchWorkItem?
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }()
    private let delegate = DownloadDelegate()

    static var downloadsFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("iNUTT Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func show(_ text: String, symbol: String, progress: Double? = nil, isError: Bool = false, autoHide: Bool = true) {
        if var t = toast, t.text == text, progress != nil {
            t.progress = progress
            toast = t
        } else {
            toast = Toast(text: text, symbol: symbol, progress: progress, isError: isError)
        }
        hideWork?.cancel()
        if autoHide {
            let w = DispatchWorkItem { [weak self] in self?.toast = nil }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: w)
        }
    }

    func download(_ item: MediaItem) async {
        Taste.shared.learn(item, .download)
        guard progress[item.id] == nil else { return }
        if await perform(item, batch: nil) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    // MARK: Download all

    /// Items still waiting to be downloaded; kept on disk so an interrupted batch carries on next time.
    @Published private(set) var queue: [MediaItem] = []
    private var queueTotal = 0
    private var queueDone = 0
    private var queueFailed = 0
    private var runningQueue = false

    func downloadAll(_ items: [MediaItem]) {
        let have = Set(queue.map(\.id))
        let add = items.filter { $0.isListing != true && !have.contains($0.id) }
        guard !add.isEmpty else { return }
        queue += add
        queueTotal += add.count
        Disk.save(queue, "downloadQueue.json")
        show("Downloading \(queueTotal) items", symbol: "arrow.down.circle.fill")
        Task { await runQueue() }
    }

    /// Picks up a batch that was interrupted when the app closed.
    func resumeQueue() {
        guard queue.isEmpty, let saved = Disk.load([MediaItem].self, "downloadQueue.json"), !saved.isEmpty else { return }
        queue = saved
        queueTotal = saved.count
        Task { await runQueue() }
    }

    func cancelQueue() {
        queue = []
        Disk.save(queue, "downloadQueue.json")
    }

    private func runQueue() async {
        guard !runningQueue else { return }
        runningQueue = true
        defer { runningQueue = false }
        while let item = queue.first {
            queueDone += 1
            if !(await perform(item, batch: (queueDone, queueTotal))) { queueFailed += 1 }
            if !queue.isEmpty { queue.removeFirst() }
            Disk.save(queue, "downloadQueue.json")
        }
        guard queueTotal > 0 else { return }
        let ok = queueDone - queueFailed
        show(queueFailed == 0 ? "Downloaded \(ok) items" : "Downloaded \(ok) of \(queueDone) items",
             symbol: queueFailed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        queueTotal = 0
        queueDone = 0
        queueFailed = 0
    }

    /// Downloads one item into Photos, Files or the vault. Returns false when it failed.
    private func perform(_ item: MediaItem, batch: (Int, Int)?) async -> Bool {
        let label = batch.map { "Downloading \($0.0) of \($0.1)…" } ?? "Downloading…"
        guard let media = await FeedEngine.shared.resolve(item) else {
            if batch == nil { show("Content not found", symbol: "exclamationmark.triangle.fill", isError: true) }
            return false
        }
        if media.url.absoluteString.contains(".m3u8") {
            if batch == nil { show("This video is a stream and can't be downloaded", symbol: "exclamationmark.triangle.fill", isError: true) }
            return false
        }
        progress[item.id] = 0
        show(label, symbol: "arrow.down.circle.fill", progress: 0, autoHide: false)
        defer { progress[item.id] = nil }

        do {
            var req = Net.request(media.url, referer: media.referer)
            req.setValue("*/*", forHTTPHeaderField: "Accept")
            let id = item.id
            let (tmp, response) = try await delegate.download(req, in: session) { p in
                Task { @MainActor in
                    self.progress[id] = p
                    self.show(label, symbol: "arrow.down.circle.fill", progress: p, autoHide: false)
                }
            }
            let ext = Self.fileExtension(for: media, response: response)
            let kind: MediaKind = media.kind == .video ? .video : (ext == "gif" ? .gif : .image)

            if AppSettings.shared.vaultDownloads {
                try await Vault.shared.add(file: tmp, item: item, kind: kind, ext: ext)
                if batch == nil { show("Saved to the vault", symbol: "lock.shield.fill") }
                return true
            }

            let base = item.title.isEmpty ? "iNUTT-\(item.id)" : String(item.title.prefix(60))
            let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            var dest = Self.downloadsFolder.appendingPathComponent(safe).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = Self.downloadsFolder.appendingPathComponent("\(safe)-\(Int(Date().timeIntervalSince1970))").appendingPathExtension(ext)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)

            if AppSettings.shared.saveToPhotos {
                try await Self.saveToPhotos(dest, kind: kind)
                if batch == nil { show("Saved to Photos", symbol: "checkmark.circle.fill") }
            } else if batch == nil {
                show("Saved to Files › iNUTT", symbol: "checkmark.circle.fill")
            }
            return true
        } catch {
            if batch == nil { show("Download failed", symbol: "xmark.octagon.fill", isError: true) }
            return false
        }
    }

    static func fileExtension(for media: ResolvedMedia, response: URLResponse?) -> String {
        let ext = media.url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "mov", "m4v", "webm"].contains(ext) { return ext }
        let mime = response?.mimeType?.lowercased() ?? ""
        if mime.contains("gif") { return "gif" }
        if mime.contains("png") { return "png" }
        if mime.contains("webp") { return "webp" }
        if mime.contains("quicktime") { return "mov" }
        if mime.contains("video") { return "mp4" }
        return media.kind == .video ? "mp4" : "jpg"
    }

    static func saveToPhotos(_ file: URL, kind: MediaKind) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CocoaError(.userCancelled) }
        var url = file
        // Photos does not accept WebP; convert it.
        if kind == .image, ["webp", "avif"].contains(file.pathExtension.lowercased()),
           let img = UIImage(contentsOfFile: file.path), let jpg = img.jpegData(compressionQuality: 0.95) {
            url = file.deletingPathExtension().appendingPathExtension("jpg")
            try jpg.write(to: url)
            try? FileManager.default.removeItem(at: file)
        }
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: kind == .video ? .video : .photo, fileURL: url, options: nil)
        }
    }
}

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        var continuation: CheckedContinuation<(URL, URLResponse?), Error>
        var onProgress: (Double) -> Void
    }
    private var pending: [Int: Pending] = [:]
    private let lock = NSLock()

    func download(_ request: URLRequest, in session: URLSession, onProgress: @escaping (Double) -> Void) async throws -> (URL, URLResponse?) {
        try await withCheckedThrowingContinuation { c in
            let task = session.downloadTask(with: request)
            lock.withLock { pending[task.taskIdentifier] = Pending(continuation: c, onProgress: onProgress) }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = lock.withLock { pending[downloadTask.taskIdentifier] }
        p?.onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let p = lock.withLock { pending.removeValue(forKey: downloadTask.taskIdentifier) }
        guard let p else { return }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            p.continuation.resume(throwing: NetError.badStatus(http.statusCode))
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            p.continuation.resume(returning: (tmp, downloadTask.response))
        } catch {
            p.continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let p = lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
        p?.continuation.resume(throwing: error)
    }
}
