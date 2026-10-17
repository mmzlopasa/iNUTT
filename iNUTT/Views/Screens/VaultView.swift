import SwiftUI
import AVKit

/// Encrypted downloads. Opened files are decrypted to a temporary copy that is wiped on close.
struct VaultView: View {
    @ObservedObject private var vault = Vault.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var opening: UUID?
    @State private var shown: VaultShown?
    @State private var confirmDelete: VaultEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VAULT").font(Theme.mono(11)).foregroundStyle(Theme.muted).tracking(1.2)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(vault.entries.count)").font(Theme.dot(34)).foregroundStyle(Theme.goldGradient)
                        Text(ByteCountFormatter.string(fromByteCount: vault.totalSize, countStyle: .file))
                            .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    }
                }
                Toggle(isOn: $settings.vaultDownloads) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download into the vault").font(Theme.text(15, .medium)).foregroundStyle(Theme.ink)
                        Text("Encrypted, only inside iNUTT. Not in Photos or Files.").font(Theme.text(12)).foregroundStyle(Theme.muted)
                    }
                }
                .tint(Theme.gold)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.navy.opacity(0.6)))
                if vault.entries.isEmpty {
                    EmptyStateView(symbol: "lock.shield", title: "The vault is empty",
                                   message: "Turn on \"Download into the vault\" and every download is stored here, encrypted.")
                } else {
                    LazyVGrid(columns: MediaGrid.columns, spacing: 12) {
                        ForEach(vault.entries) { e in
                            Button { Task { await open(e) } } label: { tile(e) }
                                .buttonStyle(CardPressStyle())
                                .contextMenu {
                                    Button(role: .destructive) { confirmDelete = e } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .padding(16)
        }
        .tabBarInset()
        .background(NightSky())
        .navigationTitle("Vault")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { vault.closeOpenFiles() }
        .fullScreenCover(item: $shown) { s in VaultPlayer(shown: s) }
        .confirmationDialog("Delete from the vault?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let e = confirmDelete { vault.delete(e) } }
        }
    }

    private func tile(_ e: VaultEntry) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.navy)
            RemoteImage(url: e.thumbnailURL, referer: nil, maxPixel: 400)
            if opening == e.id { ProgressView().tint(Theme.gold) }
        }
        .aspectRatio(0.8, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                Image(systemName: e.kind.symbol).font(.system(size: 10, weight: .bold))
                Text(e.title).font(Theme.text(12, .medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func open(_ e: VaultEntry) async {
        guard opening == nil else { return }
        opening = e.id
        defer { opening = nil }
        guard let url = try? await vault.open(e) else {
            DownloadManager.shared.show("Couldn't open this file", symbol: "xmark.octagon.fill", isError: true)
            return
        }
        shown = VaultShown(entry: e, file: url)
    }
}

struct VaultShown: Identifiable {
    let entry: VaultEntry
    let file: URL
    var id: UUID { entry.id }
}

private struct VaultPlayer: View {
    let shown: VaultShown
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var zoomed = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayerView(player: player).ignoresSafeArea()
            } else if let image {
                ZoomableImage(image: image, isZoomed: $zoomed, onTap: {}).ignoresSafeArea()
            } else {
                ProgressView().tint(Theme.gold).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.ultraThinMaterial))
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .task {
            if shown.entry.kind == .video {
                let p = AVPlayer(url: shown.file)
                player = p
                p.play()
            } else if let data = try? Data(contentsOf: shown.file) {
                image = shown.entry.kind == .gif
                    ? ImagePipeline.animated(data, maxPixel: 2400) ?? UIImage(data: data)
                    : ImagePipeline.downsample(data, maxPixel: 3840) ?? UIImage(data: data)
            }
        }
        .onDisappear { player?.pause() }
    }
}
