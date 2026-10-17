import SwiftUI

struct SitesView: View {
    @EnvironmentObject private var sites: SiteStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var engine: FeedEngine
    @State private var showAdd = false
    @AppStorage("sitesSection") private var section = 0
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        NavigationStack(path: $router.sites) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SITES").font(Theme.mono(11)).foregroundStyle(Theme.muted).tracking(1.2)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(sites.sites.count)").font(Theme.dot(34)).foregroundStyle(Theme.goldGradient)
                                Text("/ \(Limits.maxSites)").font(Theme.mono(14)).foregroundStyle(Theme.muted)
                            }
                        }
                        Spacer()
                        Button { showAdd = true } label: { Label("Add", systemImage: "plus") }
                            .buttonStyle(GoldButtonStyle())
                            .disabled(!sites.canAdd)
                    }
                    .padding(.horizontal, 16)

                    Picker("", selection: $section) {
                        Text("Sites").tag(0)
                        Text("Forums").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    if section == 1 {
                        ForumsSection()
                    } else if sites.sites.isEmpty {
                        EmptyStateView(symbol: "globe", title: "No sites",
                                       message: "Add up to 50 sites. iNUTT finds images, GIFs, videos and categories automatically.",
                                       buttonTitle: "Add site") { showAdd = true }
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
                SiteRouteView(route: r)
            }
        }
        .sheet(isPresented: $showAdd) { AddSiteView() }
    }
}

struct SiteCard: View {
    let site: Site
    @EnvironmentObject private var engine: FeedEngine

    var body: some View {
        let items = engine.homeItems(site)
        let previews = previewThumbs(items)
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
                    Text("DISABLED").font(Theme.mono(9)).foregroundStyle(Theme.muted)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 6) {
                ForEach(previews) { p in
                    // Color.clear sets the size, so wide thumbnails can't push the card off screen.
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                        .overlay(RemoteImage(url: p.url, referer: site.url, maxPixel: 300))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if previews.isEmpty {
                    Shimmer().frame(height: 64).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            HStack(spacing: 14) {
                stat("square.stack.fill", "\(items.count)")
                stat("folder.fill", "\(site.categories.count) cat.")
                Spacer(minLength: 8)
                if let d = site.lastRefreshed {
                    Text(d.relativeHR).font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 22)
    }

    private struct Preview: Identifiable { var id: String; var url: URL }

    /// Up to four thumbnails: latest items first, then category covers.
    private func previewThumbs(_ items: [MediaItem]) -> [Preview] {
        var out = items.compactMap { i in i.thumbnailURL.map { Preview(id: i.id, url: $0) } }
        out += site.categories.compactMap { c in c.thumbnailURL.map { Preview(id: c.id, url: $0) } }
        return Array(out.prefix(4))
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Theme.gold)
            Text(text).font(Theme.mono(11)).foregroundStyle(Theme.body)
        }
    }
}

