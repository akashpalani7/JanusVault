import 'dart:convert';
import 'dart:typed_data';

import '../crypto/crypto_engine.dart';
import '../models/recovery_kit.dart';
import '../models/trusted_device.dart';
import '../storage/secure_key_store.dart';
import '../storage/vault_database.dart';
import '../vault/vault_session.dart';

class GeneratedRecoveryKit {
  final String kitId;
  final String printableSecret; // show ONCE, then discard from memory/UI
  final String packageEncoded; // safe to export/QR/print — see RecoveryKitPackage
  const GeneratedRecoveryKit({required this.kitId, required this.printableSecret, required this.packageEncoded});
}

class RecoveryService {
  RecoveryService._();
  static final RecoveryService instance = RecoveryService._();

  VaultDatabase get _db => VaultDatabase.instance;

  /// Generates a brand-new Recovery Kit for the currently-unlocked vault.
  /// Marks any previous kit as superseded. The returned [GeneratedRecoveryKit]
  /// has TWO parts the user must save SEPARATELY:
  ///   - `printableSecret`: short, memorizable/writable, shown only once —
  ///     never stored by this app anywhere.
  ///   - `packageEncoded`: safe to export/print/QR/email/cloud-store, since
  ///     it's just ciphertext + salt and is useless without the secret.
  /// Recovery needs BOTH. This split is what makes recovery actually work
  /// on a brand-new device that has none of this app's local data — see
  /// RecoveryKitPackage's doc comment for why that matters.
  Future<GeneratedRecoveryKit> generateNewRecoveryKit() async {
    final engine = CryptoEngine.instance;
    final vek = VaultSession.instance.vek;

    final secret = engine.generateRecoverySecret();
    final salt = engine.generateSalt();
    final wrappingKey = await engine.deriveRecoveryWrappingKey(recoverySecret: secret, salt: salt);
    final wrapped = await engine.wrapKey(keyToWrap: vek, wrappingKey: wrappingKey);

    final kitId = 'kit_${DateTime.now().microsecondsSinceEpoch}';
    final saltBase64 = base64Encode(salt);
    final wrappedVekBase64 = wrapped.toBase64();

    await _db.supersedeAllKits();
    await _db.upsertKit(RecoveryKitRecord(
      kitId: kitId,
      createdAt: DateTime.now().toUtc(),
      saltBase64: saltBase64,
      wrappedVekBase64: wrappedVekBase64,
      version: 1,
      superseded: false,
    ));

    final printable = engine.encodeRecoverySecret(secret);
    final package = RecoveryKitPackage(kitId: kitId, saltBase64: saltBase64, wrappedVekBase64: wrappedVekBase64);
    return GeneratedRecoveryKit(kitId: kitId, printableSecret: printable, packageEncoded: package.encode());
  }

  /// Recovers the vault using a user-entered recovery secret. `providedPackage`
  /// is the exported Recovery Kit Package the user saved when the kit was
  /// generated (QR/text) — required on a genuinely fresh device, since
  /// this device's own database has no record of any kit. If this device
  /// happens to already have a locally-known active kit (e.g. recovering
  /// on a device that was previously paired), that's used as a fallback
  /// when no package is supplied, purely for convenience.
  Future<void> recoverWithSecret(String printableSecret, {RecoveryKitPackage? providedPackage}) async {
    final RecoveryKitPackage kit;
    if (providedPackage != null) {
      kit = providedPackage;
    } else {
      final active = _db.activeKit;
      if (active == null) {
        throw StateError(
          'No Recovery Kit found on this device. Scan or paste the Recovery Kit '
          'package you saved when this kit was created — the secret alone isn\'t enough.',
        );
      }
      kit = RecoveryKitPackage.fromMeta(RecoveryKitMeta(
        kitId: active.kitId,
        createdAt: active.createdAt,
        saltBase64: active.saltBase64,
        wrappedVekBase64: active.wrappedVekBase64,
      ));
    }

    final secretBytes = _decodePrintableSecret(printableSecret);
    final salt = base64Decode(kit.saltBase64);
    final engine = CryptoEngine.instance;
    final wrappingKey = await engine.deriveRecoveryWrappingKey(recoverySecret: secretBytes, salt: salt);
    final wrapped = EncryptedBlob.fromBase64(kit.wrappedVekBase64);

    // Any mismatch throws (AES-GCM MAC failure), which is exactly what we
    // want: no partial/garbage decryption is possible.
    final vek = await engine.unwrapKey(wrapped: wrapped, wrappingKey: wrappingKey);
    VaultSession.instance.installVekDirectly(vek);

    // Record the kit metadata locally too now (harmless if it was already
    // there) so a subsequent `generateNewRecoveryKit`'s supersede step has
    // something concrete to supersede, and so `allKits` in a backup export
    // reflects reality on this device going forward.
    await _db.upsertKit(RecoveryKitRecord(
      kitId: kit.kitId,
      createdAt: DateTime.now().toUtc(),
      saltBase64: kit.saltBase64,
      wrappedVekBase64: kit.wrappedVekBase64,
      version: 1,
      superseded: false,
    ));
  }

  /// Registers the current device (post-recovery) as trusted, wraps the
  /// now-unlocked VEK for local storage, then issues a new Recovery Kit —
  /// the OLD one (the one just used) is single-use and gets superseded as
  /// part of this. The caller MUST show the returned kit to the user
  /// before navigating away: it is the only copy of the new secret that
  /// will ever exist, and skipping this leaves the user with a vault that
  /// no longer has a usable Recovery Kit at all.
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
