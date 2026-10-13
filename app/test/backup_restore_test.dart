import 'package:flutter_test/flutter_test.dart';
import 'package:janusvault/core/storage/vault_database.dart';

void main() {
  group('Vault Records & Backup JSON Serialization', () {
    test('VaultEntryRecord serialization and deserialization', () {
      final now = DateTime.now().toUtc();
      final entry = VaultEntryRecord(
        uuid: 'test-uuid-42',
        encryptedWebsiteName: 'blob_name',
        encryptedWebsiteUrl: 'blob_url',
        encryptedUsername: 'blob_user',
        encryptedPassword: 'blob_pass',
        createdAt: now,
        lastUpdated: now,
        hash: 'hash-val',
        deleted: false,
      );

      final json = entry.toJson();
      final restored = VaultEntryRecord.fromJson(json);

      expect(restored.uuid, equals('test-uuid-42'));
      expect(restored.encryptedWebsiteName, equals('blob_name'));
      expect(restored.encryptedUsername, equals('blob_user'));
      expect(restored.encryptedPassword, equals('blob_pass'));
      expect(restored.deleted, isFalse);
    });

    test('TrustedDeviceRecord serialization and deserialization', () {
      final now = DateTime.now().toUtc();
      final device = TrustedDeviceRecord(
        deviceId: 'dev_12345',
        displayName: 'Akash Phone',
        platform: 'android',
        pairedAt: now,
        lastSyncedAt: now,
        revoked: false,
        wrappedVekBase64: 'wrapped-vek-secret',
      );

      final json = device.toJson();
      final restored = TrustedDeviceRecord.fromJson(json);

      expect(restored.deviceId, equals('dev_12345'));
      expect(restored.displayName, equals('Akash Phone'));
      expect(restored.platform, equals('android'));
      expect(restored.wrappedVekBase64, equals('wrapped-vek-secret'));
      expect(restored.revoked, isFalse);
    });

    test('RecoveryKitRecord serialization and deserialization', () {
      final now = DateTime.now().toUtc();
      final kit = RecoveryKitRecord(
        kitId: 'kit_1',
        createdAt: now,
        saltBase64: 'salt123',
        wrappedVekBase64: 'wrappedVek123',
        version: 1,
        superseded: false,
      );

      final json = kit.toJson();
      final restored = RecoveryKitRecord.fromJson(json);

      expect(restored.kitId, equals('kit_1'));
      expect(restored.saltBase64, equals('salt123'));
      expect(restored.wrappedVekBase64, equals('wrappedVek123'));
      expect(restored.version, equals(1));
      expect(restored.superseded, isFalse);
    });

    test('VaultSettingsRecord serialization and deserialization', () {
      final now = DateTime.now().toUtc();
      final settings = VaultSettingsRecord(
        recycleBinRetentionDays: 30,
        requireBiometricForReveal: true,
        selfDeviceId: 'dev_self_999',
        vaultCreatedAt: now,
      );

      final json = settings.toJson();
      final restored = VaultSettingsRecord.fromJson(json);

      expect(restored.recycleBinRetentionDays, equals(30));
      expect(restored.requireBiometricForReveal, isTrue);
      expect(restored.selfDeviceId, equals('dev_self_999'));
    });
  });

  group('Backup Restore Preservation Contract', () {
    test('RestoreMode.replace preserves current device identity and wrapped VEK', () {
      const currentSelfId = 'device_local_primary';
      final localDeviceRecord = TrustedDeviceRecord(
        deviceId: currentSelfId,
        displayName: 'My Local Android',
        platform: 'android',
        pairedAt: DateTime(2026, 1, 1),
        lastSyncedAt: DateTime(2026, 1, 1),
        revoked: false,
        wrappedVekBase64: 'CRITICAL_LOCAL_WRAPPED_VEK_DO_NOT_OVERWRITE',
      );

      // Simulated incoming backup from another device
      final incomingBackupJson = {
        'formatVersion': 1,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'entries': [
          {
            'uuid': 'entry-1',
            'encryptedWebsiteName': 'name',
            'encryptedWebsiteUrl': 'url',
            'encryptedUsername': 'user',
            'encryptedPassword': 'pass',
            'createdAt': DateTime(2026, 1, 1).toIso8601String(),
            'lastUpdated': DateTime(2026, 1, 1).toIso8601String(),
            'hash': 'hash1',
            'deleted': false,
          }
        ],
        'trustedDevices': [
          // Foreign device's version of the same ID (e.g. from an older or different clone)
          {
            'deviceId': currentSelfId,
            'displayName': 'Old or Foreign Copy',
            'platform': 'android',
            'pairedAt': DateTime(2025, 1, 1).toIso8601String(),
            'lastSyncedAt': DateTime(2025, 1, 1).toIso8601String(),
            'revoked': false,
            'wrappedVekBase64': 'FOREIGN_INCOMPATIBLE_WRAPPED_VEK',
          },
          // An external paired device
          {
            'deviceId': 'ext_chrome_pc',
            'displayName': 'Work Chrome',
            'platform': 'extension',
            'pairedAt': DateTime(2026, 2, 1).toIso8601String(),
            'lastSyncedAt': DateTime(2026, 2, 1).toIso8601String(),
            'revoked': false,
            'wrappedVekBase64': 'work_chrome_vek',
          }
        ],
        'recoveryKits': [],
      };

      // Simulate the exact logic in BackupService.importBackup (RestoreMode.replace)
      final incomingDevices = (incomingBackupJson['trustedDevices'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(TrustedDeviceRecord.fromJson)
          .toList();

      final restoredDevices = <TrustedDeviceRecord>[];

      for (final d in incomingDevices) {
        if (d.deviceId == currentSelfId) continue;
        restoredDevices.add(d);
      }
      restoredDevices.add(localDeviceRecord);

      // Verify outcomes:
      // 1. Exactly 2 devices in total
      expect(restoredDevices.length, equals(2));

      // 2. The local device record kept its own local wrappedVekBase64
      final selfRecord = restoredDevices.firstWhere((d) => d.deviceId == currentSelfId);
      expect(selfRecord.wrappedVekBase64, equals('CRITICAL_LOCAL_WRAPPED_VEK_DO_NOT_OVERWRITE'));
      expect(selfRecord.displayName, equals('My Local Android'));

      // 3. The other paired device was successfully imported
      final extRecord = restoredDevices.firstWhere((d) => d.deviceId == 'ext_chrome_pc');
      expect(extRecord.wrappedVekBase64, equals('work_chrome_vek'));
    });
  });
}
