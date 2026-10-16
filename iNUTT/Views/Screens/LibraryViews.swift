import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var library: Library
    @State private var filter: MediaKind?

    private var items: [MediaItem] {
        guard let filter else { return library.favorites }
        return library.favorites.filter { $0.kind == filter }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("FAVORITI").font(Theme.mono(11)).foregroundStyle(Theme.muted).tracking(1.2)
                            Text("\(library.favorites.count)").font(Theme.dot(34)).foregroundStyle(Theme.goldGradient)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    KindFilterBar(filter: $filter)
                    if items.isEmpty {
                        EmptyStateView(symbol: "heart", title: "Još nema favorita",
                                       message: "Dodirni srce u pregledniku sadržaja ili dugo pritisni karticu.")
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
        }
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

    private var grouped: [(String, [HistoryEntry])] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "hr_HR")
        f.dateFormat = "EEEE, d. MMMM"
        var order: [String] = []
        var map: [String: [HistoryEntry]] = [:]
        for e in filtered {
            let label: String
            if cal.isDateInToday(e.viewedAt) { label = "Danas" }
            else if cal.isDateInYesterday(e.viewedAt) { label = "Jučer" }
            else { label = f.string(from: e.viewedAt).capitalized }
            if map[label] == nil { order.append(label) }
            map[label, default: []].append(e)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        List {
            if !settings.historyEnabled {
                Text("Spremanje povijesti je isključeno u postavkama.")
                    .font(Theme.text(13)).foregroundStyle(Theme.muted)
                    .listRowBackground(Color.clear)
            }
            if filtered.isEmpty {
                Text(query.isEmpty ? "Povijest je prazna." : "Nema rezultata.")
                    .font(Theme.text(14)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                    .listRowBackground(Color.clear)
            }
            ForEach(grouped, id: \.0) { section in
                Section {
                    ForEach(section.1) { entry in
                        Button {
                            let all = filtered.map(\.item)
                            let idx = all.firstIndex(of: entry.item) ?? 0
                            viewer.present(all, at: idx)
                        } label: {
                            HistoryRow(entry: entry)
                        }
                        .listRowBackground(Theme.navy.opacity(0.6))
                        .swipeActions {
                            Button(role: .destructive) { library.removeHistory([entry.id]) } label: { Label("Obriši", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text(section.0).font(Theme.mono(11)).foregroundStyle(Theme.gold)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightSky())
        .searchable(text: $query, prompt: "Pretraži povijest")
        .navigationTitle("Povijest")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Očisti") { confirmClear = true }.disabled(library.history.isEmpty)
            }
        }
        .confirmationDialog("Obrisati cijelu povijest?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Obriši povijest", role: .destructive) { library.clearHistory() }
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
