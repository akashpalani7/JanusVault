/// Metadata about the currently active Recovery Kit. The actual recovery
/// SECRET is never stored anywhere by the app — it exists only at the
/// moment it's generated (shown once to the user to write down / export)
/// and again at the moment the user types it back in to recover the vault.
class RecoveryKitMeta {
  final String kitId;
  final DateTime createdAt;
  final String saltBase64;
  final String wrappedVekBase64; // VEK wrapped under Argon2id(recoverySecret, salt)
  final int version;

  const RecoveryKitMeta({
    required this.kitId,
    required this.createdAt,
    required this.saltBase64,
    required this.wrappedVekBase64,
    this.version = 1,
  });
}
