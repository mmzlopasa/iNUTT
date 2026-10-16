import SwiftUI
import WebKit

/// The social networks the Social tab can show. You sign in on the network's own page.
enum SocialNetwork: String, CaseIterable, Identifiable {
    case instagram, tiktok
    var id: String { rawValue }

    var title: String { self == .instagram ? "Instagram" : "TikTok" }
    var symbol: String { self == .instagram ? "camera.fill" : "music.note" }
    var home: URL { URL(string: self == .instagram ? "https://www.instagram.com/" : "https://www.tiktok.com/foryou")! }
    var domain: String { self == .instagram ? "instagram" : "tiktok" }
}

/// One web view per network, kept alive so switching tabs keeps your place and sign-in.
@MainActor
final class SocialWebs: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = SocialWebs()

    @Published var loading: Set<SocialNetwork> = []
    @Published var canGoBack: Set<SocialNetwork> = []
    private var webs: [SocialNetwork: WKWebView] = [:]

    func web(_ n: SocialNetwork) -> WKWebView {
        if let w = webs[n] { return w }
        let config = WKWebViewConfiguration()
        // The default store is persistent, so you stay signed in between launches.
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: config)
        w.customUserAgent = Net.userAgent
        w.allowsBackForwardNavigationGestures = true
        w.isOpaque = false
        w.backgroundColor = .black
        w.scrollView.backgroundColor = .black
        w.navigationDelegate = self
        w.uiDelegate = self
        w.accessibilityIdentifier = n.rawValue
        w.load(URLRequest(url: n.home))
        webs[n] = w
        return w
    }

    func reload(_ n: SocialNetwork) { webs[n]?.reload() }
    func goBack(_ n: SocialNetwork) { webs[n]?.goBack() }
    func goHome(_ n: SocialNetwork) { webs[n]?.load(URLRequest(url: n.home)) }

    /// Clears that network's cookies and storage, then shows its sign-in page again.
    func signOut(_ n: SocialNetwork) async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let mine = records.filter { $0.displayName.lowercased().contains(n.domain) }
        await store.removeData(ofTypes: types, for: mine)
        goHome(n)
    }

    private func network(of web: WKWebView) -> SocialNetwork? {
        web.accessibilityIdentifier.flatMap(SocialNetwork.init(rawValue:))
    }

    private func update(_ web: WKWebView, loading isLoading: Bool) {
        guard let n = network(of: web) else { return }
        if isLoading { loading.insert(n) } else { loading.remove(n) }
        if web.canGoBack { canGoBack.insert(n) } else { canGoBack.remove(n) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { update(webView, loading: true) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { update(webView, loading: false) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { update(webView, loading: false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        update(webView, loading: false)
    }

    /// Stay inside the app: "open in app" links and app-store redirects are ignored.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let scheme = action.request.url?.scheme?.lowercased() else { return decisionHandler(.allow) }
        decisionHandler(["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
    }

    /// Links that want a new window (sign-in pop-ups, shared posts) open in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}

struct SocialWebView: UIViewRepresentable {
    let network: SocialNetwork

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .black
        attach(to: host)
        return host
    }

    func updateUIView(_ host: UIView, context: Context) { attach(to: host) }

    private func attach(to host: UIView) {
        let web = SocialWebs.shared.web(network)
        guard web.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            web.topAnchor.constraint(equalTo: host.topAnchor),
            web.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}

/// Instagram and TikTok, signed in with your own accounts, one tap apart.
struct SocialView: View {
    @AppStorage("socialNetwork") private var selectedRaw = SocialNetwork.instagram.rawValue
    @ObservedObject private var webs = SocialWebs.shared
    @State private var confirmSignOut = false

    private var network: SocialNetwork { SocialNetwork(rawValue: selectedRaw) ?? .instagram }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            SocialWebView(network: network)
                .id(network)
                .overlay(alignment: .top) {
                    if webs.loading.contains(network) {
                        ProgressView().tint(Theme.gold).padding(.top, 12)
                    }
                }
                .padding(.bottom, 74)
        }
        .background(Color.black.ignoresSafeArea())
        .confirmationDialog("Sign out of \(network.title)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await webs.signOut(network) } }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            ForEach(SocialNetwork.allCases) { n in
                Chip(title: n.title, symbol: n.symbol, selected: n == network) {
                    if n == network { webs.goHome(n) } else { selectedRaw = n.rawValue }
                }
            }
            Spacer(minLength: 4)
            if webs.canGoBack.contains(network) {
                icon("chevron.left") { webs.goBack(network) }
            }
            icon("arrow.clockwise") { webs.reload(network) }
            Menu {
                Button { webs.goHome(network) } label: { Label("Home", systemImage: "house") }
                Button(role: .destructive) { confirmSignOut = true } label: {
                    Label("Sign out of \(network.title)", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                iconLabel("ellipsis")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(hex: 0x0D0F14))
    }

    private func icon(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { iconLabel(symbol) }.buttonStyle(.plain)
    }

    private func iconLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.white.opacity(0.06)))
    }
}
