import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var sites: SiteStore
    @EnvironmentObject private var engine: FeedEngine
    @EnvironmentObject private var viewer: ViewerState
    @State private var filter: MediaKind?
    @State private var showAdd = false
    @State private var showHistory = false
    @EnvironmentObject private var router: Router

    private var enabled: [Site] { sites.enabledSites }

    private var mixed: [MediaItem] {
        let all = engine.mixedFeed(enabled)
        guard let filter else { return all }
        return all.filter { $0.kind == filter }
    }

    var body: some View {
        NavigationStack(path: $router.home) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if enabled.isEmpty {
                        EmptyStateView(symbol: "sparkles", title: "Welcome to iNUTT",
                                       message: "Add sites with images, GIFs and videos. Everything is shown natively, no browser.",
                                       buttonTitle: "Add site") { showAdd = true }
                            .padding(.horizontal, 16)
                    } else {
                        let items = mixed
                        if items.isEmpty && enabled.allSatisfy({ $0.categories.isEmpty }) {
                            loadingOrEmpty
                        } else {
                            if !items.isEmpty { HeroCarousel(items: Array(items.prefix(8))) }
                            KindFilterBar(filter: $filter)
                            if filter == nil {
                                ForEach(enabled) { site in
                                    SiteRow(site: site) { router.home.append(SiteRoute(siteID: site.id)) }
                                }
                            }
                            if !items.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    SectionHeader(title: "Latest", subtitle: "\(items.count) items from \(enabled.count) sites")
                                    MediaGrid(items: Array(items.prefix(120)))
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .refreshable { await engine.refreshAll() }
            .tabBarInset()
            .background(NightSky())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SiteRoute.self) { r in
                SiteRouteView(route: r)
            }
            .navigationDestination(isPresented: $showHistory) { HistoryView() }
        }
        .sheet(isPresented: $showAdd) { AddSiteView() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting.uppercased()).font(Theme.mono(11)).foregroundStyle(Theme.muted).tracking(1.2)
                Wordmark(size: 30)
            }
            Spacer()
            if engine.isRefreshingAll {
                ProgressView().tint(Theme.gold).padding(.trailing, 4)
            }
            circleButton("clock.arrow.circlepath") { showHistory = true }
            circleButton("plus") { showAdd = true }
        }
        .padding(.horizontal, 16)
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .overlay(Circle().strokeBorder(Theme.line2, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var loadingOrEmpty: some View {
        if engine.isRefreshingAll || !engine.loading.isEmpty {
            VStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { _ in
                    Shimmer().frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
        } else {
            EmptyStateView(symbol: "wand.and.stars", title: "No content yet",
                           message: "Pull down to refresh or check your site settings.",
                           buttonTitle: "Refresh") { Task { await engine.refreshAll() } }
                .padding(.horizontal, 16)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

struct SiteRoute: Hashable {
    var siteID: UUID
    var category: SiteCategory?
    var showAllCategories = false
}

struct HeroCarousel: View {
    let items: [MediaItem]
    @EnvironmentObject private var viewer: ViewerState
    @State private var index = 0
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    Button { viewer.open(items, at: i) } label: { card(item) }
                        .buttonStyle(CardPressStyle())
                        .padding(.horizontal, 16)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 420 : 250)
            HStack(spacing: 6) {
                ForEach(0..<items.count, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Color.white.opacity(0.18)))
                        .frame(width: i == index ? 22 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: index)
        }
        .onReceive(timer) { _ in
            guard items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.5)) { index = (index + 1) % items.count }
        }
    }

    private func card(_ item: MediaItem) -> some View {
        Color.clear
            .overlay(RemoteImage(url: item.thumbnailURL, referer: item.referer, maxPixel: 1200))
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.2), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(item.siteName.uppercased()).font(Theme.mono(10)).tracking(1)
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(Capsule().fill(.white.opacity(0.14)))
                        KindBadge(item: item)
                    }
                    .foregroundStyle(Theme.ink)
                    if !item.title.isEmpty {
                        Text(item.title).font(Theme.display(19, .semibold)).foregroundStyle(.white).lineLimit(2)
                    }
                }
                .padding(18)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: item.kind == .video ? "play.fill" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.onGold)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.goldGradient))
                    .shadow(color: Theme.gold.opacity(0.5), radius: 10)
                    .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
    }
}

struct SiteRow: View {
    let site: Site
    var onOpen: () -> Void
    @EnvironmentObject private var engine: FeedEngine
    @EnvironmentObject private var viewer: ViewerState

    var body: some View {
        let all = engine.homeItems(site)
        let items = Array(all.prefix(20))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SiteIcon(site: site, size: 30)
                SectionHeader(title: site.name, subtitle: site.host.uppercased(), actionTitle: "All", action: onOpen)
            }
            .padding(.horizontal, 16)
            if !site.categories.isEmpty {
                CategoryRow(site: site, categories: Array(site.categories.prefix(20)))
            }
            if items.isEmpty && site.categories.isEmpty {
                Group {
                    if engine.loading.contains(FeedEngine.key(site)) {
                        Shimmer().frame(height: 150)
                    } else if let err = engine.errors[FeedEngine.key(site)] {
                        Text(err).font(Theme.text(13)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, minHeight: 60)
                    } else {
                        Text("No content").font(Theme.text(13)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 16)
            } else if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            Button { viewer.open(all, at: i) } label: {
                                let a: CGFloat = item.kind == .video ? 16 / 11 : 4 / 5
                                MediaCard(item: item, aspect: a)
                                    .frame(width: 190 * a, height: 190)
                            }
                            .buttonStyle(CardPressStyle())
                            .contextMenu { MediaContextMenu(item: item) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
