import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import 'stores.dart';

/// App lock: biometrics (fingerprint, face, Windows Hello) and a PIN kept in secure storage.
class LockManager extends ChangeNotifier {
  static final LockManager shared = LockManager._();
  LockManager._();

  static const _storage = FlutterSecureStorage();
  final _auth = LocalAuthentication();

  bool isLocked = false;
  bool biometricAvailable = false;
  int pinLength = 4;
  String? _pinHash;
  String? _salt;
  bool _authenticating = false;

  bool get hasLock => AppSettings.shared.pinEnabled || AppSettings.shared.biometricEnabled;

  Future<void> load() async {
    try {
      _pinHash = await _storage.read(key: 'pinHash');
      _salt = await _storage.read(key: 'pinSalt');
      pinLength = int.tryParse(await _storage.read(key: 'pinLength') ?? '') ?? 4;
    } catch (_) {}
    try {
      biometricAvailable = await _auth.isDeviceSupported() && (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      biometricAvailable = false;
    }
    if (_pinHash == null && AppSettings.shared.pinEnabled) AppSettings.shared.pinEnabled = false;
    isLocked = hasLock;
  }

  void lockIfNeeded() {
    if (hasLock && AppSettings.shared.lockOnBackground && !_authenticating) {
      isLocked = true;
      notifyListeners();
    }
  }

  /// Locks right away, from the Home lock button.
  void lockNow() {
    if (!hasLock) return;
    isLocked = true;
    notifyListeners();
  }

  void unlock() {
    isLocked = false;
    notifyListeners();
  }

  Future<bool> authenticateBiometric() async {
    if (_authenticating) return false;
    _authenticating = true;
    try {
      final ok = await _auth.authenticate(localizedReason: 'Unlock iNUTT', biometricOnly: false, persistAcrossBackgrounding: true);
      if (ok) unlock();
      return ok;
    } catch (_) {
      return false;
    } finally {
      _authenticating = false;
    }
  }

  String _hash(String pin, String salt) => sha256.convert(utf8.encode('$salt:$pin')).toString();

  bool verify(String pin) {
    if (_pinHash == null || _salt == null) return false;
    final ok = _hash(pin, _salt!) == _pinHash;
    if (ok) unlock();
    return ok;
  }

  Future<void> setPin(String pin) async {
    final r = Random.secure();
    _salt = base64Url.encode(List.generate(16, (_) => r.nextInt(256)));
    _pinHash = _hash(pin, _salt!);
    pinLength = pin.length;
    await _storage.write(key: 'pinHash', value: _pinHash);
    await _storage.write(key: 'pinSalt', value: _salt);
    await _storage.write(key: 'pinLength', value: '$pinLength');
    AppSettings.shared.pinEnabled = true;
    notifyListeners();
  }

  Future<void> removePin() async {
    _pinHash = null;
    _salt = null;
    await _storage.delete(key: 'pinHash');
    await _storage.delete(key: 'pinSalt');
    AppSettings.shared.pinEnabled = false;
    notifyListeners();
  }

  String get biometryName => defaultTargetPlatform == TargetPlatform.windows ? 'Windows Hello' : 'Biometrics';
}
