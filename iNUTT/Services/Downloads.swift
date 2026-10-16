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
        guard progress[item.id] == nil else { return }
        guard let media = await FeedEngine.shared.resolve(item) else {
            show("Sadržaj nije pronađen", symbol: "exclamationmark.triangle.fill", isError: true)
            return
        }
        if media.url.absoluteString.contains(".m3u8") {
            show("Ovaj video je stream i ne može se preuzeti", symbol: "exclamationmark.triangle.fill", isError: true)
            return
        }
        progress[item.id] = 0
        show("Preuzimam…", symbol: "arrow.down.circle.fill", progress: 0, autoHide: false)
        defer { progress[item.id] = nil }

        do {
            var req = Net.request(media.url, referer: media.referer)
            req.setValue("*/*", forHTTPHeaderField: "Accept")
            let id = item.id
            let (tmp, response) = try await delegate.download(req, in: session) { p in
                Task { @MainActor in
                    self.progress[id] = p
                    self.show("Preuzimam…", symbol: "arrow.down.circle.fill", progress: p, autoHide: false)
                }
            }
            let ext = Self.fileExtension(for: media, response: response)
            let base = item.title.isEmpty ? "iNUTT-\(item.id)" : String(item.title.prefix(60))
            let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            var dest = Self.downloadsFolder.appendingPathComponent(safe).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = Self.downloadsFolder.appendingPathComponent("\(safe)-\(Int(Date().timeIntervalSince1970))").appendingPathExtension(ext)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)

            if AppSettings.shared.saveToPhotos {
                try await Self.saveToPhotos(dest, kind: media.kind == .video ? .video : (ext == "gif" ? .gif : .image))
                show("Spremljeno u Fotografije", symbol: "checkmark.circle.fill")
            } else {
                show("Spremljeno u Datoteke › iNUTT", symbol: "checkmark.circle.fill")
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            show("Preuzimanje nije uspjelo", symbol: "xmark.octagon.fill", isError: true)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
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
