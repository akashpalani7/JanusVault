import 'dart:convert';
import 'dart:typed_data';

import '../crypto/crypto_engine.dart';
import '../models/trusted_device.dart';
import '../storage/secure_key_store.dart';
import '../storage/vault_database.dart';
import '../vault/vault_session.dart';

class GeneratedRecoveryKit {
  final String kitId;
  final String printableSecret; // show ONCE, then discard from memory/UI
  const GeneratedRecoveryKit({required this.kitId, required this.printableSecret});
}

class RecoveryService {
  RecoveryService._();
  static final RecoveryService instance = RecoveryService._();

  VaultDatabase get _db => VaultDatabase.instance;

  /// Generates a brand-new Recovery Kit for the currently-unlocked vault.
  /// Marks any previous kit as superseded. The returned [printableSecret]
  /// is the ONLY time this secret will ever be shown — the app must not
  /// cache, log, or persist it anywhere.
  Future<GeneratedRecoveryKit> generateNewRecoveryKit() async {
    final engine = CryptoEngine.instance;
    final vek = VaultSession.instance.vek;

    final secret = engine.generateRecoverySecret();
    final salt = engine.generateSalt();
    final wrappingKey = await engine.deriveRecoveryWrappingKey(recoverySecret: secret, salt: salt);
    final wrapped = await engine.wrapKey(keyToWrap: vek, wrappingKey: wrappingKey);

    final kitId = 'kit_${DateTime.now().microsecondsSinceEpoch}';

    await _db.supersedeAllKits();
    await _db.upsertKit(RecoveryKitRecord(
      kitId: kitId,
      createdAt: DateTime.now().toUtc(),
      saltBase64: base64Encode(salt),
      wrappedVekBase64: wrapped.toBase64(),
      version: 1,
      superseded: false,
    ));

    final printable = engine.encodeRecoverySecret(secret);
    return GeneratedRecoveryKit(kitId: kitId, printableSecret: printable);
  }

  /// Recovers the vault using a user-entered recovery secret (the printable
  /// string from their Recovery Kit). On success, unwraps the VEK into
  /// memory; the caller should immediately follow with
  /// [completeRecoveryOnThisDevice].
  Future<void> recoverWithSecret(String printableSecret) async {
    final active = _db.activeKit;
    if (active == null) {
      throw StateError('No active recovery kit found for this vault.');
    }
    final secretBytes = _decodePrintableSecret(printableSecret);
    final salt = base64Decode(active.saltBase64);
    final engine = CryptoEngine.instance;
    final wrappingKey = await engine.deriveRecoveryWrappingKey(recoverySecret: secretBytes, salt: salt);
    final wrapped = EncryptedBlob.fromBase64(active.wrappedVekBase64);

    // Any mismatch throws (AES-GCM MAC failure), which is exactly what we
    // want: no partial/garbage decryption is possible.
    final vek = await engine.unwrapKey(wrapped: wrapped, wrappingKey: wrappingKey);
    VaultSession.instance.installVekDirectly(vek);
  }

  /// Registers the current device (post-recovery) as trusted, wraps the
  /// now-unlocked VEK for local storage, then issues a new Recovery Kit and
  /// caller should present it to the user to write down again.
  Future<GeneratedRecoveryKit> completeRecoveryOnThisDevice({
    required String displayName,
    required DevicePlatform platform,
  }) async {
    final engine = CryptoEngine.instance;
    final vek = VaultSession.instance.vek;

    final deviceLocalKey = await engine.generateDeviceLocalKey();
    await SecureKeyStore.instance.saveDeviceLocalKey(deviceLocalKey);

    final wrapped = await engine.wrapKey(keyToWrap: vek, wrappingKey: deviceLocalKey);
    final deviceId = 'dev_${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().toUtc();

    await _db.upsertDevice(TrustedDeviceRecord(
      deviceId: deviceId,
      displayName: displayName,
      platform: platform.name,
      pairedAt: now,
      lastSyncedAt: now,
      revoked: false,
      wrappedVekBase64: wrapped.toBase64(),
    ));

    final settings = _db.settings;
    if (settings != null) {
      settings.selfDeviceId = deviceId;
      await _db.saveSettings(settings);
    }

    return generateNewRecoveryKit();
  }

  Uint8List _decodePrintableSecret(String printable) {
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    final cleaned = printable.replaceAll('-', '').toUpperCase();
    var bits = BigInt.zero;
    for (final char in cleaned.split('')) {
      final index = alphabet.indexOf(char);
      if (index == -1) throw FormatException('Invalid character in recovery secret: $char');
      bits = (bits << 5) | BigInt.from(index);
    }
    final totalBits = cleaned.length * 5;
    final paddingBits = totalBits - 256;
    bits = bits >> paddingBits;
    final bytes = Uint8List(32);
    for (var i = 31; i >= 0; i--) {
      bytes[i] = (bits & BigInt.from(0xff)).toInt();
      bits = bits >> 8;
    }
    return bytes;
  }
}
