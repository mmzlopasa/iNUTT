import SwiftUI
import UIKit

/// Shows the lock screen and the app-switcher cover in their own window above everything,
/// including the full-screen viewer and any open sheet, so nothing can be seen or used while locked.
@MainActor
final class LockWindow {
    static let shared = LockWindow()

    private var window: UIWindow?
    private let state = OverlayState()

    final class OverlayState: ObservableObject {
        @Published var locked = false
        @Published var covered = false
    }

    private struct Overlay: View {
        @ObservedObject var state: OverlayState
        var body: some View {
            ZStack {
                if state.locked {
                    LockView().transition(.opacity)
                } else if state.covered {
                    PrivacyCover()
                }
            }
            .animation(.easeInOut(duration: 0.25), value: state.locked)
            .environmentObject(LockManager.shared)
            .environmentObject(AppSettings.shared)
            .preferredColorScheme(.dark)
            .tint(Theme.gold)
        }
    }

    func update(locked: Bool, covered: Bool) {
        state.locked = locked
        state.covered = covered && !locked
        let show = locked || covered
        if show, window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let w = UIWindow(windowScene: scene)
            w.windowLevel = .alert + 1
            let host = UIHostingController(rootView: Overlay(state: state))
            host.view.backgroundColor = .clear
            w.rootViewController = host
            w.backgroundColor = .clear
            window = w
        }
        guard let window else { return }
        if show {
            window.isHidden = false
            if locked { window.makeKeyAndVisible() }
        } else {
            // Let the fade-out finish before the window goes away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.state.locked, !self.state.covered else { return }
                window.isHidden = true
                window.resignKey()
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?
                    .windows.first { $0 !== window }?.makeKey()
            }
        }
    }
}
