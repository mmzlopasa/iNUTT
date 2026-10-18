import 'package:flutter/material.dart';

import '../ui/theme.dart';

/// Texts shown in onboarding and Settings › About.
class LegalText {
  static const contentNotice =
      'iNUTT does not host, own or curate any content. It only shows what the sites you add make publicly available, the way a browser would.\n\n'
      'You decide which sites to add and you are responsible for following their terms and the laws where you live. Only save content you have the right to keep.\n\n'
      'Some sites may show content meant for adults.';

  static const privacy =
      'iNUTT has no account and no servers of its own. It does not collect, sell or share personal data, and it contains no analytics, tracking or ads.\n\n'
      'Your sites, favorites, history, settings and downloads are stored only on this device. Your PIN is kept in the system\'s secure storage. Fingerprint and face unlock are handled by the system; iNUTT never sees your biometric data.\n\n'
      'When you open a site, iNUTT connects directly to that site to load its pages, images and videos, just like a browser. Those sites may receive your IP address and see standard request information under their own privacy policies.\n\n'
      'Uninstalling the app removes all of its data. You can also clear history and cache at any time in Settings.';

  static const terms =
      'iNUTT is a viewer for websites you choose. All content belongs to its owners; iNUTT does not host, upload or modify it.\n\n'
      'You are responsible for the sites you add, for complying with their terms of service and with applicable law, and for any content you save to your device.\n\n'
      'iNUTT is provided as is, without warranty. SCYDE is not liable for content found on third-party sites.';
}

/// First launch: what iNUTT does, how your data is handled, and the content notice you accept.
class OnboardingView extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingView({super.key, required this.onDone});

  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  final _pager = PageController();
  int _page = 0;
  bool _accepted = false;

  static const _pages = [
    (
      Icons.auto_awesome_rounded,
      'Your sites, one app',
      'Add up to 50 sites with images, GIFs and videos. iNUTT shows them natively, fast and without a browser.',
    ),
    (
      Icons.smart_display_rounded,
      'Watch your way',
      'Categories, search, favorites, history, a full-screen viewer and Reels you swipe like TikTok.',
    ),
    (
      Icons.shield_rounded,
      'Private by design',
      'No account, no tracking, no ads. Everything you add stays on this device, locked with biometrics or a PIN.',
    ),
  ];

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  void _go(int i) => _pager.animateToPage(i, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);

  @override
  Widget build(BuildContext context) {
    final last = _page == _pages.length;
    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          const Positioned.fill(child: NightSky()),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: Row(
                        children: [
                          const Wordmark(size: 26),
                          const Spacer(),
                          if (!last)
                            TextButton(
                              onPressed: () => _go(_pages.length),
                              child: Text(
                                'Skip',
                                style: T.text(14, weight: FontWeight.w500, color: T.muted),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: PageView(
                        controller: _pager,
                        onPageChanged: (i) => setState(() => _page = i),
                        children: [for (final p in _pages) _intro(p.$1, p.$2, p.$3), _notice()],
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i <= _pages.length; i++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            width: i == _page ? 22 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(3),
                              gradient: i == _page ? T.goldGradient : null,
                              color: i == _page ? null : Colors.white.withValues(alpha: 0.18),
                            ),
                          ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                      child: GoldButton(
                        label: last ? 'Get started' : 'Continue',
                        onPressed: last ? (_accepted ? widget.onDone : null) : () => _go(_page + 1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _intro(IconData icon, String title, String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 28),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 104,
          height: 104,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            gradient: T.goldGradient,
            boxShadow: [BoxShadow(color: T.gold.withValues(alpha: 0.45), blurRadius: 24, offset: const Offset(0, 10))],
          ),
          child: Icon(icon, size: 46, color: T.onGold),
        ),
        const SizedBox(height: 24),
        Text(
          title,
          textAlign: TextAlign.center,
          style: T.display(28, weight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: T.text(16, color: T.body),
        ),
        const SizedBox(height: 60),
      ],
    ),
  );

  Widget _notice() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 30, 24, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.verified_user_rounded, size: 30, color: T.gold),
        const SizedBox(height: 14),
        Text('Before you start', style: T.display(26, weight: FontWeight.w700)),
        const SizedBox(height: 14),
        Text(LegalText.contentNotice, style: T.text(15, color: T.body)),
        const SizedBox(height: 18),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _accepted = !_accepted),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_accepted ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, color: _accepted ? T.gold : T.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('I am 18 or older and I accept these terms.', style: T.text(15, weight: FontWeight.w500)),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// A plain page of text for Privacy and Terms.
class LegalView extends StatelessWidget {
  final String title;
  final String text;
  const LegalView({super.key, required this.title, required this.text});

  @override
  Widget build(BuildContext context) => SkyScaffold(
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      title: Text(title, style: T.display(17, weight: FontWeight.w600)),
      iconTheme: const IconThemeData(color: T.gold),
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Text(text, style: T.text(15, color: T.body)),
        ),
      ),
    ),
  );
}
