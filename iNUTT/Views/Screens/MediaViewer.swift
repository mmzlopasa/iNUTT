import SwiftUI
import AVKit

struct MediaViewer: View {
    let items: [MediaItem]
    @State private var index: Int
    @State private var chrome = true
    @State private var zoomed = false
    @State private var dragY: CGFloat = 0
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    init(items: [MediaItem], startIndex: Int) {
        self.items = items
        _index = State(initialValue: startIndex)
    }

    private var current: MediaItem { items[min(max(index, 0), items.count - 1)] }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(abs(dragY) / 500, 0.7))
                .ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    MediaPage(item: item, isActive: i == index, isZoomed: $zoomed, onTap: toggleChrome)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: dragY)
            .scaleEffect(1 - min(abs(dragY) / 2000, 0.12))
            .simultaneousGesture(dismissDrag)

            if chrome {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }

            if let t = downloads.toast {
                VStack {
                    ToastView(toast: t).padding(.top, 60)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chrome)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: downloads.toast)
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        .onAppear {
            library.record(current)
            Preloader.shared.preload(around: index, in: items)
        }
        .onChange(of: index) { i in
            zoomed = false
            library.record(current)
            Preloader.shared.preload(around: i, in: items)
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func toggleChrome() { chrome.toggle() }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { v in
                guard !zoomed, abs(v.translation.height) > abs(v.translation.width) * 1.4 else { return }
                dragY = v.translation.height
            }
            .onEnded { v in
                if abs(dragY) > 140 || abs(v.predictedEndTranslation.height) > 500 && dragY != 0 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragY = 0 }
                }
            }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().strokeBorder(Theme.edge, lineWidth: 0.8))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(current.siteName).font(Theme.display(14, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                if let c = current.categoryName {
                    Text(c).font(Theme.mono(10)).foregroundStyle(Theme.gold).lineLimit(1)
                }
            }
            Spacer()
            Text("\(index + 1) / \(items.count)")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.body)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(.ultraThinMaterial))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !current.title.isEmpty {
                Text(current.title)
                    .font(Theme.text(15, .medium))
                    .foregroundStyle(.white)
                    .lineLimit(3)
            }
            HStack(spacing: 12) {
                KindBadge(item: current)
                Spacer()
                actionButton(library.isFavorite(current) ? "heart.fill" : "heart", active: library.isFavorite(current)) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    library.toggleFavorite(current)
                }
                ZStack {
                    actionButton("arrow.down.to.line", active: false) {
                        let item = current
                        Task { await downloads.download(item) }
                    }
                    if let p = downloads.progress[current.id] {
                        Circle()
                            .trim(from: 0, to: max(0.03, p))
                            .stroke(Theme.gold, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 46, height: 46)
                            .allowsHitTesting(false)
                    }
                }
                if let link = FeedEngine.shared.cachedResolution(current)?.url ?? current.mediaURL ?? current.pageURL {
                    ShareLink(item: link) {
                        actionIcon("square.and.arrow.up", active: false)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .padding(.top, 30)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private func actionButton(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionIcon(symbol, active: active) }
    }

    private func actionIcon(_ symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(active ? Theme.onGold : Theme.ink)
            .frame(width: 46, height: 46)
            .background(
                Circle().fill(active ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(.ultraThinMaterial))
            )
            .overlay(Circle().strokeBorder(Theme.edge, lineWidth: 0.8))
    }
}

struct MediaPage: View {
    let item: MediaItem
    let isActive: Bool
    @Binding var isZoomed: Bool
    var onTap: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var resolved: ResolvedMedia?
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            if let r = resolved {
                switch r.kind {
                case .video:
                    if let player {
                        // Leaves room for the viewer's top and bottom bars so player controls stay reachable.
                        ZStack {
                            if let t = item.thumbnailURL {
                                RemoteImage(url: t, referer: item.referer, maxPixel: 600, contentMode: .fit, showsPlaceholder: false)
                                    .opacity(0.5)
                            }
                            VideoPlayerView(player: player)
                        }
                        .padding(.top, 60)
                        .padding(.bottom, 120)
                    } else {
                        placeholder
                    }
                case .image, .gif:
                    if r.gallery.count > 1 {
                        GalleryStack(urls: r.gallery, referer: r.referer, onTap: onTap)
                    } else if let image {
                        ZoomableImage(image: image, isZoomed: $isZoomed, onTap: onTap)
                            .ignoresSafeArea()
                    } else {
                        placeholder
                    }
                }
            } else if failed {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(Theme.gold)
                    Text("Sadržaj se ne može učitati").font(Theme.text(15, .medium)).foregroundStyle(Theme.ink)
                    Button("Pokušaj ponovno") { Task { await load() } }.buttonStyle(GhostButtonStyle())
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .task { await load() }
        .onChange(of: isActive) { active in
            if active { if settings.autoplay { player?.play() } } else { player?.pause() }
        }
        .onDisappear {
            player?.pause()
            if let o = loopObserver { NotificationCenter.default.removeObserver(o) }
        }
    }

    private var placeholder: some View {
        ZStack {
            // The grid thumbnail is already cached, so something is on screen instantly.
            if let t = item.thumbnailURL {
                RemoteImage(url: t, referer: item.referer, maxPixel: 600, contentMode: .fit, showsPlaceholder: false)
            }
            ProgressView().tint(Theme.gold).scaleEffect(1.1)
                .padding(10)
                .background(Circle().fill(.black.opacity(0.4)))
        }
        .onTapGesture(perform: onTap)
    }

    private func load() async {
        failed = false
        guard let r = await FeedEngine.shared.resolve(item) else { failed = true; return }
        resolved = r
        switch r.kind {
        case .video:
            if player == nil { player = makePlayer(r) }
            player?.currentItem?.preferredForwardBufferDuration = 0
            if isActive && settings.autoplay { player?.play() }
        case .image, .gif:
            guard r.gallery.count <= 1 else { return }
            let img = await ImagePipeline.shared.image(r.url, referer: r.referer, maxPixel: 3840, animated: r.kind == .gif)
            if let img { image = img } else { failed = true; resolved = nil }
        }
    }

    private func makePlayer(_ r: ResolvedMedia) -> AVPlayer {
        let p = Preloader.shared.player(for: item, media: r)
        if settings.loopVideos, let pi = p.currentItem {
            loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: pi, queue: .main) { _ in
                p.seek(to: .zero)
                p.play()
            }
        }
        return p
    }
}

struct GalleryStack: View {
    let urls: [URL]
    let referer: URL?
    var onTap: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(urls, id: \.self) { u in
                    RemoteImage(url: u, referer: referer, maxPixel: 2400, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 200)
                }
            }
            .padding(.vertical, 70)
        }
        .onTapGesture(perform: onTap)
    }
}

struct VideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.videoGravity = .resizeAspect
        vc.view.backgroundColor = .clear
        vc.updatesNowPlayingInfoCenter = true
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 6
        sv.bouncesZoom = true
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.contentInsetAdjustmentBehavior = .never
        sv.backgroundColor = .clear
        sv.delegate = context.coordinator

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.frame = sv.bounds
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        iv.isUserInteractionEnabled = true
        sv.addSubview(iv)
        context.coordinator.imageView = iv

        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        sv.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        sv.addGestureRecognizer(single)
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            sv.setZoomScale(1, animated: false)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImage
        weak var imageView: UIImageView?

        init(_ parent: ZoomableImage) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let z = scrollView.zoomScale > 1.01
            if z != parent.isZoomed { DispatchQueue.main.async { self.parent.isZoomed = z } }
        }

        @objc func singleTap() { parent.onTap() }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? UIScrollView else { return }
            if sv.zoomScale > 1.01 {
                sv.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: imageView)
                let scale: CGFloat = 2.6
                let size = CGSize(width: sv.bounds.width / scale, height: sv.bounds.height / scale)
                sv.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
