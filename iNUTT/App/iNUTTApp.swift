import SwiftUI
import AVFoundation

@main
struct iNUTTApp: App {
    @StateObject private var sites = SiteStore.shared
    @StateObject private var library = Library.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var engine = FeedEngine.shared
    @StateObject private var lock = LockManager.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var viewer = ViewerState()
    @StateObject private var router = Router.shared
    @Environment(\.scenePhase) private var phase

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.largeTitleTextAttributes = [.font: UIFont(name: "Sora-Bold", size: 32) ?? .boldSystemFont(ofSize: 32),
                                        .foregroundColor: UIColor(Theme.ink)]
        nav.titleTextAttributes = [.font: UIFont(name: "Sora-SemiBold", size: 17) ?? .boldSystemFont(ofSize: 17),
                                   .foregroundColor: UIColor(Theme.ink)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = UIColor(Theme.gold)
        UITableView.appearance().backgroundColor = .clear
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sites)
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(engine)
                .environmentObject(lock)
                .environmentObject(downloads)
                .environmentObject(viewer)
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .tint(Theme.gold)
        }
        .onChange(of: phase) { newPhase in
            switch newPhase {
            case .background:
                lock.lockIfNeeded()
                engine.saveNow()
                engine.scheduleBackgroundRefresh()
            case .active:
                if engine.isStale { Task { await engine.refreshAll() } }
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(FeedEngine.refreshTaskID)) {
            await FeedEngine.shared.backgroundRefresh()
        }
    }
}

struct ViewerPresentation: Identifiable {
    let id = UUID()
    var items: [MediaItem]
    var index: Int
}

@MainActor
final class ViewerState: ObservableObject {
    @Published var presentation: ViewerPresentation?

    func present(_ items: [MediaItem], at index: Int) {
        guard items.indices.contains(index) else { return }
        // Keep the pager light: a window around the tapped item.
        let lower = max(0, index - 150)
        let upper = min(items.count, index + 150)
        presentation = ViewerPresentation(items: Array(items[lower..<upper]), index: index - lower)
    }

    /// Opens a tapped item: category tiles navigate to their grid, media opens in the viewer.
    func open(_ items: [MediaItem], at index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        if let c = SiteStore.shared.site(item.siteID)?.category(matching: item.pageURL) {
            Router.shared.push(SiteRoute(siteID: item.siteID, category: c))
            return
        }
        if item.isListing == true, let c = item.asCategory {
            Router.shared.push(SiteRoute(siteID: item.siteID, category: c))
            return
        }
        // Keep category tiles out of the pager.
        let media = items.filter { $0.isListing != true }
        present(media, at: media.firstIndex(of: item) ?? 0)
    }

    /// Called from the viewer when an item turned out to be a category page.
    func openListing(_ item: MediaItem) {
        guard let c = item.asCategory else { return }
        presentation = nil
        Task { @MainActor in
            // Let the viewer finish closing before navigating.
            try? await Task.sleep(nanoseconds: 450_000_000)
            Router.shared.push(SiteRoute(siteID: item.siteID, category: c))
        }
    }
}

/// Navigation state of every tab, so any screen (and the viewer) can open a site or category.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    @Published var tab: AppTab = .home
    @Published var home = NavigationPath()
    @Published var sites = NavigationPath()
    @Published var search = NavigationPath()
    @Published var favorites = NavigationPath()

    func push(_ route: SiteRoute) {
        switch tab {
        case .home: home.append(route)
        case .search: search.append(route)
        case .favorites: favorites.append(route)
        case .sites: sites.append(route)
        case .reels:
            tab = .sites
            sites.append(route)
        }
    }
}
