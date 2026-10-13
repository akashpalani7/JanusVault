import 'dart:convert';
import 'package:cryptography/cryptography.dart';

import '../crypto/crypto_engine.dart';
import '../models/trusted_device.dart';
import '../storage/secure_key_store.dart';
import '../storage/vault_database.dart';
import '../sync/lan_sync_service.dart';
import '../sync/sync_protocol.dart';
import '../vault/vault_session.dart';

/// A pairing package is self-contained: it's exactly what gets encoded
/// into the QR code shown on the device that already holds the vault.
/// Scanning it is the ENTIRE pairing handshake — no network round trip
/// required, no asymmetric crypto, no mismatch between platforms. See
/// CryptoEngine's "Device pairing" section for why this replaced X25519.
class PairingPackage {
  final String pairingCodePrintable;
  final String wrappedVekForTransitBase64;
  final String? deviceId;

  const PairingPackage({
    required this.pairingCodePrintable,
    required this.wrappedVekForTransitBase64,
    this.deviceId,
  });

  /// Encodes as a single string suitable for a QR code or manual typing:
  /// `"janusvault-pair:v2:<code>:<wrappedVek>[:<deviceId>]"`
  String encode() {
    if (deviceId != null && deviceId!.isNotEmpty) {
      return 'janusvault-pair:v2:$pairingCodePrintable:$wrappedVekForTransitBase64:$deviceId';
    }
    return 'janusvault-pair:v2:$pairingCodePrintable:$wrappedVekForTransitBase64';
  }

  static PairingPackage decode(String raw) {
    final parts = raw.split(':');
    if ((parts.length != 4 && parts.length != 5) || parts[0] != 'janusvault-pair' || parts[1] != 'v2') {
      throw const FormatException('Not a valid JanusVault pairing code');
    }
    return PairingPackage(
      pairingCodePrintable: parts[2],
      wrappedVekForTransitBase64: parts[3],
      deviceId: parts.length == 5 ? parts[4] : null,
    );
  }
}

class DeviceManager {
  DeviceManager._();
  static final DeviceManager instance = DeviceManager._();

  VaultDatabase get _db => VaultDatabase.instance;

  /// Called once, on first-ever app launch, before any vault exists.
  /// Generates this device's local key and registers it as the first
  /// trusted device holding a freshly generated VEK.
  Future<String> initializeFirstDevice(
      {required String displayName, required DevicePlatform platform}) async {
    final engine = CryptoEngine.instance;

    final deviceLocalKey = await engine.generateDeviceLocalKey();
    await SecureKeyStore.instance.saveDeviceLocalKey(deviceLocalKey);

    final vek = await engine.generateVek();
    VaultSession.instance.installVekDirectly(vek);

    final wrapped =
        await engine.wrapKey(keyToWrap: vek, wrappingKey: deviceLocalKey);

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

    await _db.saveSettings(VaultSettingsRecord(
      recycleBinRetentionDays: 30,
      requireBiometricForReveal: true,
      selfDeviceId: deviceId,
      vaultCreatedAt: now,
    ));

    return deviceId;
  }

  /// Called on the device that ALREADY holds the vault, to produce a
  /// one-shot pairing package containing everything a brand-new device
  /// needs — the whole handshake fits in a single QR code.
  Future<PairingPackage> createPairingPackage({
    String? targetDeviceId,
    String? targetDisplayName,
  }) async {
    final engine = CryptoEngine.instance;
    final code = engine.generatePairingCode();
    final pairingKey = await engine.derivePairingKeyFromCode(code);
    final wrapped = await engine.wrapKey(
        keyToWrap: VaultSession.instance.vek, wrappingKey: pairingKey);
    final devId = targetDeviceId ?? 'ext_${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now().toUtc();

    await _db.upsertDevice(TrustedDeviceRecord(
      deviceId: devId,
      displayName: targetDisplayName ?? 'Browser Extension',
      platform: DevicePlatform.browserExtension.name,
      pairedAt: now,
      lastSyncedAt: now,
      revoked: false,
      wrappedVekBase64: '',
    ));

    return PairingPackage(
      pairingCodePrintable: engine.encodePairingCode(code),
      wrappedVekForTransitBase64: wrapped.toBase64(),
      deviceId: devId,
    );
  }

  /// Called on the NEW device after scanning/typing the pairing package:
  /// re-derives the same key from the pairing code, unwraps the VEK, wraps
  /// it again under this device's own local key for storage, and
  /// registers itself as trusted. Fully offline — no sync channel needed.
  Future<String> completeNewDevicePairing({
    required PairingPackage package,
    required String displayName,
    required DevicePlatform platform,
  }) async {
    final engine = CryptoEngine.instance;

    final code = engine.decodePairingCode(package.pairingCodePrintable);
    final pairingKey = await engine.derivePairingKeyFromCode(code);
    final transitBlob =
        EncryptedBlob.fromBase64(package.wrappedVekForTransitBase64);

    // Wrong code -> AES-GCM MAC failure -> throws. No partial/garbage
    // decryption is possible, which is exactly the property we want.
    final vek =
        await engine.unwrapKey(wrapped: transitBlob, wrappingKey: pairingKey);
    VaultSession.instance.installVekDirectly(vek);

    final deviceLocalKey = await engine.generateDeviceLocalKey();
    await SecureKeyStore.instance.saveDeviceLocalKey(deviceLocalKey);
    final wrappedForStorage =
        await engine.wrapKey(keyToWrap: vek, wrappingKey: deviceLocalKey);

    final deviceId = package.deviceId ?? 'dev_${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().toUtc();

    await _db.upsertDevice(TrustedDeviceRecord(
      deviceId: deviceId,
      displayName: displayName,
      platform: platform.name,
      pairedAt: now,
      lastSyncedAt: now,
      revoked: false,
      wrappedVekBase64: wrappedForStorage.toBase64(),
    ));

    await _db.saveSettings(VaultSettingsRecord(
      recycleBinRetentionDays: 30,
      requireBiometricForReveal: true,
      selfDeviceId: deviceId,
      vaultCreatedAt: now,
    ));

    return deviceId;
  }

  /// This device's own record, converted to the lightweight wire shape
  /// sent to peers during sync. Returns null before the vault has been
  /// initialized (no settings row yet).
  DeviceInfo? selfDeviceInfo() {
    final settings = _db.settings;
    if (settings == null) return null;
    final record = _db.findDeviceById(settings.selfDeviceId);
    if (record == null) return null;
    return DeviceInfo(
      deviceId: record.deviceId,
      displayName: record.displayName,
      platform: record.platform,
      pairedAt: record.pairedAt,
      lastSyncedAt: record.lastSyncedAt,
      revoked: record.revoked,
    );
  }

  /// Every OTHER trusted device this device already knows about, as the
  /// wire shape — sent alongside [selfDeviceInfo] so a peer that's been
  /// offline for a while can catch up transitively (A pairs B, B pairs C;
  /// once B syncs with A, A learns about C too without ever meeting it).
  List<DeviceInfo> knownPeerDeviceInfos() {
    final selfId = _db.settings?.selfDeviceId;
    return _db.allDevices
        .where((d) => d.deviceId != selfId)
        .map((r) => DeviceInfo(
              deviceId: r.deviceId,
              displayName: r.displayName,
              platform: r.platform,
              pairedAt: r.pairedAt,
              lastSyncedAt: r.lastSyncedAt,
              revoked: r.revoked,
            ))
        .toList();
  }

  /// Merges a batch of [DeviceInfo] learned from a sync peer into the
  /// local trusted-device table. New devices are added (with an empty
  /// wrapped VEK — meaningless for a device that isn't this one — purely
  /// so it shows up in the list); known devices have their `revoked` flag
  /// OR'd in (once revoked anywhere, it stays revoked everywhere) and
  /// their `lastSyncedAt` bumped to the newer of the two timestamps. This
  /// device's OWN record is never touched here — see [touchSelfLastSynced].
  Future<void> mergeIncomingDeviceInfos(List<DeviceInfo> infos) async {
    final selfId = _db.settings?.selfDeviceId;
    for (final info in infos) {
      if (info.deviceId == selfId) continue;
      final existing = _db.findDeviceById(info.deviceId);
      if (existing == null) {
        await _db.upsertDevice(TrustedDeviceRecord(
          deviceId: info.deviceId,
          displayName: info.displayName,
          platform: info.platform,
          pairedAt: info.pairedAt,
          lastSyncedAt: info.lastSyncedAt,
          revoked: info.revoked,
          wrappedVekBase64: '',
        ));
      } else {
        var changed = false;
        if (info.revoked && !existing.revoked) {
          existing.revoked = true;
          changed = true;
        }
        if (info.lastSyncedAt.isAfter(existing.lastSyncedAt)) {
          existing.lastSyncedAt = info.lastSyncedAt;
          changed = true;
        }
        if (info.displayName != existing.displayName && info.displayName.isNotEmpty) {
          existing.displayName = info.displayName;
          changed = true;
        }
        if (changed) await _db.upsertDevice(existing);
      }
    }
  }

  /// Call this on BOTH ends whenever a sync round with a peer completes
  /// successfully — it's the only reliable signal that "this device was
  /// definitely reachable and current just now", which is what
  /// "Last synced" is supposed to mean.
  Future<void> touchSelfLastSynced() async {
    final selfId = _db.settings?.selfDeviceId;
    if (selfId == null) return;
    final record = _db.findDeviceById(selfId);
    if (record == null) return;
    record.lastSyncedAt = DateTime.now().toUtc();
    await _db.upsertDevice(record);
  }

  List<TrustedDevice> listDevices() {
    final selfId = _db.settings?.selfDeviceId;
    return _db.allDevices
        .where((r) => r.deviceId != selfId)
        .map((r) => TrustedDevice(
              deviceId: r.deviceId,
              displayName: r.displayName,
              platform: DevicePlatform.values.byName(r.platform),
              pairedAt: r.pairedAt,
              lastSyncedAt: r.lastSyncedAt,
              revoked: r.revoked,
            ))
        .toList();
  }

  /// Revokes a device's access. This does NOT rotate the VEK automatically
  /// — call [rotateVek] separately if the device may have been compromised
  /// (vs. simply lost/replaced with nothing sensitive on it).
  Future<void> revokeDevice(String deviceId) async {
    final record = _db.findDeviceById(deviceId);
    if (record == null) return;
    record.revoked = true;
    await _db.upsertDevice(record);
    try {
      LanSyncService.instance.disconnectRevokedDevice(deviceId);
    } catch (_) {}
  }

  /// Full key rotation after a suspected compromise: generates a brand-new
  /// VEK and re-wraps it for the CURRENT device only. Every other
  /// still-trusted device must independently obtain the new VEK via a
  /// fresh pairing package or sync from this device afterwards. Callers
  /// must also re-persist every vault entry with the new VEK via
  /// VaultRepository (re-encrypting all data is the caller's job, not
  /// this method's, since it may want to show progress for a large vault).
  Future<SecretKey> rotateVek({required String selfDeviceId}) async {
    final engine = CryptoEngine.instance;
    final oldVek = VaultSession.instance.vek;
    
    final newVek = await engine.generateVek();

    final deviceLocalKey = await SecureKeyStore.instance.loadDeviceLocalKey();
    if (deviceLocalKey == null) throw StateError('No local device key found');
    final wrapped = await engine.wrapKey(keyToWrap: newVek, wrappingKey: deviceLocalKey);

    final record = _db.findDeviceById(selfDeviceId);
    if (record != null) {
      record.wrappedVekBase64 = wrapped.toBase64();
      await _db.upsertDevice(record);
    }
    
    final oldAuthKey = await engine.deriveSyncAuthKey(oldVek);
    final wrappedForSync = await engine.wrapKey(keyToWrap: newVek, wrappingKey: oldAuthKey);
    final oldAuthKeyBytes = await oldAuthKey.extractBytes();
    
    final settings = _db.settings;
    if (settings != null) {
      settings.queuedRotationOldSyncAuthKeyBase64 = base64Encode(oldAuthKeyBytes);
      settings.queuedRotationWrappedNewVekBase64 = wrappedForSync.toBase64();
      await _db.saveSettings(settings);
    }
    
    return newVek;
  }
}
