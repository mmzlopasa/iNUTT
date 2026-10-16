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
                        row("globe", "Upravljaj stranicama", value: "\(sites.sites.count)/\(Limits.maxSites)")
                    }
                    Button { showAdd = true } label: { row("plus.circle.fill", "Dodaj linkove") }
                        .disabled(!sites.canAdd)
                } header: { sectionTitle("Stranice") }
                .listRowBackground(rowBG)

                Section {
                    Toggle(isOn: Binding(get: { settings.faceIDEnabled }, set: { v in
                        settings.faceIDEnabled = v
                    })) { row("faceid", LockManager.biometryName) }
                    .disabled(!LockManager.biometryAvailable && !settings.faceIDEnabled)

                    if lock.hasPIN && settings.pinEnabled {
                        NavigationLink { PinSetupView() } label: { row("lock.rotation", "Promijeni PIN") }
                        Button(role: .destructive) { confirmRemovePIN = true } label: { row("lock.open", "Isključi PIN", tint: Theme.err) }
                    } else {
                        NavigationLink { PinSetupView() } label: { row("lock.fill", "Postavi PIN zaključavanje") }
                    }
                    Toggle(isOn: $settings.lockOnBackground) { row("moon.zzz.fill", "Zaključaj pri izlasku") }
                    Toggle(isOn: $settings.hideInSwitcher) { row("eye.slash.fill", "Sakrij sadržaj u multitaskingu") }
                } header: { sectionTitle("Sigurnost") } footer: {
                    Text("Kad je uključeno, iNUTT traži \(LockManager.biometryName) ili PIN pri svakom otvaranju.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
                .listRowBackground(rowBG)

                Section {
                    NavigationLink { HistoryView() } label: {
                        row("clock.arrow.circlepath", "Pregled i pretraga povijesti", value: "\(library.history.count)")
                    }
                    Toggle(isOn: $settings.historyEnabled) { row("record.circle", "Spremaj povijest") }
                    Button(role: .destructive) { library.clearHistory() } label: { row("trash", "Očisti povijest", tint: Theme.err) }
                        .disabled(library.history.isEmpty)
                } header: { sectionTitle("Povijest") }
                .listRowBackground(rowBG)

                Section {
                    Picker(selection: $settings.maxQuality) {
                        Text("4K (2160p)").tag(2160)
                        Text("1440p").tag(1440)
                        Text("1080p").tag(1080)
                        Text("720p").tag(720)
                    } label: { row("4k.tv", "Maksimalna rezolucija") }
                    Toggle(isOn: $settings.autoplay) { row("play.circle", "Automatska reprodukcija") }
                    Toggle(isOn: $settings.loopVideos) { row("repeat", "Ponavljaj videe") }
                    Toggle(isOn: $settings.startMuted) { row("speaker.slash", "Pokreni bez zvuka") }
                } header: { sectionTitle("Reprodukcija") }
                .listRowBackground(rowBG)

                Section {
                    Toggle(isOn: $settings.saveToPhotos) { row("photo.on.rectangle", "Spremaj u Fotografije") }
                    Toggle(isOn: $settings.backgroundRefresh) { row("arrow.triangle.2.circlepath", "Osvježavanje u pozadini") }
                    Button { confirmClearCache = true } label: {
                        row("internaldrive", "Očisti predmemoriju", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    }
                } header: { sectionTitle("Preuzimanja i pohrana") } footer: {
                    Text("Preuzimanja se uvijek spremaju i u aplikaciju Datoteke › iNUTT.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
                .listRowBackground(rowBG)

                Section {
                    row("info.circle", "Verzija", value: appVersion)
                    Link(destination: URL(string: "https://scyde.dev")!) {
                        row("hammer.fill", "Developer", value: "SCYDE")
                    }
                } header: { sectionTitle("O aplikaciji") } footer: {
                    Text("iNUTT · izradio SCYDE · scyde.dev")
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
            .confirmationDialog("Očistiti predmemoriju?", isPresented: $confirmClearCache, titleVisibility: .visible) {
                Button("Očisti", role: .destructive) {
                    ImagePipeline.shared.clear()
                    engine.clearCache()
                    cacheSize = 0
                }
            } message: { Text("Slike i spremljeni sadržaj će se ponovno učitati.") }
            .confirmationDialog("Isključiti PIN?", isPresented: $confirmRemovePIN, titleVisibility: .visible) {
                Button("Isključi PIN", role: .destructive) { lock.setPIN(nil) }
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
            Text("POSTAVKE").font(Theme.mono(11)).foregroundStyle(Theme.muted).tracking(1.2)
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
                Text("\(sites.sites.count) od \(Limits.maxSites) stranica").font(Theme.mono(11)).foregroundStyle(Theme.gold)
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightSky())
        .navigationTitle("Stranice")
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
                        Text("Jedan link").tag(false)
                        Text("Više linkova").tag(true)
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
                    } header: { Text("Jedan link po retku") } footer: {
                        Text("Može još \(Limits.maxSites - sites.sites.count) stranica.")
                    }
                    .listRowBackground(Theme.navy.opacity(0.6))
                } else {
                    Section {
                        TextField("https://primjer.com/galerija", text: $urlText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Theme.mono(14))
                        TextField("Naziv (neobavezno)", text: $name)
                    } header: { Text("Link stranice") } footer: {
                        Text("Može i link na kategoriju, RSS feed ili subreddit.")
                    }
                    .listRowBackground(Theme.navy.opacity(0.6))

                    Section {
                        Picker("Učitavanje", selection: $mode) {
                            ForEach(RenderMode.allCases) { Text($0.label).tag($0) }
                        }
                        TextField("Predložak pretrage, npr. https://site.com/search?q={q}", text: $searchTemplate)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Theme.mono(12))
                    } header: { Text("Napredno") }
                    .listRowBackground(Theme.navy.opacity(0.6))

                    if let p = preview {
                        Section {
                            HStack(spacing: 16) {
                                stat("\(p.items.count)", "stavki")
                                stat("\(p.categories.count)", "kategorija")
                                stat("\(p.items.filter { $0.kind == .video }.count)", "videa")
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
                        } header: { Text("Pregled") }
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
                            Text(bulk ? "Dodaj sve" : (preview == nil ? "Provjeri i dodaj" : "Spremi stranicu"))
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
            .navigationTitle("Dodaj stranicu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Odustani") { dismiss() } }
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
        guard let url = SiteStore.normalize(urlText) else { error = "Neispravan link."; return }
        guard sites.canAdd else { error = "Dosegnut je maksimum od \(Limits.maxSites) stranica."; return }
        var site = Site(name: name.isEmpty ? (url.host?.replacingOccurrences(of: "www.", with: "") ?? "Stranica") : name, url: url)
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
                    error = "Na stranici nije pronađen sadržaj. Probaj način \"Puno (JavaScript)\" ili drugi link."
                    preview = r
                } else {
                    preview = r
                    if name.isEmpty, let t = r.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count < 40 {
                        name = t
                    }
                }
            } catch {
                self.error = "Stranica se ne može učitati: \(error.localizedDescription)"
            }
        }
    }

    private func save(_ site: Site, preview p: ScrapeResult) {
        var s = site
        if !name.isEmpty { s.name = name }
        s.categories = p.categories
        s.iconURL = p.iconURL
        guard sites.add(s) else { error = "Stranica je već dodana."; return }
        Task { await engine.refresh(s, nil) }
        dismiss()
    }

    private func addBulk() {
        let lines = bulkText.split(whereSeparator: \.isNewline).map(String.init)
        var added: [Site] = []
        for l in lines {
            guard sites.canAdd, let u = SiteStore.normalize(l) else { continue }
            let s = Site(name: u.host?.replacingOccurrences(of: "www.", with: "") ?? "Stranica", url: u)
            if sites.add(s) { added.append(s) }
        }
        if added.isEmpty { error = "Nijedan link nije dodan."; return }
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
            Section("Osnovno") {
                TextField("Naziv", text: $draft.name)
                TextField("Link", text: Binding(get: { draft.url.absoluteString }, set: { if let u = SiteStore.normalize($0) { draft.url = u } }))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Theme.mono(13))
                Toggle("Uključena", isOn: $draft.enabled)
            }
            .listRowBackground(Theme.navy.opacity(0.6))

            Section("Učitavanje") {
                Picker("Način", selection: $draft.renderMode) {
                    ForEach(RenderMode.allCases) { Text($0.label).tag($0) }
                }
                TextField("Predložak pretrage ({q})", text: Binding(get: { draft.searchTemplate ?? "" }, set: { draft.searchTemplate = $0.isEmpty ? nil : $0 }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Theme.mono(12))
            }
            .listRowBackground(Theme.navy.opacity(0.6))

            Section("Kategorije (\(draft.categories.count))") {
                if draft.categories.isEmpty {
                    Text("Nisu pronađene kategorije.").foregroundStyle(Theme.muted)
                }
                ForEach(draft.categories) { c in
                    Text(c.name).font(Theme.text(14))
                }
                .onDelete { draft.categories.remove(atOffsets: $0) }
            }
            .listRowBackground(Theme.navy.opacity(0.6))

            Section {
                Button(role: .destructive) { confirmDelete = true } label: { Text("Ukloni stranicu") }
            }
            .listRowBackground(Theme.navy.opacity(0.6))
        }
        .scrollContentBackground(.hidden)
        .background(NightSky())
        .navigationTitle(draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Spremi") {
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
        .confirmationDialog("Ukloniti \(draft.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Ukloni", role: .destructive) {
                engine.forget(siteID: site.id)
                sites.remove([site.id])
                dismiss()
            }
        }
    }
}
