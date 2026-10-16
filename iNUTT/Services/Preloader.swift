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
        let asset = AVURLAsset(url: media.url, options: Net.avHeaders(referer: media.referer))
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

    /// Releases a player when its page is gone and it is not a neighbour any more.
    func release(_ id: String) {
        players[id]?.pause()
    }

    func preload(around index: Int, in items: [MediaItem]) {
        let targets = [index + 1, index + 2, index - 1].filter { items.indices.contains($0) }.map { items[$0] }
        for item in targets {
            Task {
                guard let media = await FeedEngine.shared.resolve(item) else { return }
                switch media.kind {
                case .video:
                    let p = self.player(for: item, media: media)
                    p.currentItem?.preferredForwardBufferDuration = 4
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
