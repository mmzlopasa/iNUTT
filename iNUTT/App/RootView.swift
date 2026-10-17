import SwiftUI

enum AppTab: Int, CaseIterable, Identifiable {
    case home, reels, sites, search, favorites
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .reels: return "Reels"
        case .sites: return "Sites"
        case .search: return "Search"
        case .favorites: return "Favorites"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .reels: return "play.rectangle.on.rectangle.fill"
        case .sites: return "square.grid.2x2.fill"
        case .search: return "magnifyingglass"
        case .favorites: return "heart.fill"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var lock: LockManager
    @EnvironmentObject private var viewer: ViewerState
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: FeedEngine
    @Environment(\.scenePhase) private var phase
    @EnvironmentObject private var router: Router
    @State private var didStart = false
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $router.tab) {
                HomeView().tag(AppTab.home).toolbar(.hidden, for: .tabBar)
                ReelsView().tag(AppTab.reels).toolbar(.hidden, for: .tabBar)
                SitesView().tag(AppTab.sites).toolbar(.hidden, for: .tabBar)
                SearchView().tag(AppTab.search).toolbar(.hidden, for: .tabBar)
                FavoritesView().tag(AppTab.favorites).toolbar(.hidden, for: .tabBar)
            }
            FloatingTabBar(selection: $router.tab)
                .padding(.bottom, 6)
        }
        .ignoresSafeArea(.keyboard)
        .background(NightSky())
        .fullScreenCover(item: $viewer.presentation) { p in
            MediaViewer(items: p.items, startIndex: p.index)
                .environmentObject(downloads)
                .environmentObject(viewer)
        }
        .overlay(alignment: .top) {
            if let t = downloads.toast, viewer.presentation == nil {
                ToastView(toast: t)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: downloads.toast)
        .overlay {
            if !onboarded {
                OnboardingView { withAnimation(.easeInOut(duration: 0.3)) { onboarded = true } }
                    .transition(.opacity)
            }
        }
        .onAppear { updateLock() }
        .onChange(of: lock.isLocked) { _ in updateLock() }
        .onChange(of: phase) { p in
            updateLock()
            // Face ID can't run while the app is in the background; ask again when it is back.
            if p == .active && lock.isLocked { Task { await lock.authenticateBiometric() } }
        }
        .task {
            guard !didStart else { return }
            didStart = true
            engine.scheduleBackgroundRefresh()
            if engine.isStale { await engine.refreshAll() }
        }
    }
}

extension RootView {
    func updateLock() {
        LockWindow.shared.update(locked: lock.isLocked, covered: settings.hideInSwitcher && phase != .active)
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            NightSky()
            Wordmark(size: 34)
        }
        .ignoresSafeArea()
    }
}

struct FloatingTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { t in
                Button {
                    if selection != t {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { selection = t }
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(height: 22)
                        Text(t.title).font(Theme.text(10, .medium)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(selection == t ? Theme.onGold : Theme.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background {
                        if selection == t {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Theme.goldGradient)
                                .shadow(color: Theme.gold.opacity(0.4), radius: 12, y: 4)
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(HomeKindMenu(enabled: t == .home, selection: $selection))
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(hex: 0x0D0F14, alpha: 0.62))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: 560)
    }
}

/// Long-press on the Home tab: jump straight to Images, Videos or GIFs.
private struct HomeKindMenu: ViewModifier {
    let enabled: Bool
    @Binding var selection: AppTab

    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                Button { show(nil) } label: { Label("All", systemImage: "square.grid.2x2") }
                ForEach(MediaKind.allCases, id: \.self) { k in
                    Button { show(k) } label: { Label(k.label, systemImage: k.symbol) }
                }
            }
        } else {
            content
        }
    }

    private func show(_ kind: MediaKind?) {
        let router = Router.shared
        router.homeFilter = kind
        router.home = NavigationPath()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { selection = .home }
    }
}
