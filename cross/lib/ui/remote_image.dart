import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/image_cache.dart';
import 'theme.dart';

/// Loading placeholder with a soft moving highlight.
class Shimmer extends StatefulWidget {
  final double radius;
  const Shimmer({super.key, this.radius = 0});

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _c,
      builder: (_, __) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            begin: Alignment(-1.5 + 3 * _c.value, -0.3),
            end: Alignment(-0.5 + 3 * _c.value, 0.3),
            colors: const [T.navy2, Color(0xFF242836), T.navy2],
          ),
        ),
      ),
    ),
  );
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
