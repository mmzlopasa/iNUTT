import SwiftUI

enum AppTab: Int, CaseIterable, Identifiable {
    case home, sites, search, favorites, settings
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .sites: return "Sites"
        case .search: return "Search"
        case .favorites: return "Favorites"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .sites: return "square.grid.2x2.fill"
        case .search: return "magnifyingglass"
        case .favorites: return "heart.fill"
        case .settings: return "gearshape.fill"
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
    @State private var tab: AppTab = .home
    @State private var didStart = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $tab) {
                HomeView(selectedTab: $tab).tag(AppTab.home).toolbar(.hidden, for: .tabBar)
                SitesView().tag(AppTab.sites).toolbar(.hidden, for: .tabBar)
                SearchView().tag(AppTab.search).toolbar(.hidden, for: .tabBar)
                FavoritesView().tag(AppTab.favorites).toolbar(.hidden, for: .tabBar)
                SettingsView().tag(AppTab.settings).toolbar(.hidden, for: .tabBar)
            }
            FloatingTabBar(selection: $tab)
                .padding(.bottom, 6)
        }
        .ignoresSafeArea(.keyboard)
        .background(NightSky())
        .fullScreenCover(item: $viewer.presentation) { p in
            MediaViewer(items: p.items, startIndex: p.index)
                .environmentObject(downloads)
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
            if settings.hideInSwitcher && phase != .active && !lock.isLocked {
                PrivacyCover()
            }
        }
        .overlay {
            if lock.isLocked {
                LockView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: lock.isLocked)
        .task {
            guard !didStart else { return }
            didStart = true
            engine.scheduleBackgroundRefresh()
            if engine.isStale { await engine.refreshAll() }
        }
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
                        Text(t.title).font(Theme.text(10, .medium))
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
