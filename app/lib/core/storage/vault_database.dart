import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// On-disk representation of a vault entry. Every sensitive field is
/// already ciphertext (base64 EncryptedBlob) by the time it reaches this
/// class — the JSON file on disk never sees plaintext.
class VaultEntryRecord {
  String uuid;
  String encryptedWebsiteName;
  String encryptedWebsiteUrl;
  String encryptedUsername;
  String encryptedPassword;
  DateTime createdAt;
  DateTime lastUpdated;
  String hash;
  bool deleted;
  DateTime? deletedAt;

  VaultEntryRecord({
    required this.uuid,
    required this.encryptedWebsiteName,
    required this.encryptedWebsiteUrl,
    required this.encryptedUsername,
    required this.encryptedPassword,
    required this.createdAt,
    required this.lastUpdated,
    required this.hash,
    required this.deleted,
    this.deletedAt,
  });

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'encryptedWebsiteName': encryptedWebsiteName,
        'encryptedWebsiteUrl': encryptedWebsiteUrl,
        'encryptedUsername': encryptedUsername,
        'encryptedPassword': encryptedPassword,
        'createdAt': createdAt.toIso8601String(),
        'lastUpdated': lastUpdated.toIso8601String(),
        'hash': hash,
        'deleted': deleted,
        'deletedAt': deletedAt?.toIso8601String(),
      };

  static VaultEntryRecord fromJson(Map<String, dynamic> json) => VaultEntryRecord(
        uuid: json['uuid'] as String,
        encryptedWebsiteName: json['encryptedWebsiteName'] as String,
        encryptedWebsiteUrl: json['encryptedWebsiteUrl'] as String,
        encryptedUsername: json['encryptedUsername'] as String,
        encryptedPassword: json['encryptedPassword'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        lastUpdated: DateTime.parse(json['lastUpdated'] as String),
        hash: json['hash'] as String,
        deleted: json['deleted'] as bool,
        deletedAt: json['deletedAt'] == null ? null : DateTime.parse(json['deletedAt'] as String),
      );
}

class TrustedDeviceRecord {
  String deviceId;
  String displayName;
  String platform; // DevicePlatform.name
  DateTime pairedAt;
  DateTime lastSyncedAt;
  bool revoked;
  String wrappedVekBase64;

  TrustedDeviceRecord({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.pairedAt,
    required this.lastSyncedAt,
    required this.revoked,
    required this.wrappedVekBase64,
  });

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'displayName': displayName,
        'platform': platform,
        'pairedAt': pairedAt.toIso8601String(),
        'lastSyncedAt': lastSyncedAt.toIso8601String(),
        'revoked': revoked,
        'wrappedVekBase64': wrappedVekBase64,
      };

  static TrustedDeviceRecord fromJson(Map<String, dynamic> json) => TrustedDeviceRecord(
        deviceId: json['deviceId'] as String,
        displayName: json['displayName'] as String,
        platform: json['platform'] as String,
        pairedAt: DateTime.parse(json['pairedAt'] as String),
        lastSyncedAt: DateTime.parse(json['lastSyncedAt'] as String),
        revoked: json['revoked'] as bool,
        wrappedVekBase64: json['wrappedVekBase64'] as String,
      );
}

class RecoveryKitRecord {
  String kitId;
  DateTime createdAt;
  String saltBase64;
  String wrappedVekBase64;
  int version;
  bool superseded;

  RecoveryKitRecord({
    required this.kitId,
    required this.createdAt,
    required this.saltBase64,
    required this.wrappedVekBase64,
    required this.version,
    required this.superseded,
  });

  Map<String, dynamic> toJson() => {
        'kitId': kitId,
        'createdAt': createdAt.toIso8601String(),
        'saltBase64': saltBase64,
        'wrappedVekBase64': wrappedVekBase64,
        'version': version,
        'superseded': superseded,
      };

  static RecoveryKitRecord fromJson(Map<String, dynamic> json) => RecoveryKitRecord(
        kitId: json['kitId'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        saltBase64: json['saltBase64'] as String,
        wrappedVekBase64: json['wrappedVekBase64'] as String,
        version: json['version'] as int,
        superseded: json['superseded'] as bool,
      );
}

class VaultSettingsRecord {
  int recycleBinRetentionDays;
  bool requireBiometricForReveal;
  String selfDeviceId;
  DateTime vaultCreatedAt;

  VaultSettingsRecord({
    required this.recycleBinRetentionDays,
    required this.requireBiometricForReveal,
    required this.selfDeviceId,
    required this.vaultCreatedAt,
  });

  Map<String, dynamic> toJson() => {
        'recycleBinRetentionDays': recycleBinRetentionDays,
        'requireBiometricForReveal': requireBiometricForReveal,
        'selfDeviceId': selfDeviceId,
        'vaultCreatedAt': vaultCreatedAt.toIso8601String(),
      };

  static VaultSettingsRecord fromJson(Map<String, dynamic> json) => VaultSettingsRecord(
        recycleBinRetentionDays: json['recycleBinRetentionDays'] as int,
        requireBiometricForReveal: json['requireBiometricForReveal'] as bool,
        selfDeviceId: json['selfDeviceId'] as String,
        vaultCreatedAt: DateTime.parse(json['vaultCreatedAt'] as String),
      );
}

/// A single JSON-file-backed store holding all four "tables" in memory,
/// with write-through persistence on every mutation. Writes are serialized
/// through [_writeQueue] so concurrent calls never interleave and corrupt
/// the file. This intentionally replaces Isar (see pubspec.yaml) — for the
/// data volumes a personal password manager deals with (hundreds to low
/// thousands of entries), a flat JSON file loaded once into memory is both
/// simpler and completely dependency-free.
class VaultDatabase {
  VaultDatabase._();
  static final VaultDatabase instance = VaultDatabase._();

  final List<VaultEntryRecord> _entries = [];
  final List<TrustedDeviceRecord> _devices = [];
  final List<RecoveryKitRecord> _kits = [];
  VaultSettingsRecord? _settings;

  bool _loaded = false;
  Future<void> _writeQueue = Future.value();

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/peervault_db.json');
  }

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    _loaded = true;
    final file = await _file();
    if (!await file.exists()) return;

    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return;
    final json = jsonDecode(raw) as Map<String, dynamic>;

    _entries
      ..clear()
      ..addAll((json['entries'] as List<dynamic>? ?? []).map((e) => VaultEntryRecord.fromJson(e as Map<String, dynamic>)));
    _devices
      ..clear()
      ..addAll((json['devices'] as List<dynamic>? ?? []).map((e) => TrustedDeviceRecord.fromJson(e as Map<String, dynamic>)));
    _kits
      ..clear()
      ..addAll((json['kits'] as List<dynamic>? ?? []).map((e) => RecoveryKitRecord.fromJson(e as Map<String, dynamic>)));
    _settings = json['settings'] == null ? null : VaultSettingsRecord.fromJson(json['settings'] as Map<String, dynamic>);
  }

  /// Persists the current in-memory state to disk. Calls are chained onto
  /// [_writeQueue] so overlapping saves can't race and corrupt the file.
  Future<void> _persist() {
    _writeQueue = _writeQueue.then((_) async {
      final file = await _file();
      final json = {
        'entries': _entries.map((e) => e.toJson()).toList(),
        'devices': _devices.map((e) => e.toJson()).toList(),
        'kits': _kits.map((e) => e.toJson()).toList(),
        'settings': _settings?.toJson(),
      };
      // Write to a temp file then rename, so a crash mid-write never
      // leaves a truncated/corrupt database file behind.
      final tempFile = File('${file.path}.tmp');
      await tempFile.writeAsString(jsonEncode(json), flush: true);
      await tempFile.rename(file.path);
    });
    return _writeQueue;
  }

  // ---------------------------------------------------------------------
  // Vault entries
  // ---------------------------------------------------------------------

  List<VaultEntryRecord> get allEntries => List.unmodifiable(_entries);

  VaultEntryRecord? findEntryByUuid(String uuid) {
    for (final e in _entries) {
      if (e.uuid == uuid) return e;
    }
    return null;
  }

  Future<void> upsertEntry(VaultEntryRecord record) async {
    final index = _entries.indexWhere((e) => e.uuid == record.uuid);
    if (index == -1) {
      _entries.add(record);
    } else {
      _entries[index] = record;
    }
    await _persist();
  }

  Future<int> deleteEntriesWhere(bool Function(VaultEntryRecord) test) async {
    final before = _entries.length;
    _entries.removeWhere(test);
    final removed = before - _entries.length;
    if (removed > 0) await _persist();
    return removed;
  }

  Future<void> clearEntries() async {
    _entries.clear();
    await _persist();
  }

  // ---------------------------------------------------------------------
  // Trusted devices
  // ---------------------------------------------------------------------

  List<TrustedDeviceRecord> get allDevices => List.unmodifiable(_devices);

  TrustedDeviceRecord? findDeviceById(String deviceId) {
    for (final d in _devices) {
      if (d.deviceId == deviceId) return d;
    }
    return null;
  }

  Future<void> upsertDevice(TrustedDeviceRecord record) async {
    final index = _devices.indexWhere((d) => d.deviceId == record.deviceId);
    if (index == -1) {
      _devices.add(record);
    } else {
      _devices[index] = record;
    }
    await _persist();
  }

  Future<void> clearDevices() async {
    _devices.clear();
    await _persist();
  }

  // ---------------------------------------------------------------------
  // Recovery kits
  // ---------------------------------------------------------------------

  List<RecoveryKitRecord> get allKits => List.unmodifiable(_kits);

  RecoveryKitRecord? get activeKit {
    for (final k in _kits) {
      if (!k.superseded) return k;
    }
    return null;
  }

  Future<void> upsertKit(RecoveryKitRecord record) async {
    final index = _kits.indexWhere((k) => k.kitId == record.kitId);
    if (index == -1) {
      _kits.add(record);
    } else {
      _kits[index] = record;
    }
    await _persist();
  }

  Future<void> supersedeAllKits() async {
    for (final k in _kits) {
      k.superseded = true;
    }
    await _persist();
  }

  Future<void> clearKits() async {
    _kits.clear();
    await _persist();
  }

  // ---------------------------------------------------------------------
  // Settings (single row)
  // ---------------------------------------------------------------------

  VaultSettingsRecord? get settings => _settings;

  Future<void> saveSettings(VaultSettingsRecord record) async {
    _settings = record;
    await _persist();
  }
}
