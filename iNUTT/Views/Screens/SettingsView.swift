import SwiftUI

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
                    } else {
                        NavigationLink { PinSetupView() } label: { row("lock.fill", "Set up PIN lock") }
                    }
                    Toggle(isOn: $settings.lockOnBackground) { row("moon.zzz.fill", "Lock when leaving") }
                    Toggle(isOn: $settings.hideInSwitcher) { row("eye.slash.fill", "Hide content in app switcher") }
                } header: { sectionTitle("Security") } footer: {
                    Text("When enabled, iNUTT asks for \(LockManager.biometryName) or your PIN every time it opens.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
                .listRowBackground(rowBG)

                Section {
                    NavigationLink { HistoryView() } label: {
                        row("clock.arrow.circlepath", "View and search history", value: "\(library.history.count)")
                    }
                    Toggle(isOn: $settings.historyEnabled) { row("record.circle", "Save history") }
                    Button(role: .destructive) { library.clearHistory() } label: { row("trash", "Clear history", tint: Theme.err) }
                        .disabled(library.history.isEmpty)
                } header: { sectionTitle("History") }
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
                } header: { sectionTitle("Playback") }
                .listRowBackground(rowBG)

                Section {
                    Toggle(isOn: $settings.saveToPhotos) { row("photo.on.rectangle", "Save to Photos") }
                    Toggle(isOn: $settings.backgroundRefresh) { row("arrow.triangle.2.circlepath", "Background refresh") }
                    Button { confirmClearCache = true } label: {
                        row("internaldrive", "Clear cache", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    }
                } header: { sectionTitle("Downloads & storage") } footer: {
                    Text("Preuzimanja se uvijek spremaju i u aplikaciju Datoteke › iNUTT.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
                .listRowBackground(rowBG)

                Section {
                    row("info.circle", "Version", value: appVersion)
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
    @State private var confirmDelete = false

    init(site: Site) {
        self.site = site
        _draft = State(initialValue: site)
    }

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $draft.name)
                TextField("Link", text: Binding(get: { draft.url.absoluteString }, set: { if let u = SiteStore.normalize($0) { draft.url = u } }))
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
                    let urlChanged = draft.url != site.url || draft.renderMode != site.renderMode
                    sites.update(draft)
                    if urlChanged {
                        engine.forget(siteID: draft.id)
                        let d = draft
                        Task { await engine.refresh(d, nil) }
                    }
                    dismiss()
                }
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
