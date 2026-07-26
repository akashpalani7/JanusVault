import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The ONLY thing ever kept in [FlutterSecureStorage] (Android Keystore /
/// iOS Keychain, hardware-backed where available): this device's local
/// wrapping key, which wraps the VEK for at-rest storage. The VEK itself
/// is NEVER stored here directly, and NEVER in plaintext anywhere. It only
/// ever exists wrapped (see CryptoEngine.wrapKey).
class SecureKeyStore {
  SecureKeyStore._();
  static final SecureKeyStore instance = SecureKeyStore._();

  static const _androidOptions = AndroidOptions(encryptedSharedPreferences: true);
  static const _iosOptions = IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device);

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: _androidOptions,
    iOptions: _iosOptions,
  );

  static const _kDeviceLocalKey = 'peervault.device_local_key';

  Future<void> saveDeviceLocalKey(SecretKey key) async {
    final bytes = await key.extractBytes();
    await _storage.write(key: _kDeviceLocalKey, value: base64Encode(bytes));
  }

  Future<SecretKey?> loadDeviceLocalKey() async {
    final value = await _storage.read(key: _kDeviceLocalKey);
    if (value == null) return null;
    return SecretKey(base64Decode(value));
  }

  Future<void> wipeAll() => _storage.deleteAll();
}
