import SwiftUI

struct Shimmer: View {
    @State private var phase: CGFloat = -1
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.navy2
                LinearGradient(colors: [.clear, .white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.8)
                    .offset(x: phase * geo.size.width * 1.4)
            }
        }
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

struct RemoteImage: View {
    let url: URL?
    var referer: URL?
    var maxPixel: CGFloat = 600
    var contentMode: ContentMode = .fill
    var showsPlaceholder = true

    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL?, referer: URL? = nil, maxPixel: CGFloat = 600, contentMode: ContentMode = .fill, showsPlaceholder: Bool = true) {
        self.url = url
        self.referer = referer
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.showsPlaceholder = showsPlaceholder
        _image = State(initialValue: ImagePipeline.shared.cached(url, maxPixel: maxPixel))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if showsPlaceholder {
                if failed {
                    ZStack {
                        Theme.navy2
                        Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(Theme.muted.opacity(0.6))
                    }
                } else {
                    Shimmer()
                }
            }
        }
        .task(id: url) {
            guard image == nil, let url else { if url == nil { failed = true }; return }
            let img = await ImagePipeline.shared.image(url, referer: referer, maxPixel: maxPixel)
            withAnimation(.easeOut(duration: 0.25)) {
                image = img
                failed = img == nil
            }
        }
    }
}

struct KindBadge: View {
    var item: MediaItem
    var body: some View {
        HStack(spacing: 4) {
            switch item.kind {
            case .video:
                Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                if let d = item.duration { Text(d).font(Theme.mono(10)) }
            case .gif:
                Text("GIF").font(Theme.mono(10))
            case .image:
                Image(systemName: "photo").font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(item.kind == .image ? Theme.ink : Theme.onGold)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(
            Capsule().fill(item.kind == .image ? AnyShapeStyle(Color.black.opacity(0.45)) : AnyShapeStyle(Theme.goldGradient))
        )
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }
}

struct MediaCard: View {
    let item: MediaItem
    var aspect: CGFloat = 4 / 5
    var showTitle = true
    @ObservedObject private var marks = FavoriteMarks.shared
    @ObservedObject private var seen = SeenMarks.shared

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay(RemoteImage(url: item.thumbnailURL, referer: item.referer))
            .overlay(alignment: .bottom) {
                if showTitle && !item.title.isEmpty {
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 70)
                        .overlay(alignment: .bottomLeading) {
                            Text(item.title)
                                .font(Theme.text(12, .medium))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .padding(10)
                        }
                }
            }
            .overlay {
                // Already opened: dimmed, so new things stand out.
                if seen.contains(item) { Color.black.opacity(0.35).allowsHitTesting(false) }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if seen.contains(item) {
                        Image(systemName: "eye.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 20, height: 20).background(Circle().fill(.black.opacity(0.45)))
                    }
                    KindBadge(item: item)
                }
                .padding(8)
            }
            .overlay(alignment: .topLeading) {
                if marks.contains(item) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.gold)
                        .padding(6)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.edge, lineWidth: 0.6))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onAppear { FeedEngine.shared.prefetch(item) }
    }
}

/// Context menu shared by every card.
struct MediaContextMenu: View {
    let item: MediaItem
    @EnvironmentObject private var library: Library
    @ObservedObject private var collections = CollectionStore.shared

    var body: some View {
        Button {
            library.toggleFavorite(item)
        } label: {
            Label(library.isFavorite(item) ? "Remove from favorites" : "Add to favorites",
                  systemImage: library.isFavorite(item) ? "heart.slash" : "heart")
        }
        Button {
            Task { await DownloadManager.shared.download(item) }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
        if !collections.collections.isEmpty {
            Menu {
                ForEach(collections.collections) { c in
                    Button {
                        collections.toggle(item, in: c.id)
                    } label: {
                        if collections.contains(item, in: c.id) { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                    }
                }
            } label: {
                Label("Add to collection", systemImage: "folder.badge.plus")
            }
        }
    }
}

struct MediaGrid: View {
    /// 2 columns on iPhone, 5 on iPad.
    static var columnCount: Int { UIDevice.current.userInterfaceIdiom == .pad ? 5 : 2 }
    static var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount) }

    let items: [MediaItem]
    var onReachEnd: (() -> Void)?
    @EnvironmentObject private var viewer: ViewerState
    /// Fixed per list, so cards do not jump when an item turns out to be a video while scrolling.
    @State private var shape: (key: String, aspect: CGFloat)?

    private var key: String { (items.first?.id ?? "") + "|" + String(items.count > 0) }

    private var computedAspect: CGFloat {
        let videos = items.prefix(30).filter { $0.kind == .video }.count
        return videos * 2 > min(items.count, 30) ? 16 / 11 : 4 / 5
    }

    private var aspect: CGFloat {
        if let shape, shape.key == key { return shape.aspect }
        return computedAspect
    }

    var body: some View {
        let cols = MediaGrid.columns
        LazyVGrid(columns: cols, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                Button {
                    viewer.open(items, at: idx)
                } label: {
                    MediaCard(item: item, aspect: aspect)
                }
                .buttonStyle(CardPressStyle())
                .contextMenu { MediaContextMenu(item: item) }
                .onAppear {
                    if idx >= items.count - 6 { onReachEnd?() }
                    // Warm the next screenful of thumbnails while scrolling.
                    if idx % 6 == 0 {
                        let next = items.dropFirst(idx + 1).prefix(18).compactMap { i in i.thumbnailURL.map { ($0, i.referer) } }
                        ImagePipeline.shared.prefetch(Array(next))
                    }
                }
            }
        }
        .onAppear { if shape?.key != key { shape = (key, computedAspect) } }
        .onChange(of: key) { k in shape = (k, computedAspect) }
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

struct KindFilterBar: View {
    @Binding var filter: MediaKind?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "All", symbol: "square.grid.2x2", selected: filter == nil) { filter = nil }
                ForEach(MediaKind.allCases, id: \.self) { k in
                    Chip(title: k.label, symbol: k.symbol, selected: filter == k) { filter = k }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(toast.isError ? AnyShapeStyle(Theme.err) : AnyShapeStyle(Theme.goldGradient))
            Text(toast.text).font(Theme.text(14, .medium)).foregroundStyle(Theme.ink)
            if let p = toast.progress {
                Text("\(Int(p * 100))%").font(Theme.mono(12)).foregroundStyle(Theme.gold)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Capsule().fill(Theme.navy.opacity(0.85)).background(.ultraThinMaterial, in: Capsule()))
        .overlay(alignment: .bottom) {
            if let p = toast.progress {
                GeometryReader { g in
                    Capsule().fill(Theme.goldGradient).frame(width: max(8, g.size.width * p), height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 18)
                .padding(.bottom, 4)
            }
        }
        .overlay(Capsule().strokeBorder(Theme.edge, lineWidth: 0.8))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
    }
}
