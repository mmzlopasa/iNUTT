import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/theme.dart';

/// The social networks the Social tab can show. You sign in on the network's own page.
enum SocialNetwork {
  instagram('Instagram', Icons.camera_alt_rounded, 'https://www.instagram.com/', 'instagram.com'),
  tiktok('TikTok', Icons.music_note_rounded, 'https://www.tiktok.com/foryou', 'tiktok.com');

  final String title;
  final IconData icon;
  final String home;
  final String domain;
  const SocialNetwork(this.title, this.icon, this.home, this.domain);
}

/// Keeps one web view per network alive, so switching keeps your place and sign-in.
class SocialState extends ChangeNotifier {
  static final SocialState shared = SocialState._();
  SocialState._() {
    SharedPreferences.getInstance().then((p) {
      final saved = SocialNetwork.values.where((n) => n.name == p.getString('socialNetwork'));
      if (saved.isNotEmpty) select(saved.first);
    });
  }

  SocialNetwork network = SocialNetwork.instagram;
  final Set<SocialNetwork> opened = {SocialNetwork.instagram};
  final Map<SocialNetwork, InAppWebViewController> controllers = {};
  final Set<SocialNetwork> loading = {};
  final Set<SocialNetwork> canGoBack = {};

  void select(SocialNetwork n) {
    if (n == network) {
      goHome(n);
      return;
    }
    network = n;
    opened.add(n);
    SharedPreferences.getInstance().then((p) => p.setString('socialNetwork', n.name));
    notifyListeners();
  }

  void goHome(SocialNetwork n) => controllers[n]?.loadUrl(urlRequest: URLRequest(url: WebUri(n.home)));
  void reload(SocialNetwork n) => controllers[n]?.reload();

  /// Back inside the current network's page history; false when there is nothing to go back to.
  Future<bool> goBack() async {
    final c = controllers[network];
    if (c == null || !await c.canGoBack()) return false;
    await c.goBack();
    return true;
  }

  /// Clears that network's cookies and storage, then shows its sign-in page again.
  Future<void> signOut(SocialNetwork n) async {
    final c = controllers[n];
    try {
      await c?.evaluateJavascript(source: 'try { localStorage.clear(); sessionStorage.clear(); } catch (e) {}');
    } catch (_) {}
    try {
      final cookies = CookieManager.instance();
      for (final host in ['https://www.${n.domain}', 'https://${n.domain}']) {
        await cookies.deleteCookies(url: WebUri(host), domain: '.${n.domain}');
        await cookies.deleteCookies(url: WebUri(host));
      }
    } catch (_) {}
    goHome(n);
  }

  void _state(SocialNetwork n, InAppWebViewController c, {required bool isLoading}) async {
    isLoading ? loading.add(n) : loading.remove(n);
    try {
      (await c.canGoBack()) ? canGoBack.add(n) : canGoBack.remove(n);
    } catch (_) {}
    notifyListeners();
  }
}

/// Instagram and TikTok, signed in with your own accounts, one tap apart.
class SocialView extends StatelessWidget {
  const SocialView({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: SocialState.shared,
        builder: (context, _) {
          final s = SocialState.shared;
          return ColoredBox(
            color: Colors.black,
            child: Column(children: [
              Container(
                color: T.bg,
                padding: EdgeInsets.fromLTRB(12, MediaQuery.paddingOf(context).top + 8, 12, 8),
                child: Row(children: [
                  for (final n in SocialNetwork.values) ...[
                    Chip2(title: n.title, icon: n.icon, selected: n == s.network, onTap: () => s.select(n)),
                    const SizedBox(width: 8),
                  ],
                  const Spacer(),
                  if (s.canGoBack.contains(s.network)) _icon(Icons.chevron_left_rounded, () => s.goBack()),
                  const SizedBox(width: 6),
                  _icon(Icons.refresh_rounded, () => s.reload(s.network)),
                  const SizedBox(width: 6),
                  _icon(Icons.logout_rounded, () => _confirmSignOut(context, s.network)),
                ]),
              ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 72),
                  child: Stack(children: [
                    IndexedStack(
                      index: s.network.index,
                      children: [
                        for (final n in SocialNetwork.values)
                          s.opened.contains(n) ? _SocialWeb(key: ValueKey(n), network: n) : const SizedBox.shrink(),
                      ],
                    ),
                    if (s.loading.contains(s.network))
                      const Align(alignment: Alignment.topCenter, child: LinearProgressIndicator(minHeight: 2, color: T.gold)),
                  ]),
                ),
              ),
            ]),
          );
        },
      );

  Widget _icon(IconData icon, VoidCallback onTap) => Pressable(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.06)),
          child: Icon(icon, size: 18, color: T.ink),
        ),
      );

  void _confirmSignOut(BuildContext context, SocialNetwork n) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: T.bg,
          title: Text('Sign out of ${n.title}?', style: T.display(18, weight: FontWeight.w600)),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                SocialState.shared.signOut(n);
              },
              child: const Text('Sign out', style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        ),
      );
}

class _SocialWeb extends StatelessWidget {
  final SocialNetwork network;
  const _SocialWeb({super.key, required this.network});

  static const _androidUa =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36';

  @override
  Widget build(BuildContext context) {
    final s = SocialState.shared;
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(network.home)),
      initialSettings: InAppWebViewSettings(
        // Without the WebView marker the sites show their normal mobile pages.
        userAgent: Platform.isAndroid ? _androidUa : null,
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        useShouldOverrideUrlLoading: true,
        transparentBackground: true,
        thirdPartyCookiesEnabled: true,
      ),
      onWebViewCreated: (c) => s.controllers[network] = c,
      onLoadStart: (c, _) => s._state(network, c, isLoading: true),
      onLoadStop: (c, _) => s._state(network, c, isLoading: false),
      onReceivedError: (c, req, _) {
        if (req.isForMainFrame == true) s._state(network, c, isLoading: false);
      },
      // Stay inside the app: "open in app" links and app-store redirects are ignored.
      shouldOverrideUrlLoading: (c, action) async {
        final scheme = action.request.url?.scheme.toLowerCase() ?? 'https';
        const allowed = {'http', 'https', 'about', 'blob', 'data', 'javascript'};
        return allowed.contains(scheme) ? NavigationActionPolicy.ALLOW : NavigationActionPolicy.CANCEL;
      },
    );
  }
}
