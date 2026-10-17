import SwiftUI

struct SearchView: View {
    enum Scope: String, CaseIterable { case local = "In app", remote = "On sites" }

    @EnvironmentObject private var engine: FeedEngine
    @EnvironmentObject private var sites: SiteStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: Library
    @State private var query = ""
    @State private var scope: Scope = .local
    @State private var filter: MediaKind?
    @State private var remoteResults: [MediaItem] = []
    @State private var searching = false
    @State private var lastRemoteQuery = ""

    private var localResults: [MediaItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        let pool = engine.allCachedItems() + library.favorites + library.history.map(\.item)
        return FeedEngine.dedupe(pool.filter { item in
            guard seen.insert(item.id).inserted else { return false }
            if let filter, item.kind != filter { return false }
            return item.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || item.siteName.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || (item.categoryName?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        })
    }

    struct CategoryHit: Identifiable {
        var site: Site
        var category: SiteCategory
        var id: String { site.id.uuidString + category.id }
    }

    private var matchingCategories: [CategoryHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [CategoryHit] = []
        for s in sites.enabledSites {
            for c in s.categories where q.isEmpty || c.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                out.append(CategoryHit(site: s, category: c))
            }
        }
        return Array(out.prefix(q.isEmpty ? 30 : 60))
    }

    var body: some View {
        NavigationStack(path: $router.search) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("", selection: $scope) {
                        ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    KindFilterBar(filter: $filter)

                    if query.isEmpty {
                        idle
                    } else if scope == .local {
                        results(localResults, emptyText: "No results in saved content. Try \"On sites\".")
                    } else {
                        if searching {
                            HStack(spacing: 10) {
                                ProgressView().tint(Theme.gold)
                                Text("Searching \(sites.enabledSites.count) sites…").font(Theme.text(14)).foregroundStyle(Theme.body)
                            }
                            .frame(maxWidth: .infinity).padding()
                        }
                        let r = filter == nil ? remoteResults : remoteResults.filter { $0.kind == filter }
                        if !searching || !r.isEmpty {
                            results(r, emptyText: lastRemoteQuery.isEmpty ? "Press Search on the keyboard." : "The sites returned no results.")
                        }
                    }
                }
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .tabBarInset()
            .background(NightSky())
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Images, GIFs, videos, categories…")
            .onSubmit(of: .search) { submit() }
            .onChange(of: scope) { s in if s == .remote && !query.isEmpty && query != lastRemoteQuery { submit() } }
            .navigationDestination(for: SiteRoute.self) { r in
                SiteRouteView(route: r)
            }
        }
    }

    private func submit() {
        settings.addRecentSearch(query)
        guard scope == .remote else { return }
        let q = query
        lastRemoteQuery = q
        searching = true
        remoteResults = []
        Task {
            let r = await engine.remoteSearch(q)
            if q == lastRemoteQuery {
                remoteResults = Blocklist.filter(r)
                searching = false
            }
        }
    }

    @ViewBuilder
    private func results(_ items: [MediaItem], emptyText: String) -> some View {
        if !matchingCategories.isEmpty && scope == .local {
            categoryChips
        }
        if items.isEmpty {
            Text(emptyText).font(Theme.text(14)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity).padding(30)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Results", subtitle: "\(items.count) items")
                MediaGrid(items: items)
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var idle: some View {
        if !settings.recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(title: "Recent")
                    Button("Clear") { settings.recentSearches = [] }
                        .font(Theme.text(13, .medium)).foregroundStyle(Theme.gold)
                }
                FlowLayout(spacing: 8) {
                    ForEach(settings.recentSearches, id: \.self) { s in
                        Chip(title: s, symbol: "clock", selected: false) {
                            query = s
                            submit()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        if !matchingCategories.isEmpty {
            categoryChips
        } else if sites.sites.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: "Search",
                           message: "Add sites in Settings to search their content.")
                .padding(.horizontal, 16)
        }
    }

    private var categoryChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Categories", subtitle: "from all sites")
            FlowLayout(spacing: 8) {
                ForEach(matchingCategories) { pair in
                    NavigationLink(value: SiteRoute(siteID: pair.site.id, category: pair.category)) {
                        HStack(spacing: 6) {
                            Text(pair.category.name).font(Theme.text(13, .medium)).foregroundStyle(Theme.ink)
                            Text(pair.site.name).font(Theme.mono(9)).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

/// Wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
