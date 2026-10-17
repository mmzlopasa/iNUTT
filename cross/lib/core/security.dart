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
  String? _decoyHash;
  bool _authenticating = false;

  /// Unlocked with the decoy PIN: an empty app is shown instead of the real one until the next lock.
  bool decoy = false;
  bool get hasDecoyPin => _decoyHash != null;

  bool get hasLock => AppSettings.shared.pinEnabled || AppSettings.shared.biometricEnabled;

  Future<void> load() async {
    try {
      _pinHash = await _storage.read(key: 'pinHash');
      _salt = await _storage.read(key: 'pinSalt');
      _decoyHash = await _storage.read(key: 'decoyHash');
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
    if (hasLock && (AppSettings.shared.lockOnBackground || decoy) && !_authenticating) lockNow();
  }

  /// Locks right away, from the Home lock button or a shake.
  void lockNow() {
    if (!hasLock) return;
    isLocked = true;
    decoy = false;
    notifyListeners();
  }

  void unlock() {
    isLocked = false;
    decoy = false;
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
    final h = _hash(pin, _salt!);
    if (_decoyHash != null && h == _decoyHash && h != _pinHash) {
      isLocked = false;
      decoy = true;
      notifyListeners();
      return true;
    }
    final ok = h == _pinHash;
    if (ok) unlock();
    return ok;
  }

  bool matchesPin(String pin) => _pinHash != null && _salt != null && _hash(pin, _salt!) == _pinHash;

  Future<void> setDecoyPin(String? pin) async {
    if (pin == null || _salt == null) {
      _decoyHash = null;
      await _storage.delete(key: 'decoyHash');
    } else {
      _decoyHash = _hash(pin, _salt!);
      await _storage.write(key: 'decoyHash', value: _decoyHash);
    }
    notifyListeners();
  }

  Future<void> setPin(String pin) async {
    // A new salt would make the decoy PIN unusable; it has to be set again.
    await setDecoyPin(null);
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
    await setDecoyPin(null);
    _pinHash = null;
    _salt = null;
    await _storage.delete(key: 'pinHash');
    await _storage.delete(key: 'pinSalt');
    AppSettings.shared.pinEnabled = false;
    notifyListeners();
  }

  String get biometryName => defaultTargetPlatform == TargetPlatform.windows ? 'Windows Hello' : 'Biometrics';
}
