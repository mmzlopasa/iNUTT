import AVFoundation
import UIKit

/// Warms up neighbours of the item on screen so swiping is instant, even on slow connections:
/// resolves their media, downloads images to the disk cache and pre-buffers video players.
@MainActor
final class Preloader {
    static let shared = Preloader()

    private var players: [String: AVPlayer] = [:]
    private var order: [String] = []
    private let maxPlayers = 4

    func player(for item: MediaItem, media: ResolvedMedia) -> AVPlayer {
        if let p = players[item.id] { touch(item.id); return p }
        let s = AppSettings.shared
        let asset = AVURLAsset(url: media.url, options: Net.avHeaders(referer: media.referer, url: media.url))
        let pi = AVPlayerItem(asset: asset)
        let q = CGFloat(s.maxQuality)
        pi.preferredMaximumResolution = CGSize(width: q * 16 / 9, height: q)
        pi.preferredPeakBitRate = 0
        // Start quickly: play as soon as a little is buffered, keep buffering ahead.
        pi.preferredForwardBufferDuration = 0
        let p = AVPlayer(playerItem: pi)
        p.isMuted = s.startMuted
        p.automaticallyWaitsToMinimizeStalling = false
        players[item.id] = p
        touch(item.id)
        return p
    }

    /// The player already made for an item, if any.
    func existing(_ id: String) -> AVPlayer? { players[id] }

    /// Releases a player when its page is gone and it is not a neighbour any more.
    func release(_ id: String) {
        players[id]?.pause()
    }

    func preload(around index: Int, in items: [MediaItem]) {
        let targets = [index + 1, index + 2, index - 1].filter { items.indices.contains($0) }.map { items[$0] }
        // A little further ahead only the link is worked out, so it is ready by the time a player is needed.
        for j in [index + 3, index + 4] where items.indices.contains(j) {
            let item = items[j]
            Task { _ = await FeedEngine.shared.resolve(item, priority: .background) }
        }
        for (n, item) in targets.enumerated() {
            Task {
                guard let media = await FeedEngine.shared.resolve(item, priority: .background) else { return }
                switch media.kind {
                case .video:
                    let p = self.player(for: item, media: media)
                    // The next video buffers its first seconds while you watch, like TikTok, so it starts at once.
                    p.currentItem?.preferredForwardBufferDuration = n == 0 ? 10 : 4
                    await self.preroll(p, id: item.id)
                case .image, .gif:
                    if media.gallery.count > 1 {
                        for u in media.gallery.prefix(3) { _ = await ImagePipeline.shared.data(u, referer: media.referer) }
                    } else {
                        _ = await ImagePipeline.shared.data(media.url, referer: media.referer)
                    }
                }
            }
        }
    }

    /// Waits until the player can play, then has it fill its buffer from the start without playing.
    private func preroll(_ p: AVPlayer, id: String) async {
        for _ in 0..<60 {
            guard players[id] === p, let item = p.currentItem else { return }
            if item.status == .readyToPlay { break }
            if item.status == .failed { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard players[id] === p, p.rate == 0, p.status == .readyToPlay, p.currentItem?.status == .readyToPlay else { return }
        _ = await p.preroll(atRate: 1)
    }

    private func touch(_ id: String) {
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > maxPlayers {
            let old = order.removeFirst()
            players[old]?.pause()
            players[old]?.replaceCurrentItem(with: nil)
            players[old] = nil
        }
    }
}
