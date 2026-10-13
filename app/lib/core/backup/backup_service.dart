import 'dart:convert';
import 'dart:io';

import '../storage/vault_database.dart';

enum RestoreMode { replace, merge }

/// .pvault file format (JSON):
/// {
///   "formatVersion": 1,
///   "exportedAt": "...",
///   "entries": [ ...VaultEntryRecord.toJson()... ],
///   "trustedDevices": [ ...TrustedDeviceRecord.toJson()... ],
///   "recoveryKits": [ ...RecoveryKitRecord.toJson()... ],
///   "settings": VaultSettingsRecord.toJson() | null
/// }
///
/// IMPORTANT: every field above is already ciphertext or non-secret
/// metadata — a .pvault file leaking does not expose plaintext passwords.
/// However, `wrappedVekBase64` for trusted devices is only unwrappable BY
/// that specific physical device's local key; restoring a backup onto a
/// different device only makes vault ENTRIES usable once that device
/// separately obtains the VEK (via pairing or Recovery Kit).
class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  VaultDatabase get _db => VaultDatabase.instance;

  String _buildBackupJson() {
    final json = {
      'formatVersion': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'entries': _db.allEntries.map((e) => e.toJson()).toList(),
      'trustedDevices': _db.allDevices.map((d) => d.toJson()).toList(),
      'recoveryKits': _db.allKits.map((k) => k.toJson()).toList(),
      'settings': _db.settings?.toJson(),
    };
    return jsonEncode(json);
  }

  /// Returns the backup as raw bytes, for callers that want to hand it to
  /// a native "save to..." picker (e.g. `file_picker`'s `saveFile`) rather
  /// than writing directly to a path this app already has access to.
  /// This is the preferred path on Android: `getApplicationDocumentsDirectory()`
  /// is app-private internal storage that's difficult to reach from a file
  /// manager on modern Android — letting the OS picker choose the
  /// destination puts the file somewhere the user can actually find it
  /// (Downloads, Documents, Drive, etc.) and needs no storage permission.
  List<int> exportBackupBytes() => utf8.encode(_buildBackupJson());

  Future<File> exportBackup(String outputPath) async {
    final file = File(outputPath);
    await file.writeAsString(_buildBackupJson());
    return file;
  }

  Future<void> importBackup(String inputPath, {required RestoreMode mode}) async {
    final file = File(inputPath);
    final raw = await file.readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;

    final incomingEntries = (json['entries'] as List<dynamic>).cast<Map<String, dynamic>>().map(VaultEntryRecord.fromJson).toList();
    final incomingDevices =
        (json['trustedDevices'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>().map(TrustedDeviceRecord.fromJson).toList();
    final incomingKits =
        (json['recoveryKits'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>().map(RecoveryKitRecord.fromJson).toList();

    if (mode == RestoreMode.replace) {
      final selfId = _db.settings?.selfDeviceId;
      final currentSelfRecord = selfId != null ? _db.findDeviceById(selfId) : null;

      await _db.clearEntries();
      await _db.clearDevices();
      await _db.clearKits();

      for (final e in incomingEntries) {
        await _db.upsertEntry(e);
      }
      for (final d in incomingDevices) {
        if (selfId != null && d.deviceId == selfId) continue;
        await _db.upsertDevice(d);
      }
      if (currentSelfRecord != null) {
        await _db.upsertDevice(currentSelfRecord);
      }
      for (final k in incomingKits) {
        await _db.upsertKit(k);
      }
      return;
    }

    // Merge mode: UUID + lastUpdated decide the winner, never creating
    // duplicates and never regressing a newer local record to an older one.
    for (final incoming in incomingEntries) {
      final existing = _db.findEntryByUuid(incoming.uuid);
      if (existing == null || incoming.lastUpdated.isAfter(existing.lastUpdated)) {
        await _db.upsertEntry(incoming);
      }
      // else: local copy is newer or equal — keep local, discard incoming.
    }
    for (final incoming in incomingDevices) {
      if (_db.findDeviceById(incoming.deviceId) == null) {
        await _db.upsertDevice(incoming);
      }
    }
  }
}
