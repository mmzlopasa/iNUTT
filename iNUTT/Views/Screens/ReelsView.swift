import SwiftUI
import AVFoundation
import UIKit

/// Loads the short videos of the one Reels source and keeps them for an instant start next time.
@MainActor
final class ReelsStore: ObservableObject {
    static let shared = ReelsStore()

    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var next: URL?
    private var loadedSource = ""

    private struct Snapshot: Codable { var source: String; var items: [MediaItem]; var next: URL? }

    private init() {
        if let s = Disk.load(Snapshot.self, "reels.json"), s.source == AppSettings.shared.reelsSource {
            items = s.items
            next = s.next
            loadedSource = s.source
        }
    }

    var sourceURL: URL? { SiteStore.normalize(AppSettings.shared.reelsSource) }

    /// A hidden site describing the source, so the normal loaders can read it.
    var site: Site? {
        guard let u = sourceURL else { return nil }
        return Site(id: UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF")!, name: u.host?.replacingOccurrences(of: "www.", with: "") ?? "Reels", url: u)
    }

    func loadIfNeeded() async {
        if loadedSource != AppSettings.shared.reelsSource {
            items = []
            next = nil
        }
        if items.isEmpty { await refresh() }
    }

    func refresh() async {
        guard let site, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await FeedEngine.fetchListing(url: site.url, base: site.url, site: site, categoryName: nil, allowRender: true)
            var list = r.items.filter(Self.isReel)
            // A page of categories: play the first ones.
            if list.count < 4 {
                for c in r.categories.prefix(3) {
                    if let r2 = try? await FeedEngine.fetchListing(url: c.url, base: c.url, site: site, categoryName: c.name, allowRender: true) {
                        list += r2.items.filter(Self.isReel)
                    }
                }
            }
            items = list
            next = r.nextPage
            loadedSource = AppSettings.shared.reelsSource
            error = list.isEmpty ? "No videos found at this link. Try a subreddit with videos, e.g. r/TikTokCringe." : nil
            save()
        } catch {
            if items.isEmpty { self.error = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard let site, let next, !loading else { return }
        loading = true
        defer { loading = false }
        guard let r = try? await FeedEngine.fetchListing(url: next, base: site.url, site: site, categoryName: nil, allowRender: true) else {
            self.next = nil
            return
        }
        let have = Set(items.map(\.id))
        let fresh = r.items.filter { Self.isReel($0) && !have.contains($0.id) }
        items += fresh
        self.next = (r.nextPage == next) ? nil : r.nextPage
        save()
    }

    /// Videos, GIFs, and links that may hold one; plain pictures are left out.
    static func isReel(_ i: MediaItem) -> Bool {
        i.isListing != true && (i.kind == .video || i.kind == .gif || (i.mediaURL == nil && i.pageURL != nil && i.duration != nil))
    }

    private func save() {
        Disk.save(Snapshot(source: loadedSource, items: Array(items.prefix(300)), next: next), "reels.json")
    }
}

/// TikTok-style feed: one full-screen video at a time, swipe up for the next.
struct ReelsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = ReelsStore.shared
    @State private var index = 0
    @State private var draft = ""
    @State private var showSource = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if store.sourceURL == nil {
                sourceSetup
            } else if store.items.isEmpty {
                if store.loading {
                    ProgressView().tint(Theme.gold).scaleEffect(1.2)
                } else {
                    VStack(spacing: 16) {
                        EmptyStateView(symbol: "play.rectangle.on.rectangle", title: "No reels",
                                       message: store.error ?? "Nothing to play yet.", buttonTitle: "Try again") {
                            Task { await store.refresh() }
                        }
                        Button("Change source") { draft = settings.reelsSource; showSource = true }
                            .buttonStyle(GhostButtonStyle())
                    }
                    .padding(.horizontal, 16)
                }
            } else {
                ReelsPager(items: store.items, index: $index) {
                    Task { await store.loadMore() }
                }
                .ignoresSafeArea()
                topBar
            }
        }
        .task { await store.loadIfNeeded() }
        .onChange(of: settings.reelsSource) { _ in
            index = 0
            Task { await store.loadIfNeeded() }
        }
        .sheet(isPresented: $showSource) { sourceSheet }
    }

    private var topBar: some View {
        VStack {
            HStack {
                Text("Reels").font(Theme.display(20, .bold)).foregroundStyle(.white)
                Spacer()
                Button { draft = settings.reelsSource; showSource = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(Circle().fill(.black.opacity(0.35)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            Spacer()
        }
    }

    private var sourceSetup: some View {
        VStack(spacing: 18) {
            EmptyStateView(symbol: "play.rectangle.on.rectangle.fill", title: "Reels",
                           message: "Add one link with short videos. They play full screen; swipe up for the next one.")
            sourceField
        }
        .padding(.horizontal, 16)
    }

    private var sourceField: some View {
        VStack(spacing: 12) {
            TextField("e.g. r/TikTokCringe or a video site", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(Theme.mono(14))
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line2))
            Button("Use this source") {
                guard SiteStore.normalize(draft) != nil else { return }
                settings.reelsSource = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                showSource = false
            }
            .buttonStyle(GoldButtonStyle())
            .disabled(SiteStore.normalize(draft) == nil)
        }
    }

    private var sourceSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("One link only. Subreddits with videos work best; TikTok itself blocks apps from reading its feed.")
                    .font(Theme.text(13)).foregroundStyle(Theme.muted)
                sourceField
                Spacer()
            }
            .padding(16)
            .background(NightSky())
            .navigationTitle("Reels source")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

/// Vertical pager backed by UIPageViewController, so only nearby pages exist.
struct ReelsPager: UIViewControllerRepresentable {
    let items: [MediaItem]
    @Binding var index: Int
    var onNearEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .vertical)
        pvc.view.backgroundColor = .black
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        if items.indices.contains(index) {
            pvc.setViewControllers([context.coordinator.page(index)], direction: .forward, animated: false)
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        if pvc.viewControllers?.isEmpty ?? true, items.indices.contains(index) {
            pvc.setViewControllers([context.coordinator.page(index)], direction: .forward, animated: false)
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: ReelsPager
        init(_ p: ReelsPager) { parent = p }

        func page(_ i: Int) -> UIViewController {
            let vc = UIHostingController(rootView: ReelPage(item: parent.items[i], index: i, current: parent.$index))
            vc.view.backgroundColor = .black
            vc.view.tag = i
            return vc
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            let i = vc.view.tag - 1
            return parent.items.indices.contains(i) ? page(i) : nil
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            let i = vc.view.tag + 1
            return parent.items.indices.contains(i) ? page(i) : nil
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let i = pvc.viewControllers?.first?.view.tag else { return }
            parent.index = i
            UISelectionFeedbackGenerator().selectionChanged()
            Preloader.shared.preload(around: i, in: parent.items)
            if i >= parent.items.count - 4 { parent.onNearEnd() }
        }
    }
}

/// One reel: full-screen video that fills the screen, with its title and actions on top.
struct ReelPage: View {
    let item: MediaItem
    let index: Int
    @Binding var current: Int
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var library = Library.shared
    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var paused = false
    @State private var failed = false
    @State private var loopObserver: NSObjectProtocol?

    private var isActive: Bool { current == index }

    var body: some View {
        ZStack {
            Color.black
            if let t = item.thumbnailURL, player == nil && image == nil {
                RemoteImage(url: t, referer: item.referer, maxPixel: 800, contentMode: .fill, showsPlaceholder: false)
            }
            if let player {
                PlayerLayerView(player: player).ignoresSafeArea()
            } else if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if failed {
                Text("Couldn't play this one. Swipe up for the next.").font(Theme.text(14)).foregroundStyle(Theme.body)
            } else {
                ProgressView().tint(Theme.gold)
            }
            if paused {
                Image(systemName: "play.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.85))
            }
            overlay
        }
        .contentShape(Rectangle())
        .onTapGesture { togglePause() }
        .task { await load() }
        .onChange(of: current) { _ in
            if isActive {
                library.record(item)
                if !paused { player?.play() }
            } else {
                player?.pause()
            }
        }
        .onDisappear {
            player?.pause()
            if let o = loopObserver { NotificationCenter.default.removeObserver(o) }
        }
    }

    private var overlay: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.siteName.uppercased()).font(Theme.mono(10)).foregroundStyle(Theme.gold).tracking(1)
                    if !item.title.isEmpty {
                        Text(item.title).font(Theme.text(15, .medium)).foregroundStyle(.white).lineLimit(3)
                    }
                }
                Spacer()
                VStack(spacing: 18) {
                    side(library.isFavorite(item) ? "heart.fill" : "heart", library.isFavorite(item)) { library.toggleFavorite(item) }
                    side("arrow.down.circle", false) { Task { await DownloadManager.shared.download(item) } }
                    side(player?.isMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill", false) {
                        player?.isMuted.toggle()
                        settings.startMuted = player?.isMuted ?? false
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 110)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).frame(height: 260), alignment: .bottom)
        }
    }

    private func side(_ symbol: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 24, weight: .semibold))
                .foregroundStyle(on ? Theme.gold : .white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(.black.opacity(0.3)))
        }
    }

    private func togglePause() {
        guard let player else { return }
        paused.toggle()
        if paused { player.pause() } else { player.play() }
    }

    private func load() async {
        guard let r = await FeedEngine.shared.resolve(item) else { failed = true; return }
        switch r.kind {
        case .video:
            let p = Preloader.shared.player(for: item, media: r)
            p.isMuted = settings.startMuted
            p.currentItem?.preferredForwardBufferDuration = 0
            loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
                p.seek(to: .zero)
                p.play()
            }
            player = p
            if isActive {
                library.record(item)
                p.play()
            }
        case .gif, .image:
            image = await ImagePipeline.shared.image(r.url, referer: r.referer, maxPixel: 1600, animated: r.kind == .gif)
            failed = image == nil
        }
    }
}

/// Plain AVPlayerLayer filling the screen, like TikTok.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = .resizeAspectFill
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}
