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
        @Published var decoy = false
    }

    private struct Overlay: View {
        @ObservedObject var state: OverlayState
        var body: some View {
            ZStack {
                if state.locked {
                    LockView().transition(.opacity)
                } else if state.decoy {
                    DecoyView()
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

    func update(locked: Bool, covered: Bool, decoy: Bool = false) {
        state.locked = locked
        state.decoy = decoy && !locked
        state.covered = covered && !locked
        let show = locked || covered || state.decoy
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
            if locked || state.decoy { window.makeKeyAndVisible() }
        } else {
            // Let the fade-out finish before the window goes away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.state.locked, !self.state.covered, !self.state.decoy else { return }
                window.isHidden = true
                window.resignKey()
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?
                    .windows.first { $0 !== window }?.makeKey()
            }
        }
    }
}

/// What the decoy PIN opens: iNUTT as if it had never been set up.
private struct DecoyView: View {
    @State private var tab = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            NightSky()
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Wordmark(size: 28)
                    Spacer()
                    Image(systemName: "gearshape.fill").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.ink).frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                }
                .padding(.horizontal, 16)
                EmptyStateView(symbol: tab == 0 ? "sparkles" : "heart",
                               title: tab == 0 ? "Welcome to iNUTT" : "No favorites yet",
                               message: tab == 0 ? "Add sites with images, GIFs and videos to see them here." : "Tap the heart in the viewer or long-press a card.")
                    .padding(.horizontal, 16)
                Spacer()
            }
            .padding(.top, 60)
            HStack(spacing: 4) {
                ForEach(Array(["house.fill", "heart.fill"].enumerated()), id: \.offset) { i, s in
                    Button { tab = i } label: {
                        Image(systemName: s).font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(tab == i ? Theme.onGold : Theme.muted)
                            .frame(maxWidth: .infinity).frame(height: 54)
                            .background { if tab == i { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.goldGradient) } }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(hex: 0x0D0F14, alpha: 0.8)))
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
        .ignoresSafeArea()
    }
}
