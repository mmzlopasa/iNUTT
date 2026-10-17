import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/image_cache.dart';
import 'theme.dart';

/// One clock for every placeholder on screen, instead of a ticker per card.
class _ShimmerClock extends ChangeNotifier {
  static final _ShimmerClock shared = _ShimmerClock();
  late final Ticker _ticker = Ticker((elapsed) {
    value = (elapsed.inMilliseconds % 1400) / 1400;
    notifyListeners();
  });
  double value = 0;
  int _users = 0;

  void attach() {
    if (_users++ == 0) _ticker.start();
  }

  void detach() {
    if (--_users == 0) _ticker.stop();
  }
}

/// Loading placeholder with a soft moving highlight.
class Shimmer extends StatefulWidget {
  final double radius;
  const Shimmer({super.key, this.radius = 0});

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> {
  @override
  void initState() {
    super.initState();
    _ShimmerClock.shared.attach();
  }

  @override
  void dispose() {
    _ShimmerClock.shared.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(painter: _ShimmerPainter(widget.radius), size: Size.infinite),
  );
}

/// Repaints from the shared clock without rebuilding any widget.
class _ShimmerPainter extends CustomPainter {
  final double radius;
  _ShimmerPainter(this.radius) : super(repaint: _ShimmerClock.shared);

  @override
  void paint(Canvas canvas, Size size) {
    final v = _ShimmerClock.shared.value;
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment(-1.5 + 3 * v, -0.3),
        end: Alignment(-0.5 + 3 * v, 0.3),
        colors: const [T.navy2, Color(0xFF242836), T.navy2],
      ).createShader(rect);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)), paint);
  }

  @override
  bool shouldRepaint(_ShimmerPainter old) => old.radius != radius;
}

/// Network image through the shared memory + disk cache. Cached images appear in the first frame.
class RemoteImage extends StatefulWidget {
  final Uri? url;
  final Uri? referer;
  final BoxFit fit;
  final bool placeholder;

  /// Decode width in logical pixels; keeps memory low and scrolling smooth.
  final double? decodeWidth;
  const RemoteImage({super.key, required this.url, this.referer, this.fit = BoxFit.cover, this.placeholder = true, this.decodeWidth = 400});

  @override
  State<RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<RemoteImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(RemoteImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _start();
  }

  void _start() {
    final url = widget.url;
    _failed = false;
    _bytes = ImagePipeline.shared.cached(url);
    if (_bytes != null) return;
    if (url == null) {
      _failed = true;
      return;
    }
    ImagePipeline.shared.load(url, referer: widget.referer).then((b) {
      if (!mounted || widget.url != url) return;
      setState(() {
        _bytes = b;
        _failed = b == null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b != null) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      return Image.memory(
        b,
        fit: widget.fit,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
        cacheWidth: widget.decodeWidth == null ? null : (widget.decodeWidth! * dpr).round(),
        filterQuality: FilterQuality.medium,
        frameBuilder: (context, child, frame, sync) =>
            sync ? child : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 220), child: child),
        errorBuilder: (_, __, ___) => widget.placeholder ? _failedBox() : const SizedBox.shrink(),
      );
    }
    if (!widget.placeholder) return const SizedBox.shrink();
    return _failed ? _failedBox() : const Shimmer();
  }

  Widget _failedBox() => const ColoredBox(
    color: T.navy2,
    child: Center(child: Icon(Icons.image_outlined, color: Color(0x998F8BBA), size: 24)),
  );
}
