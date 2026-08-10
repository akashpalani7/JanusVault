import 'package:uuid/uuid.dart';

import '../crypto/crypto_engine.dart';
import '../models/vault_entry.dart';
import '../storage/vault_database.dart';
import 'vault_session.dart';

class VaultRepository {
  VaultRepository._();
  static final VaultRepository instance = VaultRepository._();

  final Uuid _uuid = const Uuid();

  VaultDatabase get _db => VaultDatabase.instance;

  /// Decrypts and returns every non-deleted entry. Requires the vault to be
  /// unlocked (VaultSession.instance.isUnlocked).
  Future<List<VaultEntry>> getAllEntries({bool includeDeleted = false}) async {
    final records = includeDeleted ? _db.allEntries : _db.allEntries.where((r) => !r.deleted);
    final results = <VaultEntry>[];
    for (final record in records) {
      results.add(await _decryptRecord(record));
    }
    return results;
  }

  Future<List<VaultEntry>> searchByWebsite(String query) async {
    // Search happens client-side on decrypted data because website names are
    // encrypted at rest — there is no way to do an encrypted-field LIKE query
    // without leaking a searchable index (which we deliberately avoid).
    final all = await getAllEntries();
    final lower = query.toLowerCase();
    return all.where((e) => e.websiteName.toLowerCase().contains(lower) || e.websiteUrl.toLowerCase().contains(lower)).toList();
  }

  Future<VaultEntry> createEntry({
    required String websiteName,
    required String websiteUrl,
    required String username,
    required String password,
  }) async {
    final now = DateTime.now().toUtc();
    final entry = VaultEntry(
      uuid: _uuid.v4(),
      websiteName: websiteName,
      websiteUrl: websiteUrl,
      username: username,
      password: password,
      createdAt: now,
      lastUpdated: now,
      deleted: false,
    );
    await _persist(entry);
    return entry;
  }

  Future<VaultEntry> updateEntry(VaultEntry existing, {
    String? websiteName,
    String? websiteUrl,
    String? username,
    String? password,
  }) async {
    final updated = existing.copyWith(
      websiteName: websiteName ?? existing.websiteName,
      websiteUrl: websiteUrl ?? existing.websiteUrl,
      username: username ?? existing.username,
      password: password ?? existing.password,
      lastUpdated: DateTime.now().toUtc(),
    );
    await _persist(updated);
    return updated;
  }

  /// Soft-delete: flips the recycle-bin flag rather than removing the row,
  /// so the tombstone can propagate to every synced device.
  Future<void> softDeleteEntry(String uuid) async {
    final record = _db.findEntryByUuid(uuid);
    if (record == null) return;
    record.deleted = true;
    record.deletedAt = DateTime.now().toUtc();
    record.lastUpdated = record.deletedAt!;
    record.hash = await CryptoEngine.instance.computeRecordHash(
      uuid: record.uuid,
      encryptedPasswordBase64: record.encryptedPassword,
      encryptedWebsiteNameBase64: record.encryptedWebsiteName,
      encryptedUsernameBase64: record.encryptedUsername,
      lastUpdated: record.lastUpdated,
      deleted: true,
    );
    await _db.upsertEntry(record);
  }

  Future<void> restoreEntry(String uuid) async {
    final record = _db.findEntryByUuid(uuid);
    if (record == null) return;
    record.deleted = false;
    record.deletedAt = null;
    record.lastUpdated = DateTime.now().toUtc();
    record.hash = await CryptoEngine.instance.computeRecordHash(
      uuid: record.uuid,
      encryptedPasswordBase64: record.encryptedPassword,
      encryptedWebsiteNameBase64: record.encryptedWebsiteName,
      encryptedUsernameBase64: record.encryptedUsername,
      lastUpdated: record.lastUpdated,
      deleted: false,
    );
    await _db.upsertEntry(record);
  }

  /// Permanently removes entries that have been in the recycle bin longer
  /// than [retentionDays]. Should be run periodically (e.g. on app start
  /// and via a background task).
  Future<int> purgeExpiredRecycleBin({required int retentionDays}) async {
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: retentionDays));
    return _db.deleteEntriesWhere((r) => r.deleted && r.deletedAt != null && r.deletedAt!.isBefore(cutoff));
  }

  Future<void> hardDeleteEntry(String uuid) async {
    await _db.deleteEntriesWhere((r) => r.uuid == uuid);
  }

  // ---------------------------------------------------------------------
  // internal helpers
  // ---------------------------------------------------------------------

  Future<void> _persist(VaultEntry entry) async {
    final vek = VaultSession.instance.vek;
    final engine = CryptoEngine.instance;

    final encWebsiteName = await engine.encryptString(plainText: entry.websiteName, vek: vek);
    final encWebsiteUrl = await engine.encryptString(plainText: entry.websiteUrl, vek: vek);
    final encUsername = await engine.encryptString(plainText: entry.username, vek: vek);
    final encPassword = await engine.encryptString(plainText: entry.password, vek: vek);

    final hash = await engine.computeRecordHash(
      uuid: entry.uuid,
      encryptedPasswordBase64: encPassword,
      encryptedWebsiteNameBase64: encWebsiteName,
      encryptedUsernameBase64: encUsername,
      lastUpdated: entry.lastUpdated,
      deleted: entry.deleted,
    );

    final record = VaultEntryRecord(
      uuid: entry.uuid,
      encryptedWebsiteName: encWebsiteName,
      encryptedWebsiteUrl: encWebsiteUrl,
      encryptedUsername: encUsername,
      encryptedPassword: encPassword,
      createdAt: entry.createdAt,
      lastUpdated: entry.lastUpdated,
      hash: hash,
      deleted: entry.deleted,
    );

    await _db.upsertEntry(record);
  }

  Future<VaultEntry> _decryptRecord(VaultEntryRecord record) async {
    final vek = VaultSession.instance.vek;
    final engine = CryptoEngine.instance;
    return VaultEntry(
      uuid: record.uuid,
      websiteName: await engine.decryptString(encoded: record.encryptedWebsiteName, vek: vek),
      websiteUrl: await engine.decryptString(encoded: record.encryptedWebsiteUrl, vek: vek),
      username: await engine.decryptString(encoded: record.encryptedUsername, vek: vek),
      password: await engine.decryptString(encoded: record.encryptedPassword, vek: vek),
      createdAt: record.createdAt,
      lastUpdated: record.lastUpdated,
      deleted: record.deleted,
    );
  }
}
