import SwiftUI

struct SitesView: View {
    @EnvironmentObject private var sites: SiteStore
    @EnvironmentObject private var engine: FeedEngine
    @State private var showAdd = false
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("STRANICE").font(Theme.mono(11)).foregroundStyle(Theme.muted).tracking(1.2)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(sites.sites.count)").font(Theme.dot(34)).foregroundStyle(Theme.goldGradient)
                                Text("/ \(Limits.maxSites)").font(Theme.mono(14)).foregroundStyle(Theme.muted)
                            }
                        }
                        Spacer()
                        Button { showAdd = true } label: { Label("Dodaj", systemImage: "plus") }
                            .buttonStyle(GoldButtonStyle())
                            .disabled(!sites.canAdd)
                    }
                    .padding(.horizontal, 16)

                    if sites.sites.isEmpty {
                        EmptyStateView(symbol: "globe", title: "Nema stranica",
                                       message: "Dodaj do 50 stranica. iNUTT sam pronalazi slike, GIF-ove, videe i kategorije.",
                                       buttonTitle: "Dodaj stranicu") { showAdd = true }
                            .padding(.horizontal, 16)
                    } else {
                        let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: hSize == .regular ? 3 : 1)
                        LazyVGrid(columns: cols, spacing: 12) {
                            ForEach(sites.sites) { site in
                                NavigationLink(value: SiteRoute(siteID: site.id)) { SiteCard(site: site) }
                                    .buttonStyle(CardPressStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 8)
            }
            .refreshable { await engine.refreshAll() }
            .tabBarInset()
            .background(NightSky())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SiteRoute.self) { r in
                if let s = sites.site(r.siteID) { SiteDetailView(site: s, initialCategory: r.category) }
            }
        }
        .sheet(isPresented: $showAdd) { AddSiteView() }
    }
}

struct SiteCard: View {
    let site: Site
    @EnvironmentObject private var engine: FeedEngine

    var body: some View {
        let items = engine.items(site)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SiteIcon(site: site, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(site.name).font(Theme.display(17, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(site.host).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                if engine.loading.contains(FeedEngine.key(site)) {
                    ProgressView().tint(Theme.gold)
                } else if !site.enabled {
                    Text("ISKLJUČENO").font(Theme.mono(9)).foregroundStyle(Theme.muted)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 6) {
                ForEach(items.prefix(4)) { item in
                    RemoteImage(url: item.thumbnailURL, referer: item.referer, maxPixel: 300)
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if items.isEmpty {
                    Shimmer().frame(height: 64).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            HStack(spacing: 14) {
                stat("square.stack.fill", "\(items.count)")
                stat("folder.fill", "\(site.categories.count) kat.")
                Spacer()
                if let d = site.lastRefreshed {
                    Text(d.relativeHR).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(14)
        .glassCard(radius: 22)
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Theme.gold)
            Text(text).font(Theme.mono(11)).foregroundStyle(Theme.body)
        }
    }
}

struct SiteDetailView: View {
    let site: Site
    var initialCategory: SiteCategory?
    @EnvironmentObject private var engine: FeedEngine
    @EnvironmentObject private var sites: SiteStore
    @State private var category: SiteCategory?
    @State private var filter: MediaKind?
    @State private var didInit = false
    @State private var showEdit = false
    @State private var categorySearch = ""
    @State private var showAllCategories = false

    private var current: Site { sites.site(site.id) ?? site }

    private var items: [MediaItem] {
        let all = engine.items(current, category)
        guard let filter else { return all }
        return all.filter { $0.kind == filter }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    SiteIcon(site: current, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(current.name).font(Theme.display(24, .bold)).foregroundStyle(Theme.ink).lineLimit(2)
                        Text(category?.name ?? current.host).font(Theme.mono(12)).foregroundStyle(Theme.gold)
                    }
                }
                .padding(.horizontal, 16)

                if !current.categories.isEmpty {
                    categoryBar
                }
                KindFilterBar(filter: $filter)

                let key = FeedEngine.key(current, category)
                if items.isEmpty {
                    if engine.loading.contains(key) {
                        LazyVGrid(columns: MediaGrid.columns, spacing: 12) {
                            ForEach(0..<(MediaGrid.columnCount * 3), id: \.self) { _ in
                                Shimmer().aspectRatio(4 / 5, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                        }
                        .padding(.horizontal, 16)
                    } else {
                        EmptyStateView(symbol: "tray", title: "Nema sadržaja",
                                       message: engine.errors[key] ?? "Pokušaj osvježiti ili u postavkama stranice uključi način \"Puno (JavaScript)\".",
                                       buttonTitle: "Osvježi") { Task { await engine.refresh(current, category) } }
                            .padding(.horizontal, 16)
                    }
                } else {
                    MediaGrid(items: items) {
                        Task { await engine.loadMore(current, category) }
                    }
                    .padding(.horizontal, 16)
                    if engine.loading.contains(key) {
                        ProgressView().tint(Theme.gold).frame(maxWidth: .infinity).padding()
                    }
                }
            }
            .padding(.top, 6)
        }
        .refreshable { await engine.refresh(current, category) }
        .tabBarInset()
        .background(NightSky())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(current.name).font(Theme.display(16, .semibold)).foregroundStyle(Theme.ink)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showEdit = true } label: { Image(systemName: "slider.horizontal.3") }
            }
        }
        .sheet(isPresented: $showEdit) { NavigationStack { EditSiteView(site: current) } }
        .sheet(isPresented: $showAllCategories) { categorySheet }
        .task {
            guard !didInit else { return }
            didInit = true
            category = initialCategory
            await loadIfNeeded()
        }
        .onChange(of: category) { _ in Task { await loadIfNeeded() } }
    }

    private func loadIfNeeded() async {
        if engine.items(current, category).isEmpty { await engine.refresh(current, category) }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "Sve", symbol: "sparkles", selected: category == nil) { category = nil }
                ForEach(current.categories.prefix(25)) { c in
                    Chip(title: c.name, symbol: nil, selected: category == c) { category = c }
                }
                if current.categories.count > 25 {
                    Chip(title: "Sve kategorije (\(current.categories.count))", symbol: "list.bullet", selected: false) { showAllCategories = true }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var categorySheet: some View {
        NavigationStack {
            List {
                ForEach(current.categories.filter { categorySearch.isEmpty || $0.name.localizedCaseInsensitiveContains(categorySearch) }) { c in
                    Button {
                        category = c
                        showAllCategories = false
                    } label: {
                        HStack {
                            Text(c.name).font(Theme.text(16)).foregroundStyle(Theme.ink)
                            Spacer()
                            if category == c { Image(systemName: "checkmark").foregroundStyle(Theme.gold) }
                        }
                    }
                    .listRowBackground(Theme.navy2)
                }
            }
            .scrollContentBackground(.hidden)
            .background(NightSky())
            .searchable(text: $categorySearch, prompt: "Traži kategorije")
            .navigationTitle("Kategorije")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
