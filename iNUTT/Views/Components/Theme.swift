import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Design tokens taken from the ScyHost / SCYDE design language.
enum Theme {
    static let bg = Color(hex: 0x0D0F14)
    static let navy = Color(hex: 0x14161D)
    static let navy2 = Color(hex: 0x1A1D25)
    static let navy3 = Color(hex: 0x262A35)
    static let ink = Color(hex: 0xF5F2FF)
    static let body = Color(hex: 0xB8B4DD)
    static let muted = Color(hex: 0x8F8BBA)
    static let brand = Color(hex: 0xC4BBFF)
    static let violet = Color(hex: 0x8B7CFF)
    static let gold = Color(hex: 0xFFD76A)
    static let gold2 = Color(hex: 0xFFE7A0)
    static let gold3 = Color(hex: 0xE9B84A)
    static let onGold = Color(hex: 0x1B1530)
    static let err = Color(hex: 0xFF9AA8)
    static let line = Color(red: 184 / 255, green: 180 / 255, blue: 235 / 255).opacity(0.13)
    static let line2 = Color(red: 184 / 255, green: 180 / 255, blue: 235 / 255).opacity(0.26)
    static let edge = Color.white.opacity(0.14)

    static let goldGradient = LinearGradient(colors: [gold, gold2, gold], startPoint: .leading, endPoint: .trailing)
    static let lavenderGradient = LinearGradient(colors: [brand, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cardFill = LinearGradient(stops: [
        .init(color: .white.opacity(0.10), location: 0),
        .init(color: .white.opacity(0.03), location: 0.42),
        .init(color: .white.opacity(0.055), location: 1)
    ], startPoint: .topLeading, endPoint: .bottomTrailing)

    // Typography: Sora for display, Geist for UI text, Geist Mono for meta, Doto for big numbers.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Sora-Bold"
        case .semibold, .medium: name = "Sora-SemiBold"
        default: name = "Sora-Regular"
        }
        return .custom(name, size: size, relativeTo: .title)
    }

    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black, .semibold: name = "Geist-SemiBold"
        case .medium: name = "Geist-Medium"
        default: name = "Geist-Regular"
        }
        return .custom(name, size: size, relativeTo: .body)
    }

    static func mono(_ size: CGFloat) -> Font { .custom("GeistMono-Medium", size: size, relativeTo: .caption) }
    static func dot(_ size: CGFloat) -> Font { .custom("Doto-Bold", size: size, relativeTo: .largeTitle) }
}

/// Night-sky background: deep navy with a gold haze, violet haze and a few stars.
struct NightSky: View {
    var intensity: Double = 1

    var body: some View {
        ZStack {
            Theme.bg
            RadialGradient(colors: [Theme.gold.opacity(0.22 * intensity), .clear], center: UnitPoint(x: 0.9, y: -0.05), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(hex: 0x6C5CE7).opacity(0.18 * intensity), .clear], center: UnitPoint(x: 0, y: 1.05), startRadius: 0, endRadius: 460)
            Stars().opacity(0.55 * intensity)
        }
        .ignoresSafeArea()
    }
}

private struct Stars: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: 42)
            for _ in 0..<70 {
                let x = rng.next() * size.width
                let y = rng.next() * size.height
                let r = 0.5 + rng.next() * 1.3
                let a = 0.25 + rng.next() * 0.6
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(a)))
            }
        }
        .allowsHitTesting(false)
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 10_000) / 10_000
    }
}

struct GlassCard: ViewModifier {
    var radius: CGFloat = 20
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.navy.opacity(0.55))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.cardFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(highlighted ? Theme.gold.opacity(0.35) : Theme.edge, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 18, y: 12)
    }
}

extension View {
    func glassCard(radius: CGFloat = 20, highlighted: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, highlighted: highlighted))
    }

    /// Leaves room for the floating tab bar.
    func tabBarInset() -> some View {
        safeAreaInset(edge: .bottom) { Color.clear.frame(height: 78) }
    }
}

struct GoldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.text(16, .semibold))
            .foregroundStyle(Theme.onGold)
            .padding(.horizontal, 22)
            .frame(height: 50)
            .background(Capsule().fill(Theme.goldGradient))
            .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 0.6))
            .shadow(color: Theme.gold.opacity(0.35), radius: 16, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.text(15, .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.12 : 0.06)))
            .overlay(Capsule().strokeBorder(Theme.line2, lineWidth: 1))
    }
}

struct Chip: View {
    var title: String
    var symbol: String?
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(Theme.text(13, .medium)).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .foregroundStyle(selected ? Theme.onGold : Theme.body)
            .background(
                Capsule().fill(selected ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Color.white.opacity(0.06)))
            )
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}

/// "iNUTT." wordmark with the gold dot, like "scyhost."
struct Wordmark: View {
    var size: CGFloat = 28
    var body: some View {
        HStack(spacing: 0) {
            Text("iNUTT").font(Theme.display(size, .bold)).foregroundStyle(Theme.ink)
            Text(".").font(Theme.display(size, .bold)).foregroundStyle(Theme.gold)
        }
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.display(19, .semibold)).foregroundStyle(Theme.ink)
                if let subtitle { Text(subtitle).font(Theme.mono(11)).foregroundStyle(Theme.muted) }
            }
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                    }
                    .font(Theme.text(13, .medium))
                    .foregroundStyle(Theme.gold)
                }
            }
        }
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.12)).frame(width: 88, height: 88)
                Circle().strokeBorder(Theme.gold.opacity(0.3), lineWidth: 1).frame(width: 88, height: 88)
                Image(systemName: symbol).font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.goldGradient)
            }
            Text(title).font(Theme.display(20, .semibold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            Text(message).font(Theme.text(14)).foregroundStyle(Theme.body).multilineTextAlignment(.center)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action).buttonStyle(GoldButtonStyle()).padding(.top, 6)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .glassCard(radius: 28)
    }
}

struct SiteIcon: View {
    var site: Site?
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Theme.navy3)
            Text(String((site?.name ?? "?").prefix(1)).uppercased())
                .font(Theme.display(size * 0.45, .bold))
                .foregroundStyle(Theme.goldGradient)
            if let icon = site?.iconURL {
                RemoteImage(url: icon, referer: site?.url, maxPixel: 128, contentMode: .fit, showsPlaceholder: false)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Theme.edge, lineWidth: 0.5))
    }
}

extension Date {
    var relativeHR: String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "hr_HR")
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }
}
