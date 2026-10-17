import SwiftUI
import AVFoundation
import Combine
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

    private struct Snapshot: Codable { var source: String; var items: [MediaItem]; var next: URL?; var rounds: Int? }

    private init() {
        if let s = Disk.load(Snapshot.self, "reels.json"), s.source == AppSettings.shared.reelsSource {
            items = s.items
            next = s.next
            captureRounds = s.rounds ?? 0
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
            captureRounds = 0
        }
        if items.isEmpty { await refresh() }
    }

    func refresh() async {
        guard let site, !loading else { return }
        let source = AppSettings.shared.reelsSource
        loading = true
        defer { loading = false }
        // TikTok-style pages load their videos while you swipe: play through the page off screen and
        // show each video the moment it loads, while the page's links are read at the same time.
        captureRounds = 0
        streamSource = source
        streamed = []
        streamFresh = true
        let captureTask = Task { await self.capture(site, rounds: 10) }
        let r = try? await FeedEngine.fetchListing(url: site.url, base: site.url, site: site, categoryName: nil, allowRender: true)
        let strong = (r?.items ?? []).filter { $0.isListing != true && ($0.kind == .video || $0.kind == .gif || $0.duration != nil) }

        var list: [MediaItem] = []
        var nextPage: URL?
        if strong.count >= 6 && streamed.count < 2 {
            // A normal listing of videos: use it and stop the capture.
            captureTask.cancel()
            streamSource = nil
            let have = Set(streamed.map(\.id))
            list = streamed + Self.reels(r?.items ?? []).filter { !have.contains($0.id) }
            nextPage = r?.nextPage
        } else {
            let captured = await captureTask.value
            streamSource = nil
            if !captured.isEmpty {
                list = captured
                captureRounds = 10
            }
        }
        if list.isEmpty, let r {
            list = Self.reels(r.items)
            nextPage = r.nextPage
            // A page of categories: play the first ones.
            if list.count < 4 {
                for c in r.categories.prefix(3) {
                    if let r2 = try? await FeedEngine.fetchListing(url: c.url, base: c.url, site: site, categoryName: c.name, allowRender: true) {
                        let have = Set(list.map(\.id))
                        list += Self.reels(r2.items).filter { !have.contains($0.id) }
                    }
                }
            }
        }
        // The link itself is one reel (a single video page).
        if list.isEmpty {
            list = [MediaItem(siteID: site.id, siteName: site.name, title: "", thumbnailURL: nil, mediaURL: nil, pageURL: site.url, kind: .video)]
        }
        // The source changed while this one loaded: drop it and load the new one.
        guard source == AppSettings.shared.reelsSource else {
            Task { await self.loadIfNeeded() }
            return
        }
        // Videos that streamed in are on screen already: keep them first so the reel being watched stays.
        if streamed.isEmpty {
            items = list
        } else {
            let have = Set(items.map(\.id))
            items += list.filter { !have.contains($0.id) }
        }
        next = captureRounds > 0 ? nil : nextPage
        loadedSource = AppSettings.shared.reelsSource
        error = nil
        save()
    }

    func loadMore() async {
        guard let site, !loading else { return }
        let source = AppSettings.shared.reelsSource
        if captureRounds > 0 {
            // Swipe further through the page for the next videos, adding each as it loads.
            guard captureRounds < 60 else { return }
            loading = true
            defer { loading = false }
            captureRounds += 10
            streamSource = source
            streamFresh = false
            _ = await capture(site, rounds: captureRounds)
            streamSource = nil
            save()
            return
        }
        guard let next else { return }
        loading = true
        defer { loading = false }
        guard let r = try? await FeedEngine.fetchListing(url: next, base: site.url, site: site, categoryName: nil, allowRender: true) else {
            self.next = nil
            return
        }
        guard source == AppSettings.shared.reelsSource else { return }
        let have = Set(items.map(\.id))
        let fresh = Self.reels(r.items).filter { !have.contains($0.id) }
        items += fresh
        self.next = (r.nextPage == next) ? nil : r.nextPage
        save()
    }

    private var captureRounds = 0
    /// While set, captured videos of this source go on screen as soon as they load.
    private var streamSource: String?
    private var streamed: [MediaItem] = []
    private var streamFresh = false

    private func capture(_ site: Site, rounds: Int) async -> [MediaItem] {
        func item(_ v: PageRenderer.CapturedVideo) -> MediaItem {
            var item = MediaItem(siteID: site.id, siteName: site.name, title: v.title, thumbnailURL: v.poster,
                                 mediaURL: v.url, pageURL: site.url, kind: .video)
            // Every video comes from the same page; tell them apart by their file.
            item.id = MediaItem.hash(v.url.absoluteString)
            return item
        }
        return await PageRenderer.shared.captureVideos(site.url, rounds: rounds) { [weak self] batch in
            Task { @MainActor in
                guard let self, let s = self.streamSource, s == AppSettings.shared.reelsSource else { return }
                let fresh = batch.map(item)
                self.streamed += fresh
                // The first video of a fresh load replaces what was shown before.
                if self.streamFresh { self.items = []; self.streamFresh = false }
                let have = Set(self.items.map(\.id))
                self.items += fresh.filter { !have.contains($0.id) }
                self.loadedSource = s
            }
        }.map(item)
    }

    /// Videos, GIFs, and post links that may hold one, from any site. Post links are treated as
    /// videos so resolving them renders the page until its video shows up. Plain pictures are left out.
    static func reels(_ items: [MediaItem]) -> [MediaItem] {
        items.compactMap { i in
            if i.isListing == true { return nil }
            if i.kind == .video || i.kind == .gif { return i }
            guard i.mediaURL == nil, i.pageURL != nil else { return nil }
            var v = i
            v.kind = .video
            return v
        }
    }

    private func save() {
        Disk.save(Snapshot(source: loadedSource, items: Array(items.prefix(300)), next: next, rounds: captureRounds), "reels.json")
    }
}

/// Which reel is on screen and whether the Reels tab is visible. Pages live in their own
/// hosting controllers, so they follow this shared object instead of a binding.
@MainActor
final class ReelsCursor: ObservableObject {
    static let shared = ReelsCursor()
    @Published var index = 0
    @Published var visible = false
    /// Bumped when the reel on screen ended and the next one should slide in.
    @Published var advance = 0
}

/// TikTok-style feed: one full-screen video at a time, swipe up for the next.
struct ReelsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var lock: LockManager
    @Environment(\.scenePhase) private var phase
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
                    VStack(spacing: 14) {
                        ProgressView().tint(Theme.gold).scaleEffect(1.2)
                        Text("Loading reels…").font(Theme.text(14, .medium)).foregroundStyle(Theme.muted)
                    }
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
        .onAppear { updateVisible() }
        .onChange(of: router.tab) { _ in updateVisible() }
        .onChange(of: lock.isLocked) { _ in updateVisible() }
        .onChange(of: phase) { p in updateVisible(phase: p) }
        .onChange(of: settings.reelsSource) { _ in
            index = 0
            ReelsCursor.shared.index = 0
            Task { await store.loadIfNeeded() }
        }
        .sheet(isPresented: $showSource) { sourceSheet }
    }

    /// Inside onChange the view still holds the old phase, so the new one is passed in.
    private func updateVisible(phase: ScenePhase? = nil) {
        ReelsCursor.shared.visible = router.tab == .reels && !lock.isLocked && (phase ?? self.phase) == .active
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
            TextField("any video site or r/subreddit", text: $draft)
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
                Text("One link to any site with short videos. A few sites, like TikTok and Instagram, block apps from reading their feed.")
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
        context.coordinator.pvc = pvc
        context.coordinator.watchAdvance()
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
        weak var pvc: UIPageViewController?
        private var advanceSub: AnyCancellable?
        init(_ p: ReelsPager) { parent = p }

        /// Slides to the next reel when the one on screen ended (auto-scroll setting).
        @MainActor
        func watchAdvance() {
            advanceSub = ReelsCursor.shared.$advance.dropFirst().sink { [weak self] _ in
                guard let self, let pvc = self.pvc, let i = pvc.viewControllers?.first?.view.tag,
                      self.parent.items.indices.contains(i + 1) else { return }
                let next = i + 1
                pvc.setViewControllers([self.page(next)], direction: .forward, animated: true) { _ in
                    Task { @MainActor in self.settle(on: next) }
                }
            }
        }

        @MainActor
        private func settle(on i: Int) {
            parent.index = i
            ReelsCursor.shared.index = i
            Preloader.shared.preload(around: i, in: parent.items)
            if i >= parent.items.count - 4 { parent.onNearEnd() }
        }

        func page(_ i: Int) -> UIViewController {
            let page = ReelPage(item: parent.items[i], index: i)
                .environmentObject(AppSettings.shared)
                .environmentObject(Library.shared)
                .environmentObject(DownloadManager.shared)
                .ignoresSafeArea()
            let vc = UIHostingController(rootView: page)
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
            ReelsCursor.shared.index = i
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
    // Pages live in their own hosting controllers, which don't inherit the app's environment.
    @ObservedObject private var cursor = ReelsCursor.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var library = Library.shared
    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var paused = false
    @State private var failed = false
    @State private var loopObserver: NSObjectProtocol?
    @State private var onScreen = false
    @State private var ready = false

    private var isActive: Bool { cursor.visible && cursor.index == index }

    var body: some View {
        ZStack {
            Color.black
            if let player {
                PlayerLayerView(player: player).ignoresSafeArea()
            }
            // The poster stays on top until the first frame is ready, so a reel is never a black screen.
            if let t = item.thumbnailURL, !ready && image == nil && !failed {
                RemoteImage(url: t, referer: item.referer, maxPixel: 800, contentMode: .fill, showsPlaceholder: false)
                    .ignoresSafeArea()
            }
            if player != nil && !failed {
                if !ready { ProgressView().tint(Theme.gold) }
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
        .onChange(of: isActive) { active in
            if active { library.record(item) }
            apply()
        }
        .onAppear {
            onScreen = true
            // .task runs load() again on every appearance and replaces a released player.
            if let p = player, p.currentItem != nil {
                attachLoop(p)
                apply()
            }
        }
        .onDisappear {
            onScreen = false
            player?.pause()
            detachLoop()
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
        guard player != nil else { return }
        paused.toggle()
        apply()
    }

    private func apply() {
        guard let player else { return }
        if isActive && !paused && onScreen {
            // Coming back to a reel that already ended: start it over.
            if let d = player.currentItem?.duration, d.isNumeric, player.currentTime() >= d - CMTime(seconds: 0.3, preferredTimescale: 600) {
                player.seek(to: .zero)
            }
            player.play()
        } else {
            player.pause()
        }
    }

    private func attachLoop(_ p: AVPlayer) {
        guard loopObserver == nil, let current = p.currentItem else { return }
        let index = self.index
        loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: current, queue: .main) { [weak p] _ in
            Task { @MainActor in
                let cursor = ReelsCursor.shared
                if AppSettings.shared.reelsAutoNext, cursor.visible, cursor.index == index {
                    cursor.advance &+= 1
                } else {
                    p?.seek(to: .zero)
                    p?.play()
                }
            }
        }
    }

    private func detachLoop() {
        if let o = loopObserver { NotificationCenter.default.removeObserver(o) }
        loopObserver = nil
    }

    private func load() async {
        guard let r = await FeedEngine.shared.resolve(item) else { failed = true; return }
        guard !Task.isCancelled else { return }
        switch r.kind {
        case .video:
            let p = (player?.currentItem != nil ? player : nil) ?? Preloader.shared.player(for: item, media: r)
            p.isMuted = settings.startMuted
            p.currentItem?.preferredForwardBufferDuration = 0
            player = p
            if onScreen { attachLoop(p) }
            if isActive { library.record(item) }
            apply()
            await watch(p)
        case .gif, .image:
            image = await ImagePipeline.shared.image(r.url, referer: r.referer, maxPixel: 1600, animated: r.kind == .gif)
            failed = image == nil
        }
    }
}

extension ReelPage {
    /// Waits for the video's first frame, or shows the error instead of a black screen.
    private func watch(_ p: AVPlayer) async {
        for _ in 0..<80 {
            guard !Task.isCancelled, let pi = p.currentItem else { return }
            switch pi.status {
            case .readyToPlay:
                ready = true
                return
            case .failed:
                failed = true
                player = nil
                return
            default:
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        // Nothing after 16 seconds: this reel cannot play.
        if !ready { failed = true; player = nil }
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
