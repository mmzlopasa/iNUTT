import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/security.dart';
import '../core/stores.dart';
import '../ui/theme.dart';

class PinDots extends StatelessWidget {
  final int count;
  final int filled;
  const PinDots({super.key, required this.count, required this.filled});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            margin: const EdgeInsets.symmetric(horizontal: 8),
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: i < filled ? T.goldGradient : null,
              border: Border.all(color: i < filled ? Colors.transparent : T.line2, width: 1.5),
            ),
          ),
      ]);
}

class PinPad extends StatelessWidget {
  final ValueChanged<String> onDigit;
  final VoidCallback onDelete;
  final IconData? leftIcon;
  final VoidCallback? onLeft;
  const PinPad({super.key, required this.onDigit, required this.onDelete, this.leftIcon, this.onLeft});

  Widget _key(Widget child, VoidCallback? onTap) => Pressable(
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.lightImpact();
                onTap();
              },
        child: Container(
          width: 76,
          height: 76,
          alignment: Alignment.center,
          decoration: onTap == null
              ? null
              : BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.06), border: Border.all(color: T.line)),
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    Widget digit(String d) => _key(Text(d, style: T.display(28, weight: FontWeight.w400)), () => onDigit(d));
    Widget row(List<Widget> c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [for (final w in c) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: w)]));
    return Column(mainAxisSize: MainAxisSize.min, children: [
      row([digit('1'), digit('2'), digit('3')]),
      row([digit('4'), digit('5'), digit('6')]),
      row([digit('7'), digit('8'), digit('9')]),
      row([
        _key(leftIcon == null ? const SizedBox() : Icon(leftIcon, color: T.gold, size: 30), onLeft),
        digit('0'),
        _key(const Icon(Icons.backspace_outlined, color: T.body, size: 24), onDelete),
      ]),
    ]);
  }
}

class LockView extends StatefulWidget {
  const LockView({super.key});

  @override
  State<LockView> createState() => _LockViewState();
}

class _LockViewState extends State<LockView> with SingleTickerProviderStateMixin {
  String _pin = '';
  bool _wrong = false;
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  @override
  void initState() {
    super.initState();
    if (AppSettings.shared.biometricEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => LockManager.shared.authenticateBiometric());
    }
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  void _digit(String d) {
    final lock = LockManager.shared;
    if (_pin.length >= lock.pinLength) return;
    setState(() {
      _pin += d;
      _wrong = false;
    });
    if (_pin.length == lock.pinLength) {
      if (!lock.verify(_pin)) {
        HapticFeedback.heavyImpact();
        _shake.forward(from: 0);
        setState(() {
          _wrong = true;
          _pin = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.shared;
    final lock = LockManager.shared;
    return Material(
      color: Colors.transparent,
      child: Stack(children: [
        const Positioned.fill(child: NightSky()),
        SafeArea(
          child: Center(
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Wordmark(size: 36),
                const SizedBox(height: 8),
                Text(_wrong ? 'Wrong PIN, try again' : (s.pinEnabled ? 'Enter your PIN' : 'Unlock with ${lock.biometryName}'),
                    style: T.text(15, color: _wrong ? T.err : T.body)),
                const SizedBox(height: 28),
                if (s.pinEnabled) ...[
                  AnimatedBuilder(
                    animation: _shake,
                    builder: (_, child) => Transform.translate(offset: Offset(sin(_shake.value * pi * 6) * 10 * (1 - _shake.value), 0), child: child),
                    child: PinDots(count: lock.pinLength, filled: _pin.length),
                  ),
                  const SizedBox(height: 30),
                  PinPad(
                    onDigit: _digit,
                    onDelete: () => setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1)),
                    leftIcon: s.biometricEnabled ? Icons.fingerprint_rounded : null,
                    onLeft: s.biometricEnabled ? lock.authenticateBiometric : null,
                  ),
                ] else
                  GoldButton(label: 'Unlock', icon: Icons.fingerprint_rounded, onPressed: lock.authenticateBiometric),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class PinSetupView extends StatefulWidget {
  const PinSetupView({super.key});

  @override
  State<PinSetupView> createState() => _PinSetupViewState();
}

class _PinSetupViewState extends State<PinSetupView> {
  int _length = 4;
  String _first = '';
  String _pin = '';
  bool _confirming = false;
  bool _mismatch = false;

  void _digit(String d) {
    if (_pin.length >= _length) return;
    setState(() {
      _pin += d;
      _mismatch = false;
    });
    if (_pin.length < _length) return;
    if (!_confirming) {
      setState(() {
        _first = _pin;
        _pin = '';
        _confirming = true;
      });
    } else if (_pin == _first) {
      LockManager.shared.setPin(_pin).then((_) {
        if (mounted) Navigator.pop(context);
      });
    } else {
      HapticFeedback.heavyImpact();
      setState(() {
        _mismatch = true;
        _pin = '';
        _first = '';
        _confirming = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => SkyScaffold(
        appBar: AppBar(title: const Text('PIN lock')),
        body: Center(
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_confirming ? 'Repeat the PIN' : 'Choose a PIN', style: T.display(22)),
              const SizedBox(height: 6),
              Text(_mismatch ? 'PINs don\'t match, try again' : 'Used to unlock iNUTT', style: T.text(14, color: _mismatch ? T.err : T.body)),
              const SizedBox(height: 16),
              if (!_confirming)
                Wrap(spacing: 8, children: [
                  for (final n in [4, 6])
                    Chip2(
                        title: '$n digits',
                        selected: _length == n,
                        onTap: () => setState(() {
                              _length = n;
                              _pin = '';
                            })),
                ]),
              const SizedBox(height: 24),
              PinDots(count: _length, filled: _pin.length),
              const SizedBox(height: 28),
              PinPad(onDigit: _digit, onDelete: () => setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1))),
              const SizedBox(height: 110),
            ]),
          ),
        ),
      );
}
