import SwiftUI

/// First launch: what iNUTT does, how your data is handled, and the content notice you accept.
struct OnboardingView: View {
    var onDone: () -> Void
    @State private var page = 0
    @State private var accepted = false

    private struct Page { let symbol: String; let title: String; let text: String }
    private let pages = [
        Page(symbol: "sparkles", title: "Your sites, one app",
             text: "Add up to 50 sites with images, GIFs and videos. iNUTT shows them natively, fast and without a browser."),
        Page(symbol: "play.rectangle.on.rectangle.fill", title: "Watch your way",
             text: "Categories, search, favorites, history, a full-screen viewer and Reels you swipe like TikTok."),
        Page(symbol: "lock.shield.fill", title: "Private by design",
             text: "No account, no tracking, no ads. Everything you add stays on this device, locked with Face ID or a PIN."),
    ]

    var body: some View {
        ZStack {
            NightSky().ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Wordmark(size: 26)
                    Spacer()
                    if page < pages.count {
                        Button("Skip") { withAnimation { page = pages.count } }
                            .font(Theme.text(14, .medium)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        intro(pages[i]).tag(i)
                    }
                    notice.tag(pages.count)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 6) {
                    ForEach(0...pages.count, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Color.white.opacity(0.18)))
                            .frame(width: i == page ? 22 : 6, height: 6)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: page)
                .padding(.bottom, 18)

                Button(page < pages.count ? "Continue" : "Get started") {
                    if page < pages.count {
                        withAnimation { page += 1 }
                    } else {
                        onDone()
                    }
                }
                .buttonStyle(GoldButtonStyle())
                .disabled(page == pages.count && !accepted)
                .opacity(page == pages.count && !accepted ? 0.5 : 1)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: 560)
        }
        .preferredColorScheme(.dark)
    }

    private func intro(_ p: Page) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: p.symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.onGold)
                .frame(width: 104, height: 104)
                .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.goldGradient))
                .shadow(color: Theme.gold.opacity(0.45), radius: 24, y: 10)
            Text(p.title).font(Theme.display(28)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            Text(p.text).font(Theme.text(16)).foregroundStyle(Theme.body).multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
            Spacer()
        }
    }

    private var notice: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.gold)
                    .padding(.top, 30)
                Text("Before you start").font(Theme.display(26)).foregroundStyle(Theme.ink)
                Text(LegalText.contentNotice).font(Theme.text(15)).foregroundStyle(Theme.body)
                Button {
                    accepted.toggle()
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: accepted ? "checkmark.square.fill" : "square")
                            .font(.system(size: 22)).foregroundStyle(accepted ? Theme.gold : Theme.muted)
                        Text("I am 18 or older and I accept these terms.")
                            .font(Theme.text(15, .medium)).foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
        }
    }
}

/// Texts shown in onboarding and Settings › About.
enum LegalText {
    static let contentNotice = """
    iNUTT does not host, own or curate any content. It only shows what the sites you add make publicly available, the way a browser would.

    You decide which sites to add and you are responsible for following their terms and the laws where you live. Only save content you have the right to keep.

    Some sites may show content meant for adults.
    """

    static let privacy = """
    iNUTT has no account and no servers of its own. It does not collect, sell or share personal data, and it contains no analytics, tracking or ads.

    Your sites, favorites, history, settings and downloads are stored only on this device. Your PIN is kept in the system keychain. Face ID is handled by the system; iNUTT never sees your face data.

    When you open a site, iNUTT connects directly to that site to load its pages, images and videos, just like a browser. Those sites may receive your IP address and see standard request information under their own privacy policies.

    Deleting the app removes all of its data. You can also clear history and cache at any time in Settings.
    """

    static let terms = """
    iNUTT is a viewer for websites you choose. All content belongs to its owners; iNUTT does not host, upload or modify it.

    You are responsible for the sites you add, for complying with their terms of service and with applicable law, and for any content you save to your device.

    iNUTT is provided as is, without warranty. SCYDE is not liable for content found on third-party sites.
    """
}

/// A plain page of text for Privacy and Terms.
struct LegalView: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(Theme.text(15))
                .foregroundStyle(Theme.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .background(NightSky().ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
