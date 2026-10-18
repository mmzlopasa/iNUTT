import SwiftUI

struct PinDots: View {
    var count: Int
    var filled: Int
    var shake: CGFloat

    var body: some View {
        HStack(spacing: 16) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i < filled ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Color.white.opacity(0.08)))
                    .overlay(Circle().strokeBorder(i < filled ? Color.clear : Theme.line2, lineWidth: 1))
                    .frame(width: 14, height: 14)
                    .scaleEffect(i < filled ? 1.1 : 1)
            }
        }
        .modifier(ShakeEffect(animatableData: shake))
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: filled)
    }
}

struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}

struct PinPad: View {
    var onDigit: (String) -> Void
    var onDelete: () -> Void
    var leftSymbol: String?
    var leftAction: (() -> Void)?

    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: 14) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 22) { ForEach(row, id: \.self) { key($0) } }
            }
            HStack(spacing: 22) {
                if let leftAction, let leftSymbol {
                    Button(action: leftAction) {
                        Image(systemName: leftSymbol).font(.system(size: 26)).foregroundStyle(Theme.gold)
                            .frame(width: 76, height: 76)
                    }
                } else {
                    Color.clear.frame(width: 76, height: 76)
                }
                key("0")
                Button(action: onDelete) {
                    Image(systemName: "delete.left").font(.system(size: 22)).foregroundStyle(Theme.body)
                        .frame(width: 76, height: 76)
                }
            }
        }
    }

    private func key(_ d: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onDigit(d)
        } label: {
            Text(d)
                .font(Theme.display(28, .regular))
                .foregroundStyle(Theme.ink)
                .frame(width: 76, height: 76)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
        }
        .buttonStyle(CardPressStyle())
    }
}

struct LockView: View {
    @EnvironmentObject private var lock: LockManager
    @EnvironmentObject private var settings: AppSettings
    @State private var entered = ""
    @State private var shake: CGFloat = 0

    private var usesPIN: Bool { settings.pinEnabled && lock.hasPIN }

    var body: some View {
        ZStack {
            NightSky(intensity: 1.2)
            VStack(spacing: 26) {
                Spacer()
                ZStack {
                    Circle().fill(Theme.gold.opacity(0.14)).frame(width: 96, height: 96).blur(radius: 6)
                    Image(systemName: "lock.fill").font(.system(size: 36, weight: .semibold)).foregroundStyle(Theme.goldGradient)
                }
                Wordmark(size: 30)
                Text(usesPIN ? "Enter PIN to unlock" : "iNUTT is locked")
                    .font(Theme.text(15)).foregroundStyle(Theme.body)
                if usesPIN {
                    PinDots(count: lock.pinLength, filled: entered.count, shake: shake)
                        .padding(.vertical, 6)
                    PinPad(onDigit: type, onDelete: deleteDigit,
                           leftSymbol: settings.faceIDEnabled ? "faceid" : nil,
                           leftAction: biometricTapped)
                } else {
                    Button {
                        Task {
                            await lock.authenticateBiometric()
                            if lock.isLocked { await lock.authenticateDevice() }
                        }
                    } label: {
                        Label("Unlock with \(LockManager.biometryName)", systemImage: "faceid")
                    }
                    .buttonStyle(GoldButtonStyle())
                }
                Spacer()
            }
            .padding()
        }
        .task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            await lock.authenticateBiometric()
        }
    }

    private func deleteDigit() {
        if !entered.isEmpty { entered.removeLast() }
    }

    private func biometricTapped() {
        Task { await lock.authenticateBiometric() }
    }

    private func type(_ d: String) {
        guard entered.count < lock.pinLength else { return }
        entered += d
        if entered.count == lock.pinLength {
            if lock.verify(entered) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                entered = ""
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                withAnimation(.linear(duration: 0.4)) { shake += 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { entered = "" }
            }
        }
    }
}

/// Set or change the PIN: enter twice.
struct PinSetupView: View {
    /// Sets the decoy PIN instead, which opens an empty app.
    var decoy = false
    @EnvironmentObject private var lock: LockManager
    @Environment(\.dismiss) private var dismiss
    @State private var first: String?
    @State private var entered = ""
    @State private var length = 4
    @State private var shake: CGFloat = 0
    @State private var message: String?

    var body: some View {
        ZStack {
            NightSky()
            VStack(spacing: 22) {
                Text(first == nil ? (decoy ? "Enter a decoy PIN" : "Enter a new PIN") : "Repeat PIN")
                    .font(Theme.display(22, .semibold)).foregroundStyle(Theme.ink)
                Picker("Length", selection: $length) {
                    Text("4 digits").tag(4)
                    Text("6 digits").tag(6)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .disabled(first != nil || decoy)
                PinDots(count: length, filled: entered.count, shake: shake)
                if let message { Text(message).font(Theme.text(13)).foregroundStyle(Theme.err) }
                PinPad(onDigit: type, onDelete: { if !entered.isEmpty { entered.removeLast() } })
            }
            .padding()
        }
        .navigationTitle(decoy ? "Decoy PIN" : "PIN")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if decoy { length = lock.pinLength } }
        .onChange(of: length) { _ in entered = "" }
    }

    private func type(_ d: String) {
        guard entered.count < length else { return }
        entered += d
        guard entered.count == length else { return }
        if let f = first {
            if f == entered {
                if decoy {
                    guard !lock.matchesPIN(entered) else {
                        message = "Use a different PIN than your real one"
                        withAnimation(.linear(duration: 0.4)) { shake += 1 }
                        first = nil
                        entered = ""
                        return
                    }
                    lock.setDecoyPIN(entered)
                } else {
                    lock.setPIN(entered)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } else {
                message = "PINs don't match"
                withAnimation(.linear(duration: 0.4)) { shake += 1 }
                first = nil
                entered = ""
            }
        } else {
            first = entered
            message = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { entered = "" }
        }
    }
}
