import SwiftUI

/// Resolves a navigation route to a site page or one of its categories.
struct SiteRouteView: View {
    let route: SiteRoute
    @EnvironmentObject private var sites: SiteStore

    var body: some View {
        if let site = sites.site(route.siteID) {
            if route.showAllCategories {
                CategoryIndexView(site: site)
            } else if let category = route.category {
                CategoryView(site: site, category: category)
            } else {
                SiteDetailView(site: site)
            }
        } else {
            EmptyStateView(symbol: "questionmark", title: "Site not found", message: "This site was removed.")
                .padding()
        }
    }
}

struct SiteDetailView: View {
    let site: Site
    @EnvironmentObject private var engine: FeedEngine
    @EnvironmentObject private var sites: SiteStore
    @State private var filter: MediaKind?
    @State private var didLoad = false
    @State private var showEdit = false

    private var current: Site { sites.site(site.id) ?? site }

    private var items: [MediaItem] {
        let all = engine.homeItems(current)
        guard let filter else { return all }
        return all.filter { $0.kind == filter }
    }

    var body: some View {
        let key = FeedEngine.key(current)
        let categories = current.categories
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SiteHeader(site: current, subtitle: current.host)

                if !categories.isEmpty {
                    if engine.homeItems(current).isEmpty {
                        // A site whose page is a category index: show the categories as the main content.
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Categories", subtitle: "\(categories.count) categories")
                            CategoryGrid(site: current, categories: categories)
                        }
                        .padding(.horizontal, 16)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                SectionHeader(title: "Categories", subtitle: "\(categories.count) categories")
                                NavigationLink(value: SiteRoute(siteID: current.id, showAllCategories: true)) {
                                    HStack(spacing: 3) {
                                        Text("See all")
                                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                                    }
                                    .font(Theme.text(13, .medium))
                                    .foregroundStyle(Theme.gold)
                                }
                            }
                            .padding(.horizontal, 16)
                            CategoryRow(site: current, categories: Array(categories.prefix(30)))
                        }
                    }
                }

                if !engine.homeItems(current).isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Latest", subtitle: "\(engine.homeItems(current).count) items")
                            .padding(.horizontal, 16)
                        KindFilterBar(filter: $filter)
                        MediaGrid(items: items) {
                            Task { await engine.loadMore(current, nil) }
                        }
                        .padding(.horizontal, 16)
                        if engine.loading.contains(key) {
                            ProgressView().tint(Theme.gold).frame(maxWidth: .infinity).padding()
                        }
                    }
                } else if categories.isEmpty {
                    if engine.loading.contains(key) {
                        LoadingGrid().padding(.horizontal, 16)
                    } else {
                        EmptyStateView(symbol: "tray", title: "No content",
                                       message: engine.errors[key] ?? "Try refreshing, or switch the site to \"Full (JavaScript)\" mode in its settings.",
                                       buttonTitle: "Refresh") { Task { await engine.refresh(current, nil) } }
                            .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.top, 6)
        }
        .refreshable { await engine.refreshForHome(current, allowRender: true) }
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
        .task {
            guard !didLoad else { return }
            didLoad = true
            if engine.homeItems(current).isEmpty { await engine.refreshForHome(current, allowRender: true) }
        }
    }
}

/// Content of one category, in the same 2-column (iPhone) / 5-column (iPad) grid.
struct CategoryView: View {
    let site: Site
    let category: SiteCategory
    @EnvironmentObject private var engine: FeedEngine
    @EnvironmentObject private var sites: SiteStore
    @State private var filter: MediaKind?
    @State private var didLoad = false

    private var current: Site { sites.site(site.id) ?? site }

    private var items: [MediaItem] {
        let all = engine.items(current, category)
        guard let filter else { return all }
        return all.filter { $0.kind == filter }
    }

    var body: some View {
        let key = FeedEngine.key(current, category)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SiteHeader(site: current, subtitle: category.name, title: category.name, caption: current.name)
                KindFilterBar(filter: $filter)
                if items.isEmpty {
                    if engine.loading.contains(key) || !didLoad {
                        LoadingGrid().padding(.horizontal, 16)
                    } else {
                        EmptyStateView(symbol: "tray", title: "No content",
                                       message: engine.errors[key] ?? "This category is empty or needs \"Full (JavaScript)\" mode.",
                                       buttonTitle: "Refresh") { Task { await engine.refresh(current, category) } }
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
                Text(category.name).font(Theme.display(16, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { DownloadManager.shared.downloadAll(items) } label: { Image(systemName: "arrow.down.to.line") }
                    .disabled(items.isEmpty)
                    .accessibilityLabel("Download all")
            }
        }
        .task {
            guard !didLoad else { return }
            if engine.items(current, category).isEmpty { await engine.refresh(current, category) }
            didLoad = true
        }
    }
}

/// Every category of a site, searchable.
struct CategoryIndexView: View {
    let site: Site
    @State private var query = ""

    private var filtered: [SiteCategory] {
        guard !query.isEmpty else { return site.categories }
        return site.categories.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    var body: some View {
        ScrollView {
            CategoryGrid(site: site, categories: filtered)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
        .tabBarInset()
        .background(NightSky())
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search categories")
    }
}

struct SiteHeader: View {
    let site: Site
    var subtitle: String
    var title: String?
    var caption: String?

    var body: some View {
        HStack(spacing: 12) {
            SiteIcon(site: site, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                if let caption {
                    Text(caption.uppercased()).font(Theme.mono(10)).foregroundStyle(Theme.muted).tracking(1)
                }
                Text(title ?? site.name).font(Theme.display(24, .bold)).foregroundStyle(Theme.ink).lineLimit(2)
                if title == nil {
                    Text(subtitle).font(Theme.mono(12)).foregroundStyle(Theme.gold)
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

struct CategoryGrid: View {
    let site: Site
    let categories: [SiteCategory]

    var body: some View {
        LazyVGrid(columns: MediaGrid.columns, spacing: 12) {
            ForEach(categories) { c in
                NavigationLink(value: SiteRoute(siteID: site.id, category: c)) {
                    CategoryCard(category: c, referer: site.url)
                }
                .buttonStyle(CardPressStyle())
            }
        }
    }
}

struct CategoryRow: View {
    let site: Site
    let categories: [SiteCategory]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(categories) { c in
                    NavigationLink(value: SiteRoute(siteID: site.id, category: c)) {
                        if c.thumbnailURL != nil {
                            CategoryCard(category: c, referer: site.url).frame(width: 150)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(Theme.gold)
                                Text(c.name).font(Theme.text(13, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                        }
                    }
                    .buttonStyle(CardPressStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct CategoryCard: View {
    let category: SiteCategory
    var referer: URL?

    var body: some View {
        Color.clear
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                if let t = category.thumbnailURL {
                    RemoteImage(url: t, referer: referer)
                } else {
                    ZStack {
                        Theme.navy2
                        RadialGradient(colors: [Theme.gold.opacity(0.18), .clear], center: .topTrailing, startRadius: 0, endRadius: 160)
                        Image(systemName: "folder.fill").font(.system(size: 26)).foregroundStyle(Theme.gold.opacity(0.8))
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 60)
                    .overlay(alignment: .bottomLeading) {
                        Text(category.name)
                            .font(Theme.display(14, .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .padding(10)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.edge, lineWidth: 0.6))
    }
}

struct LoadingGrid: View {
    var body: some View {
        LazyVGrid(columns: MediaGrid.columns, spacing: 12) {
            ForEach(0..<(MediaGrid.columnCount * 3), id: \.self) { _ in
                Shimmer().aspectRatio(4 / 5, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }
}
