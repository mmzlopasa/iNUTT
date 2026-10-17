import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var router: Router
    @ObservedObject private var collections = CollectionStore.shared
    @ObservedObject private var vault = Vault.shared
    @State private var filter: MediaKind?
    /// nil shows every favorite; otherwise one of your collections.
    @State private var selected: UUID?
    @State private var newCollection = false
    @State private var renaming: MediaCollection?
    @State private var name = ""
    @State private var showVault = false
    @State private var confirmDelete: MediaCollection?
    @State private var showLater = false
    @ObservedObject private var later = WatchLater.shared
    @ObservedObject private var offline = OfflineStore.shared
    @ObservedObject private var settings = AppSettings.shared

    private var source: [MediaItem] {
        if showLater { return later.items }
        if let selected, let c = collections.collections.first(where: { $0.id == selected }) { return c.items }
        return library.favorites
    }

    private var items: [MediaItem] {
        guard let filter else { return source }
        return source.filter { $0.kind == filter }
    }

    var body: some View {
        NavigationStack(path: $router.favorites) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(showLater ? "WATCH LATER" : (selected == nil ? "FAVORITES" : "COLLECTION")).font(Theme.mono(11)).foregroundStyle(Theme.muted).tracking(1.2)
                            Text("\(source.count)").font(Theme.dot(34)).foregroundStyle(Theme.goldGradient)
                        }
                        Spacer()
                        if !items.isEmpty {
                            circle("arrow.down.to.line") {
                                DownloadManager.shared.downloadAll(items)
                            }
                        }
                        circle("lock.shield.fill") { showVault = true }
                    }
                    .padding(.horizontal, 16)
                    collectionBar
                    KindFilterBar(filter: $filter)
                    if items.isEmpty {
                        EmptyStateView(symbol: showLater ? "clock" : (selected == nil ? "heart" : "folder"),
                                       title: showLater ? "Nothing in Watch later" : (selected == nil ? "No favorites yet" : "This collection is empty"),
                                       message: showLater ? "Tap the clock in the viewer or long-press a card. Items leave the queue once you have watched them."
                                           : (selected == nil ? "Tap the heart in the viewer or long-press a card."
                                           : "Add items with the folder button in the viewer or by long-pressing a card."))
                            .padding(.horizontal, 16)
                    } else {
                        MediaGrid(items: items).padding(.horizontal, 16)
                    }
                }
                .padding(.top, 8)
            }
            .tabBarInset()
            .background(NightSky())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SiteRoute.self) { r in
                SiteRouteView(route: r)
            }
            .navigationDestination(isPresented: $showVault) { VaultView() }
        }
        .alert("New collection", isPresented: $newCollection) {
            TextField("Name", text: $name)
            Button("Create") { if let c = collections.create(name) { selected = c.id } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename collection", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Save") { if let r = renaming { collections.rename(r.id, to: name) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this collection?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let c = confirmDelete {
                    if selected == c.id { selected = nil }
                    collections.delete(c.id)
                }
            }
        } message: { Text("The items stay in Favorites and on their sites.") }
    }

    private var collectionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All favorites", symbol: "heart.fill", on: selected == nil && !showLater) { selected = nil; showLater = false }
                    .contextMenu {
                        Button { settings.offlineFavorites.toggle(); offline.sync() } label: {
                            Label(settings.offlineFavorites ? "Don't keep offline" : "Keep offline (Wi-Fi)",
                                  systemImage: settings.offlineFavorites ? "icloud.slash" : "arrow.down.circle")
                        }
                    }
                chip("Watch later · \(later.items.count)", symbol: "clock.fill", on: showLater) { selected = nil; showLater = true }
                ForEach(collections.collections) { c in
                    chip("\(c.name) · \(c.items.count)", symbol: offline.isOfflineCollection(c.id) ? "arrow.down.circle.fill" : "folder.fill",
                         on: selected == c.id && !showLater) { selected = c.id; showLater = false }
                        .contextMenu {
                            Button { offline.toggleCollection(c.id) } label: {
                                Label(offline.isOfflineCollection(c.id) ? "Don't keep offline" : "Keep offline (Wi-Fi)",
                                      systemImage: offline.isOfflineCollection(c.id) ? "icloud.slash" : "arrow.down.circle")
                            }
                            Button { name = c.name; renaming = c } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { confirmDelete = c } label: { Label("Delete", systemImage: "trash") }
                        }
                }
                chip("New", symbol: "plus", on: false) { name = ""; newCollection = true }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Theme.text(13, .semibold))
                .foregroundStyle(on ? Theme.onGold : Theme.ink)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(on ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Color.white.opacity(0.06))))
                .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func circle(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(0.07)))
                .overlay(Circle().strokeBorder(Theme.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct HistoryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var viewer: ViewerState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return library.history }
        return library.history.filter {
            $0.item.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.item.siteName.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    struct DaySection: Identifiable {
        var title: String
        var entries: [HistoryEntry]
        var id: String { title }
    }

    private var grouped: [DaySection] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d"
        var order: [String] = []
        var map: [String: [HistoryEntry]] = [:]
        for e in filtered {
            let label: String
            if cal.isDateInToday(e.viewedAt) { label = "Today" }
            else if cal.isDateInYesterday(e.viewedAt) { label = "Yesterday" }
            else { label = f.string(from: e.viewedAt).capitalized }
            if map[label] == nil { order.append(label) }
            map[label, default: []].append(e)
        }
        return order.map { DaySection(title: $0, entries: map[$0] ?? []) }
    }

    var body: some View {
        List {
            if !settings.historyEnabled {
                Text("Saving history is turned off in Settings.")
                    .font(Theme.text(13)).foregroundStyle(Theme.muted)
                    .listRowBackground(Color.clear)
            }
            if filtered.isEmpty {
                Text(query.isEmpty ? "History is empty." : "No results.")
                    .font(Theme.text(14)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                    .listRowBackground(Color.clear)
            }
            ForEach(grouped) { section in
                Section {
                    ForEach(section.entries) { entry in
                        Button {
                            let all = filtered.map(\.item)
                            let idx = all.firstIndex(of: entry.item) ?? 0
                            viewer.open(all, at: idx)
                        } label: {
                            HistoryRow(entry: entry)
                        }
                        .listRowBackground(Theme.navy.opacity(0.6))
                        .swipeActions {
                            Button(role: .destructive) { library.removeHistory([entry.id]) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text(section.title).font(Theme.mono(11)).foregroundStyle(Theme.gold)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightSky())
        .searchable(text: $query, prompt: "Search history")
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear") { confirmClear = true }.disabled(library.history.isEmpty)
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { library.clearHistory() }
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: entry.item.thumbnailURL, referer: entry.item.referer, maxPixel: 200)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: entry.item.kind.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.onGold)
                        .padding(4)
                        .background(Circle().fill(Theme.gold))
                        .padding(4)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.item.displayTitle).font(Theme.text(14, .medium)).foregroundStyle(Theme.ink).lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.item.siteName).font(Theme.mono(10)).foregroundStyle(Theme.gold)
                    Text(entry.viewedAt.formatted(date: .omitted, time: .shortened)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
