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

/// The exportable, non-secret half of a Recovery Kit — safe to save as a
/// QR code, print, email to yourself, or store in cloud storage, because
/// it's useless without the recovery SECRET (never included here).
///
/// This is what makes recovery actually work in the scenario it exists
/// for: every trusted device is gone. Without this, the salt + wrapped
/// VEK needed to unwrap anything only ever lived in this device's own
/// local database — meaning a brand-new device with an empty database
/// (exactly what you're recovering ONTO) could never look them up, no
/// matter how correct the recovery secret was. Now both halves — this
/// package and the secret — travel with the user independently, and
/// either one alone reveals nothing.
class RecoveryKitPackage {
  final String kitId;
  final String saltBase64;
  final String wrappedVekBase64;

  const RecoveryKitPackage({required this.kitId, required this.saltBase64, required this.wrappedVekBase64});

  /// "janusvault-recovery:v1:<kitId>:<salt>:<wrappedVek>" — same style as
  /// PairingPackage.encode(), suitable for a QR code or manual export.
  String encode() => 'janusvault-recovery:v1:$kitId:$saltBase64:$wrappedVekBase64';

  static RecoveryKitPackage decode(String raw) {
    final parts = raw.trim().split(':');
    if (parts.length != 5 || parts[0] != 'janusvault-recovery' || parts[1] != 'v1') {
      throw const FormatException('Not a valid JanusVault Recovery Kit package');
    }
    return RecoveryKitPackage(kitId: parts[2], saltBase64: parts[3], wrappedVekBase64: parts[4]);
  }

  static RecoveryKitPackage fromMeta(RecoveryKitMeta meta) =>
      RecoveryKitPackage(kitId: meta.kitId, saltBase64: meta.saltBase64, wrappedVekBase64: meta.wrappedVekBase64);
}
