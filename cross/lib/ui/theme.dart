import 'dart:io' show Platform;
import 'dart:math';
import 'dart:ui';

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import '../core/models.dart';
import 'remote_image.dart';

/// Design tokens taken from the ScyHost / SCYDE design language.
class T {
  static const bg = Color(0xFF0D0F14);
  static const navy = Color(0xFF14161D);
  static const navy2 = Color(0xFF1A1D25);
  static const navy3 = Color(0xFF262A35);
  static const ink = Color(0xFFF5F2FF);
  static const body = Color(0xFFB8B4DD);
  static const muted = Color(0xFF8F8BBA);
  static const brand = Color(0xFFC4BBFF);
  static const violet = Color(0xFF8B7CFF);
  static const gold = Color(0xFFFFD76A);
  static const gold2 = Color(0xFFFFE7A0);
  static const gold3 = Color(0xFFE9B84A);
  static const onGold = Color(0xFF1B1530);
  static const err = Color(0xFFFF9AA8);
  static const line = Color(0x21B8B4EB);
  static const line2 = Color(0x42B8B4EB);
  static const edge = Color(0x24FFFFFF);

  static const goldGradient = LinearGradient(colors: [gold, gold2, gold]);

  // Typography: Sora for display, Geist for UI text, Geist Mono for meta, Doto for big numbers.
  static TextStyle display(double size, {FontWeight weight = FontWeight.w700, Color color = ink}) =>
      TextStyle(fontFamily: 'Sora', fontSize: size, fontWeight: weight, color: color, height: 1.15);
  static TextStyle text(double size, {FontWeight weight = FontWeight.w400, Color color = body}) =>
      TextStyle(fontFamily: 'Geist', fontSize: size, fontWeight: weight, color: color);
  static TextStyle mono(double size, {Color color = muted, double spacing = 0}) =>
      TextStyle(fontFamily: 'GeistMono', fontSize: size, fontWeight: FontWeight.w500, color: color, letterSpacing: spacing);
  static TextStyle dot(double size) => TextStyle(fontFamily: 'Doto', fontSize: size, fontWeight: FontWeight.w700, color: gold);

  static ThemeData theme() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: base.colorScheme.copyWith(primary: gold, secondary: brand, surface: navy, onPrimary: onGold),
      textTheme: base.textTheme.apply(fontFamily: 'Geist', bodyColor: ink, displayColor: ink),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: display(17, weight: FontWeight.w600),
        iconTheme: const IconThemeData(color: gold),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? onGold : muted),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? gold : navy3),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: gold),
      dividerColor: line,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        hintStyle: text(14, color: muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: gold),
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {TargetPlatform.android: CupertinoPageTransitionsBuilder(), TargetPlatform.windows: CupertinoPageTransitionsBuilder()},
      ),
    );
  }
}

/// 2 columns on phones, 5 on tablets and desktop windows.
int gridColumns(BuildContext context) => MediaQuery.sizeOf(context).width >= 600 ? 5 : 2;
bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= 600;

/// Night-sky background: deep navy with a gold haze, violet haze and a few stars.
class NightSky extends StatelessWidget {
  const NightSky({super.key});

  @override
  Widget build(BuildContext context) => const RepaintBoundary(
    child: DecoratedBox(
      decoration: BoxDecoration(color: T.bg),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(center: Alignment(0.8, -1.1), radius: 1.0, colors: [Color(0x38FFD76A), Color(0x00FFD76A)]),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(center: Alignment(-1, 1.1), radius: 1.1, colors: [Color(0x2E6C5CE7), Color(0x006C5CE7)]),
          ),
          child: CustomPaint(painter: const _Stars(), size: Size.infinite),
        ),
      ),
    ),
  );
}

class _Stars extends CustomPainter {
  const _Stars();

  @override
  void paint(Canvas canvas, Size size) {
    final rng = Random(42);
    final p = Paint();
    for (var i = 0; i < 70; i++) {
      p.color = Colors.white.withValues(alpha: (0.25 + rng.nextDouble() * 0.6) * 0.55);
      canvas.drawCircle(Offset(rng.nextDouble() * size.width, rng.nextDouble() * size.height), 0.3 + rng.nextDouble() * 0.7, p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Screen scaffold with the night sky behind.
class SkyScaffold extends StatelessWidget {
  final Widget body;
  final PreferredSizeWidget? appBar;
  const SkyScaffold({super.key, required this.body, this.appBar});

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      const Positioned.fill(child: NightSky()),
      Scaffold(backgroundColor: Colors.transparent, appBar: appBar, body: body),
    ],
  );
}

class GlassCard extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final bool highlighted;
  const GlassCard({super.key, required this.child, this.radius = 20, this.padding = EdgeInsets.zero, this.highlighted = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      color: T.navy.withValues(alpha: 0.72),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Colors.white.withValues(alpha: 0.10), Colors.white.withValues(alpha: 0.03), Colors.white.withValues(alpha: 0.055)],
        stops: const [0, 0.42, 1],
      ),
      border: Border.all(color: highlighted ? T.gold.withValues(alpha: 0.35) : T.edge),
      boxShadow: const [BoxShadow(color: Color(0x73000000), blurRadius: 18, offset: Offset(0, 12))],
    ),
    child: child,
  );
}

class GoldButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  const GoldButton({super.key, required this.label, this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: onPressed == null ? 0.5 : 1,
    child: Pressable(
      onTap: onPressed,
      child: Container(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          gradient: T.goldGradient,
          borderRadius: BorderRadius.circular(25),
          boxShadow: [BoxShadow(color: T.gold.withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 6))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 18, color: T.onGold), const SizedBox(width: 8)],
            Text(
              label,
              style: T.text(16, weight: FontWeight.w600, color: T.onGold),
            ),
          ],
        ),
      ),
    ),
  );
}

class GhostButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const GhostButton({super.key, required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onPressed,
    child: Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: T.line2),
      ),
      child: Text(
        label,
        style: T.text(15, weight: FontWeight.w500, color: T.ink),
      ),
    ),
  );
}

/// Scales down slightly while pressed, like the iOS card buttons.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  const Pressable({super.key, required this.child, this.onTap, this.onLongPress});

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(scale: _down ? 0.96 : 1, duration: const Duration(milliseconds: 140), child: widget.child),
    ),
  );
}

class Chip2 extends StatelessWidget {
  final String title;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;
  const Chip2({super.key, required this.title, this.icon, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        gradient: selected ? T.goldGradient : null,
        color: selected ? null : Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: selected ? Colors.transparent : T.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: selected ? T.onGold : T.body), const SizedBox(width: 6)],
          Text(
            title,
            style: T.text(13, weight: FontWeight.w500, color: selected ? T.onGold : T.body),
          ),
        ],
      ),
    ),
  );
}

/// "iNUTT." wordmark with the gold dot, like "scyhost."
class Wordmark extends StatelessWidget {
  final double size;
  const Wordmark({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) => Text.rich(
    maxLines: 1,
    softWrap: false,
    TextSpan(
      children: [
        TextSpan(text: 'iNUTT', style: T.display(size)),
        TextSpan(
          text: '.',
          style: T.display(size, color: T.gold),
        ),
      ],
    ),
  );
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? actionTitle;
  final VoidCallback? onAction;
  const SectionHeader({super.key, required this.title, this.subtitle, this.actionTitle, this.onAction});

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: T.display(19, weight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle != null) Text(subtitle!, style: T.mono(11), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
      if (actionTitle != null && onAction != null)
        Pressable(
          onTap: onAction,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Row(
              children: [
                Text(
                  actionTitle!,
                  style: T.text(13, weight: FontWeight.w500, color: T.gold),
                ),
                const Icon(Icons.chevron_right_rounded, size: 18, color: T.gold),
              ],
            ),
          ),
        ),
    ],
  );
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? buttonTitle;
  final VoidCallback? onButton;
  const EmptyState({super.key, required this.icon, required this.title, required this.message, this.buttonTitle, this.onButton});

  @override
  Widget build(BuildContext context) => GlassCard(
    radius: 28,
    padding: const EdgeInsets.all(28),
    child: SizedBox(
      width: double.infinity,
      child: Column(
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: T.gold.withValues(alpha: 0.12),
              border: Border.all(color: T.gold.withValues(alpha: 0.3)),
            ),
            child: Icon(icon, size: 36, color: T.gold),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: T.display(20, weight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(message, style: T.text(14), textAlign: TextAlign.center),
          if (buttonTitle != null && onButton != null) ...[
            const SizedBox(height: 18),
            GoldButton(label: buttonTitle!, onPressed: onButton),
          ],
        ],
      ),
    ),
  );
}

class SiteIcon extends StatelessWidget {
  final Site? site;
  final double size;
  const SiteIcon({super.key, this.site, this.size = 28});

  @override
  Widget build(BuildContext context) {
    final letter = (site?.name.isNotEmpty ?? false) ? site!.name[0].toUpperCase() : '?';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: T.navy3,
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: T.edge, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(letter, style: T.display(size * 0.45, color: T.gold)),
          if (site?.iconUrl != null)
            Padding(
              padding: EdgeInsets.all(size * 0.12),
              child: RemoteImage(url: site!.iconUrl, referer: site!.url, fit: BoxFit.contain, placeholder: false, decodeWidth: 128),
            ),
        ],
      ),
    );
  }
}

/// Frosted panel used by the floating tab bar and viewer bars.
class Frosted extends StatelessWidget {
  final Widget child;
  final double radius;
  const Frosted({super.key, required this.child, this.radius = 26});

  @override
  Widget build(BuildContext context) {
    // Windows redraws the blur behind it on every scrolled frame, which made the app lag there.
    if (Platform.isWindows) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xE6151820),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: T.edge),
        ),
        child: child,
      );
    }
    return _blurred();
  }

  Widget _blurred() => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0x9E0D0F14),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: T.edge),
        ),
        child: child,
      ),
    ),
  );
}

String relativeTime(DateTime d) {
  final diff = DateTime.now().difference(d);
  if (diff.inSeconds < 60) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min. ago';
  if (diff.inHours < 24) return '${diff.inHours} hr. ago';
  if (diff.inDays < 7) return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  return '${d.day}.${d.month}.${d.year}.';
}

/// Asks for a short name, such as a new collection's. Returns null when cancelled.
Future<String?> askName(BuildContext context, String title, {String initial = ''}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: T.navy,
      title: Text(title, style: T.display(18)),
      content: TextField(
        controller: c,
        autofocus: true,
        style: T.text(15, color: T.ink),
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim().isEmpty ? null : v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, c.text.trim().isEmpty ? null : c.text.trim()),
          child: Text(
            'Save',
            style: T.text(14, weight: FontWeight.w600, color: T.gold),
          ),
        ),
      ],
    ),
  );
}
