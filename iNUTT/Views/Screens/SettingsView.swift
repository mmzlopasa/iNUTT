import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sites: SiteStore
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var lock: LockManager
    @EnvironmentObject private var engine: FeedEngine
    @State private var showAdd = false
    @State private var cacheSize: Int64 = 0
    @State private var confirmClearCache = false
    @State private var confirmRemovePIN = false
    @State private var backupFile: URL?
    @State private var importing = false
    @State private var importNote: String?
    @ObservedObject private var offline = OfflineStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }

                Section {
                    NavigationLink { ManageSitesView() } label: {
                        row("globe", "Manage sites", value: "\(sites.sites.count)/\(Limits.maxSites)")
                    }
                    Button { showAdd = true } label: { row("plus.circle.fill", "Add links") }
                        .disabled(!sites.canAdd)
                } header: { sectionTitle("Sites") }
                .listRowBackground(rowBG)

                Section {
                    Toggle(isOn: Binding(get: { settings.faceIDEnabled }, set: { v in
                        settings.faceIDEnabled = v
                    })) { row("faceid", LockManager.biometryName) }
                    .disabled(!LockManager.biometryAvailable && !settings.faceIDEnabled)

                    if lock.hasPIN && settings.pinEnabled {
                        NavigationLink { PinSetupView() } label: { row("lock.rotation", "Change PIN") }
                        Button(role: .destructive) { confirmRemovePIN = true } label: { row("lock.open", "Turn off PIN", tint: Theme.err) }
                        NavigationLink { PinSetupView(decoy: true) } label: {
                            row("theatermasks.fill", lock.hasDecoyPIN ? "Change decoy PIN" : "Set up decoy PIN")
                        }
                        if lock.hasDecoyPIN {
                            Button(role: .destructive) { lock.setDecoyPIN(nil); lock.objectWillChange.send() } label: {
                                row("theatermasks", "Turn off decoy PIN", tint: Theme.err)
                            }
                        }
                    } else {
                        NavigationLink { PinSetupView() } label: { row("lock.fill", "Set up PIN lock") }
                    }
                    Toggle(isOn: $settings.lockOnBackground) { row("moon.zzz.fill", "Lock when leaving") }
                    Toggle(isOn: $settings.hideInSwitcher) { row("eye.slash.fill", "Hide content in app switcher") }
                    Toggle(isOn: $settings.shakeToLock) { row("iphone.radiowaves.left.and.right", "Shake to lock") }
                } header: { sectionTitle("Security") } footer: {
                    Text("When enabled, iNUTT asks for \(LockManager.biometryName) or your PIN every time it opens. The decoy PIN opens an empty iNUTT instead of yours. Shake to lock needs a PIN or \(LockManager.biometryName).")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
                .listRowBackground(rowBG)

                Section {
                    NavigationLink { HistoryView() } label: {
                        row("clock.arrow.circlepath", "View and search history", value: "\(library.history.count)")
                    }
                    Toggle(isOn: $settings.privateMode) { row("eye.slash.fill", "Private mode") }
                    Toggle(isOn: $settings.historyEnabled) { row("record.circle", "Save history") }
                        .disabled(settings.privateMode)
                    Button(role: .destructive) { library.clearHistory() } label: { row("trash", "Clear history", tint: Theme.err) }
                        .disabled(library.history.isEmpty)
                    Button(role: .destructive) { ResumeStore.shared.clear() } label: { row("play.slash", "Clear Continue watching", tint: Theme.err) }
                    Button(role: .destructive) { WatchLater.shared.clear() } label: { row("clock.badge.xmark", "Clear Watch later", tint: Theme.err) }
                } header: { sectionTitle("History") } footer: {
                    Text("Private mode remembers nothing: no history, no watched marks, no Continue watching, no recent searches. Also on the eye button on Home.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
                .listRowBackground(rowBG)

                Section {
                    Toggle(isOn: Binding(get: { settings.offlineFavorites }, set: { settings.offlineFavorites = $0; offline.sync() })) {
                        row("arrow.down.circle.fill", "Keep favorites offline")
                    }
                    row("internaldrive", offline.syncing ? "Downloading…" : "Offline files",
                        value: ByteCountFormatter.string(fromByteCount: offline.totalSize, countStyle: .file) + " · \(offline.entries.count)")
                    Button(role: .destructive) { offline.removeAll() } label: { row("trash", "Remove offline files", tint: Theme.err) }
                        .disabled(offline.entries.isEmpty)
                } header: { sectionTitle("Offline") } footer: {
                    Text("Favorites, and collections you mark with \"Keep offline\" (long-press a collection), download on Wi-Fi only and then open without a connection. Streams (HLS) can't be kept.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
                .listRowBackground(rowBG)

                Section {
                    Toggle(isOn: Binding(get: { settings.notifyNew }, set: { v in
                        settings.notifyNew = v
                        if v { Task { _ = await NewContentWatcher.requestPermission(); FeedEngine.shared.scheduleBackgroundRefresh() } }
                    })) { row("bell.badge.fill", "New-content alerts") }
                    Toggle(isOn: $settings.notifyDiscreet) { row("bell.slash", "Discreet text") }
                        .disabled(!settings.notifyNew)
                    row("list.bullet", "Following", value: "\(settings.watchedSites.count) sites · \(settings.watchedForums.count) forums")
                } header: { sectionTitle("Notifications") } footer: {
                    Text("Long-press a site or forum in Sites and pick \"Alert me about new content\". iOS checks in the background when it allows it, usually a few times an hour. Discreet text says only \"New content is waiting\".")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
                .listRowBackground(rowBG)

                Section {
                    Toggle(isOn: $settings.smartMix) { row("sparkles", "Picked for you") }
                    Button(role: .destructive) { Taste.shared.reset() } label: { row("arrow.counterclockwise", "Forget what I like", tint: Theme.err) }
                        .disabled(!settings.smartMix)
                    Toggle(isOn: $settings.hideDuplicates) { row("square.on.square", "Hide duplicates") }
                } header: { sectionTitle("Home") } footer: {
                    Text("Picked for you learns from what you open, save, download and watch to the end, and shows the best matches first. Nothing is learned in private mode. Hide duplicates shows the same picture or video only once when several sites have it. Forums are never shown on Home.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
                .listRowBackground(rowBG)

                Section {
                    Picker(selection: $settings.maxQuality) {
                        Text("4K (2160p)").tag(2160)
                        Text("1440p").tag(1440)
                        Text("1080p").tag(1080)
                        Text("720p").tag(720)
                    } label: { row("4k.tv", "Maximum resolution") }
                    Toggle(isOn: $settings.autoplay) { row("play.circle", "Autoplay") }
                    Toggle(isOn: $settings.loopVideos) { row("repeat", "Loop videos") }
                    Toggle(isOn: $settings.startMuted) { row("speaker.slash", "Start muted") }
                    Toggle(isOn: $settings.reelsAutoNext) { row("arrow.down.to.line.compact", "Reels: next video when one ends") }
                    Toggle(isOn: $settings.hideSeen) { row("eye.slash", "Hide watched on Home") }
                    Picker(selection: $settings.slideshowSeconds) {
                        ForEach([3, 5, 8, 12, 20], id: \.self) { Text("\($0) s").tag($0) }
                    } label: { row("play.square.stack", "Slideshow speed") }
                    Toggle(isOn: $settings.slideshowRandom) { row("shuffle", "Slideshow in random order") }
                    NavigationLink { BlockedWordsView() } label: {
                        row("nosign", "Blocked words", value: settings.blockedWords.isEmpty ? "None" : "\(settings.blockedWords.count)")
                    }
                } header: { sectionTitle("Playback") }
                .listRowBackground(rowBG)

                Section {
                    Toggle(isOn: $settings.vaultDownloads) { row("lock.shield.fill", "Download into the vault") }
                    Toggle(isOn: $settings.saveToPhotos) { row("photo.on.rectangle", "Save to Photos") }
                        .disabled(settings.vaultDownloads)
                    Toggle(isOn: $settings.backgroundRefresh) { row("arrow.triangle.2.circlepath", "Background refresh") }
                    Button { confirmClearCache = true } label: {
                        row("internaldrive", "Clear cache", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    }
                } header: { sectionTitle("Downloads & storage") } footer: {
                    Text(settings.vaultDownloads ? "Downloads are encrypted in the vault (Favorites › shield)." : "Downloads are also saved in the Files app › iNUTT.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
                .listRowBackground(rowBG)

                Section {
                    NavigationLink { SyncSettingsView() } label: {
                        row("arrow.triangle.2.circlepath.icloud", "Sync between devices",
                            value: SyncManager.shared.isConfigured ? "On" : "Off")
                    }
                } header: { sectionTitle("Sync") }
                .listRowBackground(rowBG)

                Section {
                    Button {
                        backupFile = try? Backup.export()
                    } label: { row("square.and.arrow.up", "Export backup") }
                    Button { importing = true } label: { row("square.and.arrow.down", "Restore from backup") }
                    if let importNote {
                        Text(importNote).font(Theme.text(13)).foregroundStyle(Theme.body)
                    }
                } header: { sectionTitle("Backup") } footer: {
                    Text("One file with your sites, forums, favorites, collections and blocked words. It works on iPhone, Android and Windows. Restoring adds to what you have and removes nothing.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
                .listRowBackground(rowBG)

                Section {
                    row("info.circle", "Version", value: appVersion)
                    NavigationLink { LegalView(title: "Privacy", text: LegalText.privacy) } label: { row("hand.raised.fill", "Privacy") }
                    NavigationLink { LegalView(title: "Terms of use", text: LegalText.terms) } label: { row("doc.text.fill", "Terms of use") }
                    Link(destination: URL(string: "https://scyde.dev")!) {
                        row("hammer.fill", "Developer", value: "SCYDE")
                    }
                } header: { sectionTitle("About") } footer: {
                    Text("iNUTT · made by SCYDE · scyde.dev")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity).padding(.top, 10)
                }
                .listRowBackground(rowBG)
            }
            .scrollContentBackground(.hidden)
            .tabBarInset()
            .background(NightSky())
            .toolbar(.hidden, for: .navigationBar)
            .tint(Theme.gold)
            .task { cacheSize = await Task.detached { ImagePipeline.shared.diskUsage() }.value }
            .confirmationDialog("Clear cache?", isPresented: $confirmClearCache, titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    ImagePipeline.shared.clear()
                    engine.clearCache()
                    cacheSize = 0
                }
            } message: { Text("Images and saved content will be loaded again.") }
            .confirmationDialog("Turn off PIN?", isPresented: $confirmRemovePIN, titleVisibility: .visible) {
                Button("Turn off PIN", role: .destructive) { lock.setPIN(nil) }
            }
        }
        .sheet(isPresented: $showAdd) { AddSiteView() }
        .sheet(item: Binding(get: { backupFile.map(ShareFile.init) }, set: { if $0 == nil { backupFile = nil } })) { f in
            ShareSheet(items: [f.url])
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data, .text]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let s = try? Backup.restore(data) else {
                importNote = "That file isn't an iNUTT backup."
                return
            }
            importNote = "Added \(s.sites) sites, \(s.forums) forums, \(s.favorites) favorites and \(s.collections) collections."
        }
    }

    private var rowBG: some View { Theme.navy.opacity(0.6) }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SETTINGS").font(Theme.mono(11)).foregroundStyle(Theme.muted).tracking(1.2)
            Wordmark(size: 30)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.vertical, 6)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(Theme.mono(11)).foregroundStyle(Theme.gold).tracking(1)
    }

    private func row(_ symbol: String, _ title: String, value: String? = nil, tint: Color = Theme.ink) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.onGold)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.goldGradient))
            Text(title).font(Theme.text(15, .medium)).foregroundStyle(tint)
            Spacer(minLength: 4)
            if let value { Text(value).font(Theme.mono(12)).foregroundStyle(Theme.muted) }
        }
    }
}

struct ManageSitesView: View {
    @EnvironmentObject private var sites: SiteStore
    @EnvironmentObject private var engine: FeedEngine
    @State private var showAdd = false

    var body: some View {
        List {
            Section {
                ForEach(sites.sites) { site in
                    NavigationLink { EditSiteView(site: site) } label: {
                        HStack(spacing: 12) {
                            SiteIcon(site: site, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site.name).font(Theme.text(15, .medium)).foregroundStyle(site.enabled ? Theme.ink : Theme.muted)
                                Text(site.url.absoluteString).font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                        }
                    }
                    .listRowBackground(Theme.navy.opacity(0.6))
                }
                .onDelete { idx in
                    let ids = Set(idx.map { sites.sites[$0].id })
                    ids.forEach { engine.forget(siteID: $0) }
                    sites.remove(ids)
                }
                .onMove { sites.move(from: $0, to: $1) }
            } header: {
                Text("\(sites.sites.count) of \(Limits.maxSites) sites").font(Theme.mono(11)).foregroundStyle(Theme.gold)
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightSky())
        .navigationTitle("Sites")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }.disabled(!sites.canAdd)
            }
        }
        .sheet(isPresented: $showAdd) { AddSiteView() }
    }
}

struct AddSiteView: View {
    @EnvironmentObject private var sites: SiteStore
    @EnvironmentObject private var engine: FeedEngine
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var name = ""
    @State private var bulk = false
    @State private var bulkText = ""
    @State private var mode: RenderMode = .auto
    @State private var searchTemplate = ""
    @State private var checking = false
    @State private var preview: ScrapeResult?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("", selection: $bulk) {
                        Text("Single link").tag(false)
                        Text("Multiple links").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                if bulk {
                    Section {
                        TextEditor(text: $bulkText)
                            .font(Theme.mono(13))
                            .frame(minHeight: 180)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .scrollContentBackground(.hidden)
                    } header: { Text("One link per line") } footer: {
                        Text("\(Limits.maxSites - sites.sites.count) sites left.")
                    }
                    .listRowBackground(Theme.navy.opacity(0.6))
                } else {
                    Section {
                        TextField("https://example.com/gallery", text: $urlText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Theme.mono(14))
                        TextField("Name (optional)", text: $name)
                    } header: { Text("Site link") } footer: {
                        Text("A category page, RSS feed or subreddit (r/name) works too.")
                    }
                    .listRowBackground(Theme.navy.opacity(0.6))

                    Section {
                        Picker("Loading", selection: $mode) {
                            ForEach(RenderMode.allCases) { Text($0.label).tag($0) }
                        }
                        TextField("Search template, e.g. https://site.com/search?q={q}", text: $searchTemplate)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Theme.mono(12))
                    } header: { Text("Advanced") }
                    .listRowBackground(Theme.navy.opacity(0.6))

                    if let p = preview {
                        Section {
                            HStack(spacing: 16) {
                                stat("\(p.items.count)", "items")
                                stat("\(p.categories.count)", "categories")
                                stat("\(p.items.filter { $0.kind == .video }.count)", "videos")
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(p.items.prefix(10)) { item in
                                        RemoteImage(url: item.thumbnailURL, referer: item.referer, maxPixel: 300)
                                            .frame(width: 80, height: 100)
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                }
                            }
                        } header: { Text("Preview") }
                        .listRowBackground(Theme.navy.opacity(0.6))
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(Theme.err).font(Theme.text(13)) }
                        .listRowBackground(Theme.navy.opacity(0.6))
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if checking { ProgressView().tint(Theme.onGold) }
                            Text(bulk ? "Add all" : (preview == nil ? "Check & add" : "Save site"))
                            Spacer()
                        }
                    }
                    .buttonStyle(GoldButtonStyle())
                    .disabled(checking || (bulk ? bulkText.isEmpty : urlText.isEmpty))
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(NightSky())
            .navigationTitle("Add site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onChange(of: urlText) { _ in preview = nil; error = nil }
        }
    }

    private func stat(_ v: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(Theme.dot(26)).foregroundStyle(Theme.goldGradient)
            Text(label).font(Theme.mono(10)).foregroundStyle(Theme.muted)
        }
    }

    private func submit() {
        error = nil
        if bulk { addBulk(); return }
        guard let url = SiteStore.normalize(urlText) else { error = "Invalid link."; return }
        guard sites.canAdd else { error = "You have reached the maximum of \(Limits.maxSites) sites."; return }
        var site = Site(name: name.isEmpty ? (url.host?.replacingOccurrences(of: "www.", with: "") ?? "Site") : name, url: url)
        site.renderMode = mode
        site.searchTemplate = searchTemplate.isEmpty ? nil : searchTemplate

        if let p = preview {
            save(site, preview: p)
            return
        }
        checking = true
        Task {
            defer { checking = false }
            do {
                let r = try await FeedEngine.fetchListing(url: url, base: url, site: site, categoryName: nil, allowRender: true)
                if r.items.isEmpty && r.categories.isEmpty {
                    error = "No content found on this page. Try the \"Full (JavaScript)\" mode or another link."
                    preview = r
                } else {
                    preview = r
                    if name.isEmpty, let t = r.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count < 40 {
                        name = t
                    }
                }
            } catch {
                self.error = "Couldn't load the site: \(error.localizedDescription)"
            }
        }
    }

    private func save(_ site: Site, preview p: ScrapeResult) {
        var s = site
        if !name.isEmpty { s.name = name }
        s.categories = p.categories
        s.iconURL = p.iconURL
        guard sites.add(s) else { error = "This site is already added."; return }
        Task { await engine.refresh(s, nil) }
        dismiss()
    }

    private func addBulk() {
        let lines = bulkText.split(whereSeparator: \.isNewline).map(String.init)
        var added: [Site] = []
        for l in lines {
            guard sites.canAdd, let u = SiteStore.normalize(l) else { continue }
            let s = Site(name: u.host?.replacingOccurrences(of: "www.", with: "") ?? "Site", url: u)
            if sites.add(s) { added.append(s) }
        }
        if added.isEmpty { error = "No links were added."; return }
        Task { await engine.refreshAll() }
        dismiss()
    }
}

struct EditSiteView: View {
    let site: Site
    @EnvironmentObject private var sites: SiteStore
    @EnvironmentObject private var engine: FeedEngine
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Site
    @State private var link: String
    @State private var confirmDelete = false

    init(site: Site) {
        self.site = site
        _draft = State(initialValue: site)
        _link = State(initialValue: site.url.absoluteString)
    }

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $draft.name)
                TextField("Link", text: $link)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Theme.mono(13))
                Toggle("Enabled", isOn: $draft.enabled)
            }
            .listRowBackground(Theme.navy.opacity(0.6))

            Section("Loading") {
                Picker("Mode", selection: $draft.renderMode) {
                    ForEach(RenderMode.allCases) { Text($0.label).tag($0) }
                }
                TextField("Search template ({q})", text: Binding(get: { draft.searchTemplate ?? "" }, set: { draft.searchTemplate = $0.isEmpty ? nil : $0 }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Theme.mono(12))
            }
            .listRowBackground(Theme.navy.opacity(0.6))

            Section("Categories (\(draft.categories.count))") {
                if draft.categories.isEmpty {
                    Text("No categories found.").foregroundStyle(Theme.muted)
                }
                ForEach(draft.categories) { c in
                    Text(c.name).font(Theme.text(14))
                }
                .onDelete { draft.categories.remove(atOffsets: $0) }
            }
            .listRowBackground(Theme.navy.opacity(0.6))

            Section {
                Button(role: .destructive) { confirmDelete = true } label: { Text("Remove site") }
            }
            .listRowBackground(Theme.navy.opacity(0.6))
        }
        .scrollContentBackground(.hidden)
        .background(NightSky())
        .navigationTitle(draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let u = SiteStore.normalize(link) { draft.url = u }
                    let urlChanged = draft.url != site.url || draft.renderMode != site.renderMode
                    sites.update(draft)
                    if urlChanged {
                        engine.forget(siteID: draft.id)
                        let d = draft
                        Task { await engine.refresh(d, nil) }
                    }
                    dismiss()
                }
                .disabled(SiteStore.normalize(link) == nil)
            }
        }
        .confirmationDialog("Remove \(draft.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                engine.forget(siteID: site.id)
                sites.remove([site.id])
                dismiss()
            }
        }
    }
}

struct ShareFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Words that hide items everywhere in the app.
struct BlockedWordsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var word = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add a word", text: $word)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Add", action: add).disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("Anything with one of these words in its title, category or link is hidden on Home, in Sites, Reels and Search.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.navy.opacity(0.6))
            Section {
                ForEach(settings.blockedWords, id: \.self) { w in
                    Text(w).font(Theme.text(15)).foregroundStyle(Theme.ink)
                }
                .onDelete { settings.blockedWords.remove(atOffsets: $0) }
            }
            .listRowBackground(Theme.navy.opacity(0.6))
        }
        .scrollContentBackground(.hidden)
        .background(NightSky())
        .navigationTitle("Blocked words")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        let parts = word.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        var list = settings.blockedWords
        for p in parts where !list.contains(p) { list.append(p) }
        settings.blockedWords = list
        word = ""
    }
}

/// Picks the shared folder and passphrase for keeping devices the same.
struct SyncSettingsView: View {
    @ObservedObject private var sync = SyncManager.shared
    @State private var picking = false
    @State private var passphrase = ""

    var body: some View {
        List {
            Section {
                Button { picking = true } label: {
                    HStack {
                        Label("Sync folder", systemImage: "folder").foregroundStyle(Theme.ink)
                        Spacer()
                        Text(sync.folderName ?? "Choose…").foregroundStyle(Theme.muted)
                    }
                }
                HStack {
                    SecureField(sync.hasPassphrase ? "Passphrase is set" : "Sync passphrase", text: $passphrase)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save") {
                        sync.setPassphrase(passphrase)
                        passphrase = ""
                        Task { await sync.sync() }
                    }
                    .disabled(passphrase.trimmingCharacters(in: .whitespaces).count < 6)
                }
            } footer: {
                Text("Choose a folder in iCloud Drive or Google Drive (Files app), then on your other iPhone, Android or Windows device pick the same folder with the same passphrase. Favorites, collections and Watch later are merged; removing something removes it everywhere. The file is encrypted with the passphrase, which must be at least 6 characters and is never uploaded.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.navy.opacity(0.6))

            Section {
                Button {
                    Task { await sync.sync() }
                } label: {
                    HStack {
                        Label(sync.syncing ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if let d = sync.lastSync {
                            Text(d, style: .relative).foregroundStyle(Theme.muted)
                        }
                    }
                }
                .disabled(!sync.isConfigured || sync.syncing)
                if let s = sync.status {
                    Text(s).font(Theme.text(13)).foregroundStyle(Theme.err)
                }
                if sync.folderName != nil {
                    Button(role: .destructive) { sync.stop() } label: { Label("Stop syncing", systemImage: "xmark.circle") }
                }
            }
            .listRowBackground(Theme.navy.opacity(0.6))
        }
        .scrollContentBackground(.hidden)
        .background(NightSky())
        .navigationTitle("Sync between devices")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                sync.setFolder(url)
                Task { await sync.sync() }
            }
        }
    }
}
