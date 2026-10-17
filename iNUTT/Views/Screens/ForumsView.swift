import SwiftUI
import WebKit

// MARK: - Store

struct Forum: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: URL
    /// Where you left off, so the forum reopens on the same thread.
    var lastURL: URL?
}

@MainActor
final class ForumStore: ObservableObject {
    static let shared = ForumStore()
    @Published private(set) var forums: [Forum] = []

    private init() { forums = Disk.load([Forum].self, "forums.json") ?? [] }

    func add(name: String, link: String) -> Bool {
        guard let u = SiteStore.normalize(link) else { return false }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        forums.append(Forum(name: n.isEmpty ? (u.host ?? "Forum").replacingOccurrences(of: "www.", with: "") : n, url: u))
        save()
        return true
    }

    func remove(_ f: Forum) {
        forums.removeAll { $0.id == f.id }
        save()
    }

    func move(from: IndexSet, to: Int) {
        forums.move(fromOffsets: from, toOffset: to)
        save()
    }

    func remember(_ id: UUID, url: URL?) {
        guard let i = forums.firstIndex(where: { $0.id == id }), forums[i].lastURL != url else { return }
        forums[i].lastURL = url
        save()
    }

    private func save() { Disk.save(forums, "forums.json") }
}

// MARK: - List

/// Forums you browse inside the app, signed in, with every picture and video of a thread one tap away.
struct ForumsSection: View {
    @ObservedObject private var store = ForumStore.shared
    @State private var showAdd = false
    @State private var open: BrowserTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(store.forums.count) forums").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                Spacer()
                Button { showAdd = true } label: { Label("Add forum", systemImage: "plus") }
                    .buttonStyle(GhostButtonStyle())
            }
            if store.forums.isEmpty {
                EmptyStateView(symbol: "bubble.left.and.bubble.right.fill", title: "No forums",
                               message: "Add the forums you read. They open right here, you stay signed in, and the Media button shows every picture and video of a thread in the viewer.",
                               buttonTitle: "Add forum") { showAdd = true }
            } else {
                ForEach(store.forums) { f in
                    Button {
                        open = BrowserTarget(url: f.lastURL ?? f.url, title: f.name, forumID: f.id)
                    } label: {
                        ForumRow(forum: f)
                    }
                    .buttonStyle(CardPressStyle())
                    .contextMenu {
                        Button { open = BrowserTarget(url: f.url, title: f.name, forumID: f.id) } label: {
                            Label("Open start page", systemImage: "house")
                        }
                        WatchToggle(id: f.id, forum: true)
                        Button(role: .destructive) { store.remove(f) } label: { Label("Remove", systemImage: "trash") }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .sheet(isPresented: $showAdd) { AddForumView() }
        .fullScreenCover(item: $open) { t in WebBrowserView(target: t) }
    }
}

private struct ForumRow: View {
    let forum: Forum
    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: URL(string: "/favicon.ico", relativeTo: forum.url)?.absoluteURL, referer: nil, maxPixel: 96)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 3) {
                Text(forum.name).font(Theme.display(16, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(forum.lastURL != nil ? "Continue where you left off" : (forum.url.host ?? ""))
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.edge, lineWidth: 0.6))
    }
}

struct AddForumView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var link = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $name)
                    TextField("forum.example.com", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(Theme.mono(14))
                } footer: {
                    Text("Sign in once inside the forum; iNUTT keeps you signed in.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(NightSky().ignoresSafeArea())
            .navigationTitle("Add forum")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { if ForumStore.shared.add(name: name, link: link) { dismiss() } }
                        .disabled(SiteStore.normalize(link) == nil)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Browser

struct BrowserTarget: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var forumID: UUID?
}

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let web: WKWebView
    @Published var title = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loading = false
    @Published var progress: Double = 0
    private var observers: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default()
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        web.customUserAgent = Net.userAgent
        web.allowsBackForwardNavigationGestures = true
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = .black
        observers = [
            web.observe(\.title) { [weak self] w, _ in Task { @MainActor in self?.title = w.title ?? "" } },
            web.observe(\.canGoBack) { [weak self] w, _ in Task { @MainActor in self?.canGoBack = w.canGoBack } },
            web.observe(\.canGoForward) { [weak self] w, _ in Task { @MainActor in self?.canGoForward = w.canGoForward } },
            web.observe(\.isLoading) { [weak self] w, _ in Task { @MainActor in self?.loading = w.isLoading } },
            web.observe(\.estimatedProgress) { [weak self] w, _ in Task { @MainActor in self?.progress = w.estimatedProgress } },
        ]
    }

    func load(_ url: URL) {
        Task {
            await SiteAdapters.prepare(url, store: web.configuration.websiteDataStore.httpCookieStore)
            web.load(Net.request(url))
        }
    }

    /// Links that open a new window (target=_blank) stay in this browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    /// Every picture and video on the page, full size where the page links to it.
    func collectMedia(siteName: String) async -> [MediaItem] {
        guard let json = try? await web.evaluateJavaScript(Self.mediaScript) as? String,
              let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]] else { return [] }
        let base = web.url ?? URL(string: "https://example.com")!
        let siteID = UUID(uuidString: "00000000-0000-0000-0000-0000000F0A0B")!
        var seen = Set<String>()
        return list.compactMap { d in
            let media = HTML.resolve(d["m"], base: base)
            let page = HTML.resolve(d["p"], base: base)
            let thumb = HTML.resolve(d["t"], base: base) ?? media
            guard media != nil || page != nil else { return nil }
            let key = (media ?? page)!.absoluteString
            guard seen.insert(key).inserted else { return nil }
            let kind: MediaKind = d["k"] == "v" ? .video : (MediaKind.guess(from: media) ?? MediaKind.guess(from: thumb) ?? .image)
            // The forum page is sent as referer, so image hosts that block hot-linking still answer.
            var item = MediaItem(siteID: siteID, siteName: siteName, title: d["n"] ?? "", thumbnailURL: thumb,
                                 mediaURL: media, pageURL: media == nil ? page : base, kind: kind)
            item.id = MediaItem.hash(key)
            return item
        }
    }

    static let mediaScript = #"""
    (function(){
      var out=[], seen={};
      var file=/\.(jpe?g|png|webp|gif|mp4|webm|m3u8|mov)(\?|#|$)/i, img=/\.(jpe?g|png|webp|gif)(\?|#|$)/i;
      function add(o){ var k=o.m||o.p; if(!k||seen[k])return; seen[k]=1; out.push(o); }
      function big(i){ var w=i.naturalWidth||i.width, h=i.naturalHeight||i.height; return w>=120&&h>=90; }
      function src(i){ return i.currentSrc||i.src||i.getAttribute('data-src')||i.getAttribute('data-url')||''; }
      document.querySelectorAll('a[href] img').forEach(function(i){
        var a=i.closest('a'); var h=a.href||''; if(!big(i)&&!(i.getAttribute('data-src'))) return;
        if(/avatar|smilie|smiley|emoji|icon|logo|rank|badge|banner|signature/i.test(src(i)+' '+i.className)) return;
        if(file.test(h)) add({m:h,t:src(i),k:/\.(mp4|webm|m3u8|mov)/i.test(h)?'v':'i',n:i.alt||''});
        else if(/^https?:/i.test(h)&&!/#|javascript:/i.test(h)) add({p:h,t:src(i),k:'i',n:i.alt||''});
      });
      document.querySelectorAll('img').forEach(function(i){
        if(i.closest('a[href]')) return; var s=src(i); if(!s||!big(i)) return;
        if((i.naturalWidth||i.width)<300) return;
        if(/avatar|smilie|smiley|emoji|icon|logo|rank|badge|banner|signature/i.test(s+' '+i.className)) return;
        add({m:s,t:s,k:'i',n:i.alt||''});
      });
      document.querySelectorAll('a[href]').forEach(function(a){ if(/\.(mp4|webm|m3u8|mov)(\?|#|$)/i.test(a.href)) add({m:a.href,k:'v',n:(a.innerText||'').trim().slice(0,80)}); });
      document.querySelectorAll('video').forEach(function(v){
        var s=v.currentSrc||v.src; if((!s||s.indexOf('blob:')===0)){ var so=v.querySelector('source'); s=so?so.src:''; }
        if(s&&s.indexOf('blob:')!==0) add({m:s,t:v.poster||'',k:'v'});
      });
      document.querySelectorAll('iframe[src]').forEach(function(f){ if(/embed|player|video/i.test(f.src)) add({p:f.src,k:'v'}); });
      return JSON.stringify(out.slice(0,500));
    })()
    """#
}

/// A full-screen browser for forums and for opening any item's original page.
struct WebBrowserView: View {
    let target: BrowserTarget
    @StateObject private var model = BrowserModel()
    @StateObject private var viewer = ViewerState()
    @Environment(\.dismiss) private var dismiss
    @State private var viewerItems: ViewerPresentation?
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack(alignment: .top) {
                WebViewHost(web: model.web).ignoresSafeArea(edges: .bottom)
                if model.loading {
                    GeometryReader { g in
                        Rectangle().fill(Theme.goldGradient).frame(width: g.size.width * model.progress, height: 2)
                    }
                    .frame(height: 2)
                }
                if let note {
                    Text(note).font(Theme.text(13, .medium)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(Capsule().fill(Theme.navy.opacity(0.9)))
                        .padding(.top, 12)
                        .transition(.opacity)
                }
            }
            bottomBar
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { model.load(target.url) }
        .onDisappear {
            if let id = target.forumID { ForumStore.shared.remember(id, url: model.web.url) }
            // Whatever you signed in to here works on Home and in Sites too.
            Task { await CookieSync.pull() }
        }
        .fullScreenCover(item: $viewerItems) { p in
            MediaViewer(items: p.items, startIndex: p.index)
                .environmentObject(Library.shared)
                .environmentObject(DownloadManager.shared)
                .environmentObject(viewer)
                .environmentObject(AppSettings.shared)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: { icon("xmark") }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title.isEmpty ? target.title : model.title)
                    .font(Theme.display(14, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(model.web.url?.host ?? target.url.host ?? "").font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Button { model.web.reload() } label: { icon("arrow.clockwise") }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.navy)
    }

    private var bottomBar: some View {
        HStack(spacing: 18) {
            Button { model.web.goBack() } label: { icon("chevron.left") }.disabled(!model.canGoBack).opacity(model.canGoBack ? 1 : 0.4)
            Button { model.web.goForward() } label: { icon("chevron.right") }.disabled(!model.canGoForward).opacity(model.canGoForward ? 1 : 0.4)
            Spacer()
            Button { addAsSite() } label: { icon("plus.rectangle.on.rectangle") }
            Button { Task { await downloadAll() } } label: { icon("arrow.down.to.line") }
            Button { Task { await showMedia() } } label: {
                Label("Media", systemImage: "photo.stack.fill")
                    .font(Theme.text(14, .semibold))
            }
            .buttonStyle(GoldButtonStyle())
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.navy.ignoresSafeArea(edges: .bottom))
    }

    private func icon(_ s: String) -> some View {
        Image(systemName: s).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Color.white.opacity(0.07)))
    }

    private func showMedia() async {
        let items = await model.collectMedia(siteName: target.title)
        guard !items.isEmpty else { flash("No pictures or videos on this page"); return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        viewerItems = ViewerPresentation(items: items, index: 0)
    }

    /// Every picture and video on the page, downloaded one after another.
    private func downloadAll() async {
        let items = await model.collectMedia(siteName: target.title)
        guard !items.isEmpty else { flash("No pictures or videos on this page"); return }
        DownloadManager.shared.downloadAll(items)
        flash("Downloading \(items.count) items")
    }

    /// The page you are on becomes a site, so its media shows up on Home and in Sites.
    private func addAsSite() {
        guard let u = model.web.url else { return }
        let name = model.title.isEmpty ? (u.host ?? "Page") : String(model.title.prefix(40))
        let site = Site(name: name, url: u)
        if SiteStore.shared.add(site) {
            Task { await FeedEngine.shared.refreshForHome(site, allowRender: true) }
            flash("Added to Sites")
        } else {
            flash("Couldn't add this page")
        }
    }

    private func flash(_ s: String) {
        withAnimation { note = s }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { note = nil }
        }
    }
}

private struct WebViewHost: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
