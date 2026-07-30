import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../crypto/crypto_engine.dart';
import '../devices/device_manager.dart';
import '../storage/vault_database.dart';
import '../vault/vault_session.dart';
import 'sync_protocol.dart';

/// Transport-agnostic abstraction for a sync connection. Each transport
/// (WebSocket, BLE GATT characteristic, Nearby Connections payload)
/// implements this interface so the handshake + sync logic is written once.
abstract class SyncTransport {
  void send(String jsonMessage);
  Future<void> close();
}

/// Per-connection handshake + message handler shared by ALL transports.
///
/// This was extracted from LanSyncService so that BLE GATT and Nearby
/// Connections can reuse the same VEK-based HMAC challenge, metadata diff,
/// record exchange, and auth approval logic without any duplication.
class SyncConnectionHandler {
  final SyncTransport transport;
  final SecretKey? vek;
  final Future<bool> Function(String actionLabel)? onAuthPromptRequested;
  final Future<bool> Function(String deviceName, String pin)? onPairingRequested;
  final void Function()? onRecordsUpdated;

  String? _sentNonceBase64;
  bool authenticated = false;
  bool awaitingRecordsReply = false;
  final Completer<bool> _authCompleter = Completer<bool>();

  VaultDatabase get _db => VaultDatabase.instance;

  SyncConnectionHandler({
    required this.transport,
    required this.vek,
    this.onAuthPromptRequested,
    this.onPairingRequested,
    this.onRecordsUpdated,
  });

  // ─────────────────────────────────────────────────────────
  //  Handshake
  // ─────────────────────────────────────────────────────────

  bool _challengeSent = false;

  Future<void> sendChallenge() async {
    if (_challengeSent) return;
    _challengeSent = true;
    final nonce = _randomBytes(16);
    _sentNonceBase64 = base64Encode(nonce);
    transport.send(SyncMessage(SyncMsgType.hello, {'nonce': _sentNonceBase64}).encode());
  }

  Future<void> respondToChallenge(String theirNonceBase64) async {
    final v = vek;
    if (v == null) return;
    final authKey = await CryptoEngine.instance.deriveSyncAuthKey(v);
    final mac = await CryptoEngine.instance.hmacSha256(authKey, theirNonceBase64);
    transport.send(SyncMessage(SyncMsgType.helloResponse, {'mac': base64Encode(mac)}).encode());
  }

  Future<void> receiveChallengeResponse(String macBase64) async {
    final v = vek;
    final sentNonce = _sentNonceBase64;
    if (v == null || sentNonce == null) {
      _fail();
      return;
    }
    final authKey = await CryptoEngine.instance.deriveSyncAuthKey(v);
    final expectedMac = await CryptoEngine.instance.hmacSha256(authKey, sentNonce);
    final actualMac = base64Decode(macBase64);
    final valid = expectedMac.length == actualMac.length && _constantTimeEquals(expectedMac, actualMac);
    authenticated = valid;
    if (!_authCompleter.isCompleted) _authCompleter.complete(valid);
    if (!valid) _fail();
  }

  void _fail() {
    if (!_authCompleter.isCompleted) _authCompleter.complete(false);
    transport.close();
  }

  Future<bool> waitForAuthentication() =>
      _authCompleter.future.timeout(const Duration(seconds: 6), onTimeout: () => false);

  // ─────────────────────────────────────────────────────────
  //  Message handling (shared across all transports)
  // ─────────────────────────────────────────────────────────

  void sendDeviceInfo() {
    final deviceManager = DeviceManager.instance;
    final self = deviceManager.selfDeviceInfo();
    if (self == null) return;
    final all = [self, ...deviceManager.knownPeerDeviceInfos()];
    transport.send(SyncMessage(SyncMsgType.deviceInfo, {'devices': all.map((d) => d.toJson()).toList()}).encode());
  }

  Future<void> handleMessage(SyncMessage message) async {
    // Handshake messages are processed before authentication
    if (message.type == SyncMsgType.hello) {
      final nonce = message.payload['nonce'] as String?;
      if (nonce != null) {
        await respondToChallenge(nonce);
      }
      return;
    }
    if (message.type == SyncMsgType.helloResponse) {
      final mac = message.payload['mac'] as String?;
      if (mac != null) {
        await receiveChallengeResponse(mac);
      }
      return;
    }
    if (message.type == SyncMsgType.pairingRequest) {
      await _handlePairingRequest(message);
      return;
    }
    // Everything else requires authentication
    if (!authenticated) return;

    switch (message.type) {
      case SyncMsgType.metadata:
        await DeviceManager.instance.touchSelfLastSynced();
        final rawEntries = message.payload['entries'] as List?;
        if (rawEntries == null) break;
        final theirs = rawEntries
            .map((e) => RecordMeta.fromJson(e as Map<String, dynamic>))
            .toList();
        final mine = localMetadata();
        final diff = SyncDiff.compute(mine: mine, theirs: theirs);

        if (diff.uuidsToSendToPeer.isNotEmpty) {
          final records = _wireRecordsFor(diff.uuidsToSendToPeer);
          transport.send(SyncMessage(SyncMsgType.records, {'entries': records.map((r) => r.toJson()).toList()}).encode());
        }
        if (diff.uuidsToRequestFromPeer.isNotEmpty) {
          awaitingRecordsReply = true;
          transport.send(SyncMessage(SyncMsgType.request, {'uuids': diff.uuidsToRequestFromPeer}).encode());
        } else {
          transport.send(SyncMessage(SyncMsgType.done, {}).encode());
          await transport.close();
        }
        break;

      case SyncMsgType.request:
        final rawUuids = message.payload['uuids'] as List?;
        if (rawUuids == null) break;
        final uuids = rawUuids.cast<String>();
        final records = _wireRecordsFor(uuids);
        transport.send(SyncMessage(SyncMsgType.records, {'entries': records.map((r) => r.toJson()).toList()}).encode());
        break;

      case SyncMsgType.records:
        final rawEntries = message.payload['entries'] as List?;
        if (rawEntries == null) break;
        final entries = rawEntries.map((e) => WireRecord.fromJson(e as Map<String, dynamic>));
        await _applyIncomingRecords(entries.toList());
        if (awaitingRecordsReply) {
          awaitingRecordsReply = false;
          transport.send(SyncMessage(SyncMsgType.done, {}).encode());
          await transport.close();
        }
        break;

      case SyncMsgType.deviceInfo:
        final rawDevices = message.payload['devices'] as List?;
        if (rawDevices == null) break;
        final infos = rawDevices
            .map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>))
            .toList();
        await DeviceManager.instance.mergeIncomingDeviceInfos(infos);
        break;

      case SyncMsgType.authRequest:
        final requestId = message.payload['requestId'] as String?;
        if (requestId == null) break;
        final actionLabel = message.payload['actionLabel'] as String? ?? 'access a saved password';
        bool approved;
        try {
          final handler = onAuthPromptRequested;
          approved = handler == null ? false : await handler(actionLabel);
        } catch (_) {
          approved = false;
        }
        transport.send(SyncMessage(SyncMsgType.authResponse, {'requestId': requestId, 'approved': approved}).encode());
        break;

      case SyncMsgType.done:
        await transport.close();
        break;

      case SyncMsgType.hello:
      case SyncMsgType.helloResponse:
      case SyncMsgType.pairingRequest:
      case SyncMsgType.pairingChallenge:
      case SyncMsgType.pairingSuccess:
      case SyncMsgType.error:
      case SyncMsgType.authResponse:
        break;
    }
  }

  // ─────────────────────────────────────────────────────────
  //  Pairing
  // ─────────────────────────────────────────────────────────

  Future<void> _handlePairingRequest(SyncMessage msg) async {
    try {
      final deviceName = msg.payload['deviceName'] as String? ?? 'Unknown Device';
      final peerKeyB64 = msg.payload['pubKey'] as String?;
      if (peerKeyB64 == null) {
        transport.send(SyncMessage(SyncMsgType.error, {'message': 'Missing pubKey in pairing request.'}).encode());
        await transport.close();
        return;
      }

      final engine = CryptoEngine.instance;
      final peerKey = engine.importEcdhPublicKey(peerKeyB64);
      final myKeyPair = await engine.generateEcdhKeyPair();
      final myPubKey = await myKeyPair.extractPublicKey();
      final myKeyB64 = engine.exportEcdhPublicKey(myPubKey);

      transport.send(SyncMessage(SyncMsgType.pairingChallenge, {'pubKey': myKeyB64}).encode());

      final sharedSecret = await engine.deriveEcdhSharedSecret(myKeyPair, peerKey);
      final pin = await engine.computeEcdhPin(sharedSecret);

      final handler = onPairingRequested;
      final approved = handler == null ? false : await handler(deviceName, pin);

      if (approved) {
        final deviceId = msg.payload['deviceId'] as String?;
        final clientName = msg.payload['clientName'] as String?;
        final platform = msg.payload['platform'] as String?;

        if (deviceId != null) {
          await DeviceManager.instance.mergeIncomingDeviceInfos([
            DeviceInfo(
              deviceId: deviceId,
              displayName: clientName ?? deviceName,
              platform: platform ?? "chrome",
              pairedAt: DateTime.now().toUtc(),
              lastSyncedAt: DateTime.now().toUtc(),
              revoked: false,
            )
          ]);
        }

        final wrappingKey = await engine.deriveEcdhWrappingKey(sharedSecret);
        final wrappedVek = await engine.wrapKey(keyToWrap: VaultSession.instance.vek, wrappingKey: wrappingKey);
        final selfInfo = DeviceManager.instance.selfDeviceInfo();
        transport.send(SyncMessage(SyncMsgType.pairingSuccess, {
          'wrappedVek': wrappedVek.toBase64(),
          'device': selfInfo?.toJson() ?? {},
        }).encode());
      } else {
        transport.send(SyncMessage(SyncMsgType.error, {'message': 'Pairing rejected on phone.'}).encode());
      }
    } catch (e) {
      transport.send(SyncMessage(SyncMsgType.error, {'message': 'Pairing failed: $e'}).encode());
    }
    await transport.close();
  }

  // ─────────────────────────────────────────────────────────
  //  Helpers
  // ─────────────────────────────────────────────────────────

  List<RecordMeta> localMetadata() {
    return _db.allEntries
        .map((r) => RecordMeta(uuid: r.uuid, hash: r.hash, lastUpdated: r.lastUpdated, deleted: r.deleted))
        .toList();
  }

  List<WireRecord> _wireRecordsFor(List<String> uuids) {
    final records = _db.allEntries.where((r) => uuids.contains(r.uuid));
    return records
        .map((r) => WireRecord(
              uuid: r.uuid,
              encryptedWebsiteName: r.encryptedWebsiteName,
              encryptedWebsiteUrl: r.encryptedWebsiteUrl,
              encryptedUsername: r.encryptedUsername,
              encryptedPassword: r.encryptedPassword,
              createdAt: r.createdAt,
              lastUpdated: r.lastUpdated,
              hash: r.hash,
              deleted: r.deleted,
            ))
        .toList();
  }

  Future<void> _applyIncomingRecords(List<WireRecord> incoming) async {
    bool changed = false;
    for (final wire in incoming) {
      final existing = _db.findEntryByUuid(wire.uuid);
      if (existing == null || wire.lastUpdated.isAfter(existing.lastUpdated)) {
        final record = VaultEntryRecord(
          uuid: wire.uuid,
          encryptedWebsiteName: wire.encryptedWebsiteName,
          encryptedWebsiteUrl: wire.encryptedWebsiteUrl,
          encryptedUsername: wire.encryptedUsername,
          encryptedPassword: wire.encryptedPassword,
          createdAt: wire.createdAt,
          lastUpdated: wire.lastUpdated,
          hash: wire.hash,
          deleted: wire.deleted,
          deletedAt: wire.deleted ? wire.lastUpdated : null,
        );
        await _db.upsertEntry(record);
        changed = true;
      }
    }
    if (changed) onRecordsUpdated?.call();
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    final bytes = List<int>.generate(length, (_) => random.nextInt(256));
    return bytes;
  }
}
