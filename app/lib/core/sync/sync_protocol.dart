import 'dart:convert';

/// Lightweight metadata for one record, exchanged FIRST before any
/// encrypted payload crosses the wire. This is intentionally the only
/// thing both sides need to decide what to transfer.
class RecordMeta {
  final String uuid;
  final String hash;
  final DateTime lastUpdated;
  final bool deleted;

  RecordMeta({required this.uuid, required this.hash, required this.lastUpdated, required this.deleted});

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'hash': hash,
        'lastUpdated': lastUpdated.toIso8601String(),
        'deleted': deleted,
      };

  static RecordMeta fromJson(Map<String, dynamic> json) => RecordMeta(
        uuid: json['uuid'] as String,
        hash: json['hash'] as String,
        lastUpdated: DateTime.parse(json['lastUpdated'] as String),
        deleted: json['deleted'] as bool,
      );
}

/// A fully self-contained encrypted record as it appears on the wire —
/// identical shape to VaultEntryRecord, still fully ciphertext.
class WireRecord {
  final String uuid;
  final String encryptedWebsiteName;
  final String encryptedWebsiteUrl;
  final String encryptedUsername;
  final String encryptedPassword;
  final DateTime createdAt;
  final DateTime lastUpdated;
  final String hash;
  final bool deleted;

  WireRecord({
    required this.uuid,
    required this.encryptedWebsiteName,
    required this.encryptedWebsiteUrl,
    required this.encryptedUsername,
    required this.encryptedPassword,
    required this.createdAt,
    required this.lastUpdated,
    required this.hash,
    required this.deleted,
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
      };

  static WireRecord fromJson(Map<String, dynamic> json) => WireRecord(
        uuid: json['uuid'] as String,
        encryptedWebsiteName: json['encryptedWebsiteName'] as String,
        encryptedWebsiteUrl: json['encryptedWebsiteUrl'] as String,
        encryptedUsername: json['encryptedUsername'] as String,
        encryptedPassword: json['encryptedPassword'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        lastUpdated: DateTime.parse(json['lastUpdated'] as String),
        hash: json['hash'] as String,
        deleted: json['deleted'] as bool,
      );
}

/// Lightweight, non-secret metadata about one trusted device, exchanged
/// during sync so every paired device eventually learns about every other
/// paired device — this is what makes the "Trusted devices" list update
/// itself instead of only ever showing whichever devices happened to be
/// present (in person, scanning each other's QR) at pairing time.
///
/// Deliberately excludes `wrappedVekBase64`: that field is only ever
/// meaningful to the specific device it was wrapped for (it's encrypted
/// under that device's own local key, which no peer has), so there's
/// nothing useful to send and every byte saved matters on a slow LAN.
class DeviceInfo {
  final String deviceId;
  final String displayName;
  final String platform;
  final DateTime pairedAt;
  final DateTime lastSyncedAt;
  final bool revoked;

  DeviceInfo({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.pairedAt,
    required this.lastSyncedAt,
    required this.revoked,
  });

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'displayName': displayName,
        'platform': platform,
        'pairedAt': pairedAt.toIso8601String(),
        'lastSyncedAt': lastSyncedAt.toIso8601String(),
        'revoked': revoked,
      };

  static DeviceInfo fromJson(Map<String, dynamic> json) => DeviceInfo(
        deviceId: json['deviceId'] as String,
        displayName: json['displayName'] as String,
        platform: json['platform'] as String,
        pairedAt: DateTime.parse(json['pairedAt'] as String),
        lastSyncedAt: DateTime.parse(json['lastSyncedAt'] as String),
        revoked: json['revoked'] as bool,
      );
}

enum SyncMsgType { hello, helloResponse, deviceInfo, metadata, request, records, done, error, authRequest, authResponse, pairingRequest, pairingChallenge, pairingSuccess }

class SyncMessage {
  final SyncMsgType type;
  final Map<String, dynamic> payload;
  SyncMessage(this.type, this.payload);

  String encode() => jsonEncode({'type': type.name, 'payload': payload});

  static SyncMessage decode(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final typeStr = json['type'] as String? ?? '';
    final type = SyncMsgType.values.byName(typeStr);
    final payloadRaw = json['payload'];
    final payload = payloadRaw is Map<String, dynamic>
        ? payloadRaw
        : (payloadRaw is Map ? Map<String, dynamic>.from(payloadRaw) : <String, dynamic>{});
    return SyncMessage(type, payload);
  }
}

/// Pure function: given what I have and what the peer has, decide which
/// UUIDs I should ask the peer for, and which UUIDs I should push to them.
/// This is the entire "incremental sync" decision, isolated from any I/O.
class SyncDiff {
  final List<String> uuidsToRequestFromPeer;
  final List<String> uuidsToSendToPeer;
  SyncDiff({required this.uuidsToRequestFromPeer, required this.uuidsToSendToPeer});

  static SyncDiff compute({required List<RecordMeta> mine, required List<RecordMeta> theirs}) {
    final mineByUuid = {for (final m in mine) m.uuid: m};
    final theirsByUuid = {for (final t in theirs) t.uuid: t};

    final toRequest = <String>[];
    final toSend = <String>[];

    for (final theirEntry in theirs) {
      final mineEntry = mineByUuid[theirEntry.uuid];
      if (mineEntry == null) {
        toRequest.add(theirEntry.uuid); // they have something I don't
      } else if (mineEntry.hash != theirEntry.hash) {
        // Divergent — whoever has the newer lastUpdated wins. If theirs is
        // newer (or equal, tie-break arbitrary but deterministic), request
        // it; otherwise it'll be picked up in the "toSend" pass below.
        if (theirEntry.lastUpdated.isAfter(mineEntry.lastUpdated) ||
            (theirEntry.lastUpdated.isAtSameMomentAs(mineEntry.lastUpdated) && theirEntry.hash.compareTo(mineEntry.hash) > 0)) {
          toRequest.add(theirEntry.uuid);
        }
      }
    }

    for (final mineEntry in mine) {
      final theirEntry = theirsByUuid[mineEntry.uuid];
      if (theirEntry == null) {
        toSend.add(mineEntry.uuid); // I have something they don't
      } else if (mineEntry.hash != theirEntry.hash) {
        if (mineEntry.lastUpdated.isAfter(theirEntry.lastUpdated) ||
            (mineEntry.lastUpdated.isAtSameMomentAs(theirEntry.lastUpdated) && mineEntry.hash.compareTo(theirEntry.hash) > 0)) {
          toSend.add(mineEntry.uuid);
        }
      }
    }

    return SyncDiff(uuidsToRequestFromPeer: toRequest, uuidsToSendToPeer: toSend);
  }
}
