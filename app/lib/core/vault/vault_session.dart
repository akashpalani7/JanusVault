import 'package:cryptography/cryptography.dart';

import '../crypto/crypto_engine.dart';
import '../storage/secure_key_store.dart';
import '../storage/vault_database.dart';

/// Holds the unwrapped VEK for exactly as long as the vault is unlocked.
/// Nothing here ever touches disk. Call [lock] whenever the app is
/// backgrounded, the screen locks, or after an idle timeout.
class VaultSession {
  VaultSession._();
  static final VaultSession instance = VaultSession._();

  SecretKey? _vek;

  bool get isUnlocked => _vek != null;

  SecretKey get vek {
    final key = _vek;
    if (key == null) {
      throw StateError('Vault is locked. Call unlock() first.');
    }
    return key;
  }

  /// Unlocks the vault for THIS device using its local wrapping key.
  /// Must only be called after a successful biometric/device-credential
  /// check (see BiometricAuthService).
  Future<void> unlock({required String selfDeviceId}) async {
    final deviceLocalKey = await SecureKeyStore.instance.loadDeviceLocalKey();
    if (deviceLocalKey == null) {
      throw StateError('No local device key found — device is not initialized.');
    }
    final deviceRecord = VaultDatabase.instance.findDeviceById(selfDeviceId);
    if (deviceRecord == null) {
      throw StateError('This device is not registered as a trusted device.');
    }
    final wrapped = EncryptedBlob.fromBase64(deviceRecord.wrappedVekBase64);
    final vek = await CryptoEngine.instance.unwrapKey(wrapped: wrapped, wrappingKey: deviceLocalKey);
    _vek = vek;
  }

  /// Used only during initial vault setup, device pairing, or full key
  /// rotation, when a VEK is being installed directly (no unwrap needed
  /// via this device's own local key).
  void installVekDirectly(SecretKey vek) {
    _vek = vek;
  }

  void lock() {
    _vek = null;
  }
}
