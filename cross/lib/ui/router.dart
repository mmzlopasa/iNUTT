import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/stores.dart';
import '../screens/site_detail.dart';
import '../screens/viewer.dart';

enum AppTab {
  home('Home', Icons.home_rounded),
  reels('Reels', Icons.smart_display_rounded),
  sites('Sites', Icons.grid_view_rounded),
  search('Search', Icons.search_rounded),
  favorites('Favorites', Icons.favorite_rounded);

  final String title;
  final IconData icon;
  const AppTab(this.title, this.icon);
}

/// False while the app is in the background or the app switcher.
final appResumed = ValueNotifier<bool>(true);

/// Navigation state of every tab, so any screen (and the viewer) can open a site or category.
class AppRouter extends ChangeNotifier {
  static final AppRouter shared = AppRouter._();
  AppRouter._();

  final rootKey = GlobalKey<NavigatorState>();
  final keys = {for (final t in AppTab.values) t: GlobalKey<NavigatorState>()};
  AppTab tab = AppTab.home;

  void select(AppTab t) {
    if (t == tab) {
      keys[t]?.currentState?.popUntil((r) => r.isFirst);
      return;
    }
    tab = t;
    notifyListeners();
  }

  void push(Widget page) {
    if (tab == AppTab.reels) {
      tab = AppTab.sites;
      notifyListeners();
    }
    final nav = keys[tab]?.currentState;
    nav?.push(MaterialPageRoute<void>(builder: (_) => page));
  }

  void openSite(String siteId, {SiteCategory? category, bool allCategories = false}) =>
      push(SiteRouteView(siteId: siteId, category: category, allCategories: allCategories));

  /// Opens a tapped item: category tiles navigate to their grid, media opens in the viewer.
  void open(List<MediaItem> items, int index) {
    if (index < 0 || index >= items.length) return;
    final item = items[index];
    final known = SiteStore.shared.site(item.siteId)?.categoryMatching(item.pageUrl);
    if (known != null) return openSite(item.siteId, category: known);
    if (item.isListing && item.asCategory != null) return openSite(item.siteId, category: item.asCategory);
    // Keep category tiles out of the pager, and keep it light: a window around the tapped item.
    final media = items.where((e) => !e.isListing).toList();
    var i = media.indexOf(item);
    if (i < 0) i = 0;
    final lower = (i - 150).clamp(0, media.length);
    final upper = (i + 150).clamp(0, media.length);
    rootKey.currentState?.push(PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => MediaViewer(items: media.sublist(lower, upper), startIndex: i - lower),
      transitionsBuilder: (_, a, __, child) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
      ),
    ));
  }

  /// Called from the viewer when an item turned out to be a category page.
  void openListing(MediaItem item) {
    final c = item.asCategory;
    if (c == null) return;
    rootKey.currentState?.pop();
    Future<void>.delayed(const Duration(milliseconds: 250), () => openSite(item.siteId, category: c));
  }
}
