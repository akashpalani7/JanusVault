/// In-memory, DECRYPTED representation of a vault entry. This object must
/// never be written to disk, logged, or cached — it only exists transiently
/// while the vault is unlocked. Storage always uses [VaultEntryRecord]
/// (see core/storage/vault_database.dart) which holds only encrypted fields.
///
/// Plain hand-written class (no freezed) — see pubspec.yaml note on why
/// this project has no code generation.
class VaultEntry {
  final String uuid;
  final String websiteName;
  final String websiteUrl;
  final String username;
  final String password;
  final DateTime createdAt;
  final DateTime lastUpdated;
  final bool deleted;

  const VaultEntry({
    required this.uuid,
    required this.websiteName,
    required this.websiteUrl,
    required this.username,
    required this.password,
    required this.createdAt,
    required this.lastUpdated,
    this.deleted = false,
  });

  VaultEntry copyWith({
    String? websiteName,
    String? websiteUrl,
    String? username,
    String? password,
    DateTime? lastUpdated,
    bool? deleted,
  }) {
    return VaultEntry(
      uuid: uuid,
      websiteName: websiteName ?? this.websiteName,
      websiteUrl: websiteUrl ?? this.websiteUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      createdAt: createdAt,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      deleted: deleted ?? this.deleted,
    );
  }
}
