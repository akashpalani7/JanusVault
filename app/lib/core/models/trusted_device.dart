enum DevicePlatform { androidApp, iosApp, windowsApp, macosApp, linuxApp, browserExtension }

class TrustedDevice {
  final String deviceId;
  final String displayName;
  final DevicePlatform platform;
  final DateTime pairedAt;
  final DateTime lastSyncedAt;
  final bool revoked;

  const TrustedDevice({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.pairedAt,
    required this.lastSyncedAt,
    this.revoked = false,
  });
}
