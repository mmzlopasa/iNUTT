import UIKit
import ImageIO
import CryptoKit

/// Memory + disk image cache with downsampling, so grids load instantly and stay smooth.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inflight: [String: Task<Data?, Never>] = [:]
    let diskDir: URL

    private init() {
        memory.totalCostLimit = 220 * 1024 * 1024
        memory.countLimit = 600
        diskDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("inutt-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 10) { [weak self] in self?.trimDisk() }
    }

    private func memKey(_ url: URL, _ px: CGFloat) -> NSString { "\(Int(px))|\(url.absoluteString)" as NSString }

    func cached(_ url: URL?, maxPixel: CGFloat) -> UIImage? {
        guard let url else { return nil }
        return memory.object(forKey: memKey(url, maxPixel))
    }

    func image(_ url: URL, referer: URL?, maxPixel: CGFloat, animated: Bool = false) async -> UIImage? {
        let key = memKey(url, maxPixel)
        if !animated, let m = memory.object(forKey: key) { return m }
        guard let data = await data(url, referer: referer) else { return nil }
        let img: UIImage? = await Task.detached(priority: .userInitiated) {
            if animated, let a = ImagePipeline.animated(data, maxPixel: maxPixel) { return a }
            return ImagePipeline.downsample(data, maxPixel: maxPixel)
        }.value
        if let img, !animated {
            let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
            memory.setObject(img, forKey: key, cost: cost)
        }
        return img
    }

    func data(_ url: URL, referer: URL?) async -> Data? {
        let file = diskDir.appendingPathComponent(Self.hash(url.absoluteString))
        if let d = try? Data(contentsOf: file), !d.isEmpty { return d }
        let k = url.absoluteString
        let existing: Task<Data?, Never>? = lock.withLock { inflight[k] }
        if let existing { return await existing.value }
        let task = Task<Data?, Never> {
            var req = Net.request(url, referer: referer, policy: .returnCacheDataElseLoad)
            req.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            guard let (d, resp) = try? await Net.session.data(for: req),
                  (resp as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true, !d.isEmpty else { return nil }
            try? d.write(to: file, options: .atomic)
            return d
        }
        lock.withLock { inflight[k] = task }
        let d = await task.value
        lock.withLock { inflight[k] = nil }
        return d
    }

    func prefetch(_ urls: [(URL, URL?)]) {
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { g in
                for (i, pair) in urls.enumerated() {
                    g.addTask { _ = await self.image(pair.0, referer: pair.1, maxPixel: 600) }
                    if i % 6 == 5 { await g.waitForAll() }
                }
            }
        }
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return UIImage(data: data) }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }

    static func animated(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return nil }
        var frames: [UIImage] = []
        var total: Double = 0
        let step = count > 300 ? 2 : 1
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel, 1280)
        ] as CFDictionary
        for i in stride(from: 0, to: count, by: step) {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, i, thumbOpts) else { continue }
            var delay = 0.1
            if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
               let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            }
            if delay < 0.02 { delay = 0.1 }
            total += delay * Double(step)
            frames.append(UIImage(cgImage: cg))
        }
        return UIImage.animatedImage(with: frames, duration: total)
    }

    func diskUsage() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for dir in [diskDir, fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("inutt-http")] {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDir)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        Net.cache.removeAllCachedResponses()
    }

    /// Keeps the image cache under ~1.5 GB by removing the oldest files.
    private func trimDisk() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey]
        guard let files = try? fm.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { u -> (URL, Int, Date)? in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return (u, v.fileSize ?? 0, v.contentAccessDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        let limit = 1_500 * 1024 * 1024
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for e in entries where total > limit * 3 / 4 {
            try? fm.removeItem(at: e.0)
            total -= e.1
        }
    }
}
