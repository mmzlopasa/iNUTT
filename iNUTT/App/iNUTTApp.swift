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
}
