import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bonsoir/bonsoir.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../crypto/crypto_engine.dart';
import '../devices/device_manager.dart';
import '../storage/secure_key_store.dart';
import '../storage/vault_database.dart';
import '../vault/vault_repository.dart';
import '../vault/vault_session.dart';
import 'sync_protocol.dart';

const String kServiceType = '_janusvault._tcp';

/// Per-connection handshake state. Anyone can open the raw socket — that's
/// unavoidable on a shared LAN — but nothing beyond `hello`/`helloResponse`
/// is ever processed until BOTH directions of this challenge/response
/// succeed, proving the other party holds a key derived from the VEK
/// itself. A stranger on the WiFi cannot produce a valid response and gets
/// disconnected before seeing a device list, vault metadata, or triggering
/// an approval prompt on the phone. See CryptoEngine.deriveSyncAuthKey.
class _SyncConnection {
  final WebSocket socket;
  final SecretKey? _vek; // null only if this device's own vault is locked
  String? _sentNonceBase64;
  bool authenticated = false;
  bool awaitingRecordsReply = false; // true after we've asked the peer for records via `request`
  final Completer<bool> _authCompleter = Completer<bool>();

  _SyncConnection(this.socket, this._vek);

  Future<void> sendChallenge() async {
    final nonce = Uint8List(16);
    final random = Random.secure();
    for (var i = 0; i < nonce.length; i++) {
      nonce[i] = random.nextInt(256);
    }
    _sentNonceBase64 = base64Encode(nonce);
    socket.add(SyncMessage(SyncMsgType.hello, {'nonce': _sentNonceBase64}).encode());
  }

  Future<void> respondToChallenge(String theirNonceBase64) async {
    final vek = _vek;
    if (vek == null) return; // can't answer without the key; their handshake will simply time out
    final authKey = await CryptoEngine.instance.deriveSyncAuthKey(vek);
    final mac = await CryptoEngine.instance.hmacSha256(authKey, theirNonceBase64);
    socket.add(SyncMessage(SyncMsgType.helloResponse, {'mac': base64Encode(mac)}).encode());
  }

  Future<void> receiveChallengeResponse(String macBase64) async {
    final vek = _vek;
    final sentNonce = _sentNonceBase64;
    print('SyncConnection: Received challenge response. Checking MAC...');
    if (vek == null || sentNonce == null) {
      print('SyncConnection: Vault is locked or nonce was null, aborting handshake');
      _fail();
      return;
    }
    final authKey = await CryptoEngine.instance.deriveSyncAuthKey(vek);
    final expectedMac = await CryptoEngine.instance.hmacSha256(authKey, sentNonce);
    final actualMac = base64Decode(macBase64);
    var valid = expectedMac.length == actualMac.length &&
        _constantTimeEquals(expectedMac, actualMac);
        
    final db = VaultDatabase.instance;
    if (!valid && db.settings?.queuedRotationOldSyncAuthKeyBase64 != null) {
      final oldKeyBytes = base64Decode(db.settings!.queuedRotationOldSyncAuthKeyBase64!);
      final oldAuthKey = SecretKey(oldKeyBytes);
      final expectedMacOld = await CryptoEngine.instance.hmacSha256(oldAuthKey, sentNonce);
      if (expectedMacOld.length == actualMac.length && _constantTimeEquals(expectedMacOld, actualMac)) {
        valid = true;
        socket.add(SyncMessage(SyncMsgType.vekRotation, {
          'wrappedNewVek': db.settings!.queuedRotationWrappedNewVekBase64,
          'rotationTimestamp': DateTime.now().toUtc().toIso8601String(),
          'rotatedByDeviceId': db.settings!.selfDeviceId,
        }).encode());
      }
    }
    
    print('SyncConnection: Authentication result -> validity = $valid');
    authenticated = valid;
    
    if (valid) {
      if (!_authCompleter.isCompleted) _authCompleter.complete(true);
    } else {
      Timer(const Duration(seconds: 2), () {
        if (!authenticated && socket.readyState == WebSocket.open) {
          if (!_authCompleter.isCompleted) _authCompleter.complete(false);
          _fail();
        }
      });
    }
  }

  void _fail() {
    if (!_authCompleter.isCompleted) _authCompleter.complete(false);
    socket.close();
  }

  /// Waits for OUR challenge to be answered correctly. A short timeout —
  /// this all happens over localhost-speed LAN, so anything slower than a
  /// couple seconds means the peer isn't going to answer at all (or is
  /// stalling deliberately).
  Future<bool> waitForAuthentication() =>
      _authCompleter.future.timeout(const Duration(seconds: 6), onTimeout: () => false);

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

class DiscoveredPeer {
  final String name;
  final String host;
  final int port;
  DiscoveredPeer({required this.name, required this.host, required this.port});
}

/// Works over any IP-reachable LAN: same WiFi network, OR one device's
/// mobile hotspot with the other device (e.g. a laptop) connected to it.
/// Both cases are just "a LAN" as far as mDNS multicast and WebSocket are
/// concerned — no special-casing needed. The only requirement is that
/// multicast isn't blocked (some routers/hotspot modes with "AP isolation"
/// block device-to-device traffic; if discovery fails, that's the first
/// thing to check on the hotspot's settings).
///
/// Runs on every device (Flutter app instances). The browser extension
/// acts purely as a WebSocket CLIENT against whichever Flutter app is
/// advertising on the LAN (extensions cannot host a TCP/WebSocket server
/// themselves), so this class deliberately keeps client and server sides
/// independent — the extension only ever needs the client half's protocol.
class LanSyncService {
  LanSyncService._();
  static final LanSyncService instance = LanSyncService._();
  
  void Function()? recordsUpdatedCallback;

  static const _channel = MethodChannel('com.janusvault.app/main_auth');
  int _lockRefCount = 0;

  Future<void> _acquireLock() async {
    _lockRefCount++;
    if (_lockRefCount == 1) {
      try { await _channel.invokeMethod('acquireMulticastLock'); } catch (_) {}
    }
  }

  Future<void> _releaseLock() async {
    if (_lockRefCount > 0) _lockRefCount--;
    if (_lockRefCount == 0) {
      try { await _channel.invokeMethod('releaseMulticastLock'); } catch (_) {}
    }
  }

  HttpServer? _server;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;

  bool get isHosting => _server != null && _broadcast != null && _broadcast!.isReady;

  int? get boundPort => _server?.port;

  VaultDatabase get _db => VaultDatabase.instance;

  /// Registered once at app startup (see main.dart) — shows an
  /// approve/deny UI plus a biometric check on THIS device, in response to
  /// a request that arrived over the LAN from a browser extension that
  /// wants to reveal or autofill a password. Returns whether it was
  /// approved. If nothing is registered (e.g. this build doesn't wire up
  /// the UI layer), every remote request is denied by default — fail
  /// closed, never fail open.
  Future<bool> Function(String actionLabel)? onAuthPromptRequested;

  /// shows an approve/deny UI with a 6-digit ECDH PIN matching dialogue.
  Future<bool> Function(String deviceName, String pin)? onPairingRequested;

  // ---------------------------------------------------------------------
  // Server side: advertise this device + accept sync connections
  // ---------------------------------------------------------------------

  Future<void> startAdvertisingAndServing({required String deviceDisplayName}) async {
    if (isHosting) return;
    
    await _acquireLock();

    try {
      _server ??= await HttpServer.bind(InternetAddress.anyIPv4, 51827);
    } catch (_) {
      // If default port is in use, fallback to any available port
      try {
        _server ??= await HttpServer.bind(InternetAddress.anyIPv4, 0);
      } catch (_) {}
    }
    
    if (_server != null) {
      _server!.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        _handlePeerConnection(socket);
      } else {
        request.response
          ..statusCode = HttpStatus.upgradeRequired
          ..write('JanusVault sync endpoint — WebSocket upgrade required')
          ..close();
      }
    });
    }
    
    if (_server != null) {
      if (_broadcast == null) {
        final service = BonsoirService(name: deviceDisplayName, type: kServiceType, port: _server!.port);
        _broadcast = BonsoirBroadcast(service: service);
        await _broadcast!.ready;
        await _broadcast!.start();
      }
    }
  }

  Future<void> stopAdvertisingAndServing() async {
    if (_broadcast != null) {
      try { await _broadcast!.stop(); } catch (_) {}
      _broadcast = null;
    }
    if (_server != null) {
      try { await _server!.close(force: true); } catch (_) {}
      _server = null;
    }
    
    await _releaseLock();
  }

  void _handlePeerConnection(WebSocket socket) {
    print('LanSyncService: Incoming WebSocket connection from peer');
    if (!VaultSession.instance.isUnlocked) {
      print('LanSyncService: Vault is locked, rejecting peer connection');
      socket.add(SyncMessage(SyncMsgType.error, {
        'message': 'This device\'s vault is locked. Open JanusVault and unlock it, then try again.',
      }).encode());
      socket.close();
      return;
    }

    final conn = _SyncConnection(socket, VaultSession.instance.vek);

    // Challenge them immediately...
    conn.sendChallenge();

    socket.listen((raw) async {
      try {
        final message = SyncMessage.decode(raw as String);
        await _handleIncomingMessage(conn, message);
      } catch (e) {
        socket.add(SyncMessage(SyncMsgType.error, {'message': e.toString()}).encode());
      }
    });

    // ...and once THEY prove themselves (by answering our challenge), only
    // then do we volunteer our own device list. If they never answer (or
    // answer wrong), nothing beyond hello/helloResponse ever gets sent to
    // them at all — see the early-return in _handleIncomingMessage.
    print('LanSyncService: Waiting for peer to authenticate...');
    conn.waitForAuthentication().then((ok) {
      print('LanSyncService: waitForAuthentication completed with ok=$ok');
      if (ok) _sendDeviceInfo(conn);
    });
  }

  void _sendDeviceInfo(_SyncConnection conn) {
    print('LanSyncService: Sending device info to peer');
    final deviceManager = DeviceManager.instance;
    final self = deviceManager.selfDeviceInfo();
    if (self == null) return; // vault not initialized yet on this device
    final all = [self, ...deviceManager.knownPeerDeviceInfos()];
    conn.socket.add(SyncMessage(SyncMsgType.deviceInfo, {'devices': all.map((d) => d.toJson()).toList()}).encode());
  }

  Future<void> _handleIncomingMessage(_SyncConnection conn, SyncMessage message) async {
    final socket = conn.socket;
    print('LanSyncService: Received message type: ${message.type.name}');

    // Handshake messages are the only ones ever processed before the peer
    // has proven it holds the VEK-derived key. Everything else — device
    // lists, vault metadata/records, and especially auth-approval requests
    // — is silently dropped for an unauthenticated connection. This is the
    // actual anti-hijack enforcement point.
    if (message.type == SyncMsgType.hello) {
      await conn.respondToChallenge(message.payload['nonce'] as String);
      return;
    }
    if (message.type == SyncMsgType.helloResponse) {
      await conn.receiveChallengeResponse(message.payload['mac'] as String);
      return;
    }
    if (message.type == SyncMsgType.pairingRequest) {
      await _handlePairingRequest(conn, message);
      return;
    }

    if (message.type == SyncMsgType.vekRotation) {
      final wrappedNewVekBase64 = message.payload['wrappedNewVek'] as String?;
      if (wrappedNewVekBase64 == null) return;
      final vekToUse = VaultSession.instance.vek;
      
      final currentAuthKey = await CryptoEngine.instance.deriveSyncAuthKey(vekToUse);
      final blob = EncryptedBlob.fromBase64(wrappedNewVekBase64);
      try {
        final newVek = await CryptoEngine.instance.unwrapKey(wrapped: blob, wrappingKey: currentAuthKey);
        await VaultRepository.instance.reencryptAllWithNewVek(newVek);
        final deviceLocalKey = await SecureKeyStore.instance.loadDeviceLocalKey();
        final record = _db.findDeviceById(_db.settings!.selfDeviceId);
        final wrappedForStorage = await CryptoEngine.instance.wrapKey(keyToWrap: newVek, wrappingKey: deviceLocalKey!);
        record!.wrappedVekBase64 = wrappedForStorage.toBase64();
        await _db.upsertDevice(record);
        
        socket.add(SyncMessage(SyncMsgType.vekRotationAck, {}).encode());
        conn.authenticated = true;
        if (!conn._authCompleter.isCompleted) conn._authCompleter.complete(true);
      } catch (e) {
        socket.add(SyncMessage(SyncMsgType.error, {'message': 'Key rotation failed: $e'}).encode());
      }
      return;
    }

    if (!conn.authenticated) return;

    switch (message.type) {
      case SyncMsgType.metadata:
        await DeviceManager.instance.touchSelfLastSynced();
        final theirs = (message.payload['entries'] as List)
            .map((e) => RecordMeta.fromJson(e as Map<String, dynamic>))
            .toList();
        final mine = await _localMetadata();
        final diff = SyncDiff.compute(mine: mine, theirs: theirs);

        // Push what I have that they lack / is newer.
        if (diff.uuidsToSendToPeer.isNotEmpty) {
          final records = await _wireRecordsFor(diff.uuidsToSendToPeer);
          socket.add(SyncMessage(SyncMsgType.records, {'entries': records.map((r) => r.toJson()).toList()}).encode());
        }
        // Ask for what I lack / is stale.
        if (diff.uuidsToRequestFromPeer.isNotEmpty) {
          conn.awaitingRecordsReply = true;
          socket.add(SyncMessage(SyncMsgType.request, {'uuids': diff.uuidsToRequestFromPeer}).encode());
        } else {
          // Nothing more to wait for from this peer for this round.
          socket.add(SyncMessage(SyncMsgType.done, {}).encode());
          await _closeQuietly(socket);
        }
        break;

      case SyncMsgType.request:
        final uuids = (message.payload['uuids'] as List).cast<String>();
        final records = await _wireRecordsFor(uuids);
        socket.add(SyncMessage(SyncMsgType.records, {'entries': records.map((r) => r.toJson()).toList()}).encode());
        break;

      case SyncMsgType.records:
        final entries = (message.payload['entries'] as List).map((e) => WireRecord.fromJson(e as Map<String, dynamic>));
        await _applyIncomingRecords(entries.toList());
        if (conn.awaitingRecordsReply) {
          // This was the reply to OUR EARLIER `request` — the round is
          // now complete from our side too.
          conn.awaitingRecordsReply = false;
          socket.add(SyncMessage(SyncMsgType.done, {}).encode());
          await _closeQuietly(socket);
        }
        break;

      case SyncMsgType.deviceInfo:
        final infos = (message.payload['devices'] as List)
            .map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>))
            .toList();
            
        final peerId = infos.firstOrNull?.deviceId;
        final existingPeer = peerId != null ? _db.findDeviceById(peerId) : null;
        if (existingPeer != null && existingPeer.revoked) {
          socket.add(SyncMessage(SyncMsgType.error, {'message': 'Device connection rejected (revoked).'}).encode());
          await _closeQuietly(socket);
          return;
        }
        
        final selfInfo = infos.where((d) => d.deviceId == _db.settings?.selfDeviceId).firstOrNull;
        if (selfInfo != null && selfInfo.revoked) {
          await _db.wipeAll();
          socket.add(SyncMessage(SyncMsgType.error, {'message': 'This device has been revoked and wiped itself.'}).encode());
          await _closeQuietly(socket);
          return;
        }
            
        await DeviceManager.instance.mergeIncomingDeviceInfos(infos);
        break;

      case SyncMsgType.authRequest:
        final requestId = message.payload['requestId'] as String;
        final actionLabel = message.payload['actionLabel'] as String? ?? 'access a saved password';
        bool approved;
        try {
          final handler = onAuthPromptRequested;
          approved = handler == null ? false : await handler(actionLabel);
        } catch (_) {
          approved = false; // any failure in the prompt/biometric path denies the request
        }
        socket.add(SyncMessage(SyncMsgType.authResponse, {'requestId': requestId, 'approved': approved}).encode());
        break;

      case SyncMsgType.done:
        // The peer has told us they have nothing further to send/request —
        // closing here is what makes `await socket.done` on the initiating
        // side (syncWithPeer) actually resolve instead of hanging forever.
        await _closeQuietly(socket);
        break;

      case SyncMsgType.hello:
      case SyncMsgType.helloResponse:
      case SyncMsgType.pairingRequest:
      case SyncMsgType.pairingChallenge:
      case SyncMsgType.pairingSuccess:
      case SyncMsgType.error:
      case SyncMsgType.authResponse:
      case SyncMsgType.vekRotation:
      case SyncMsgType.vekRotationAck:
        break;
    }
  }

  Future<void> _handlePairingRequest(_SyncConnection conn, SyncMessage msg) async {
    try {
      final deviceName = msg.payload['deviceName'] as String;
      final peerKeyB64 = msg.payload['pubKey'] as String;
      
      final engine = CryptoEngine.instance;
      final peerKey = engine.importEcdhPublicKey(peerKeyB64);
      final myKeyPair = await engine.generateEcdhKeyPair();
      final myPubKey = await myKeyPair.extractPublicKey();
      final myKeyB64 = engine.exportEcdhPublicKey(myPubKey);
      
      conn.socket.add(SyncMessage(SyncMsgType.pairingChallenge, {'pubKey': myKeyB64}).encode());
      
      final sharedSecret = await engine.deriveEcdhSharedSecret(myKeyPair, peerKey);
      final pin = await engine.computeEcdhPin(sharedSecret);
      
      final handler = onPairingRequested;
      final approved = handler == null ? false : await handler(deviceName, pin);
      
      if (approved) {
        final wrappingKey = await engine.deriveEcdhWrappingKey(sharedSecret);
        final wrappedVek = await engine.wrapKey(keyToWrap: VaultSession.instance.vek, wrappingKey: wrappingKey);
        
        final selfInfo = DeviceManager.instance.selfDeviceInfo();
        conn.socket.add(SyncMessage(SyncMsgType.pairingSuccess, {
          'wrappedVek': wrappedVek.toBase64(),
          'device': selfInfo?.toJson() ?? {},
        }).encode());
      } else {
        conn.socket.add(SyncMessage(SyncMsgType.error, {'message': 'Pairing rejected on phone.'}).encode());
      }
    } catch (e) {
      conn.socket.add(SyncMessage(SyncMsgType.error, {'message': 'Pairing failed: $e'}).encode());
    }
    // Disconnect after pairing attempt ends, so the peer reconnects with proper handshake
    await _closeQuietly(conn.socket);
  }

  // ---------------------------------------------------------------------
  // Client side: discover peers + initiate a sync session
  // ---------------------------------------------------------------------

  /// This device's own LAN IP (WiFi or hotspot interface), for display in
  /// the UI so the browser extension user can type it in manually.
  Future<String?> getSelfLanAddress() => NetworkInfo().getWifiIP();

  Future<List<DiscoveredPeer>> discoverPeers({Duration timeout = const Duration(seconds: 4)}) async {
    await _acquireLock();
    final found = <DiscoveredPeer>[];
    _discovery = BonsoirDiscovery(type: kServiceType);
    await _discovery!.ready;

    final completer = Future<void>.delayed(timeout);
    _discovery!.eventStream?.listen((event) {
      if (event.type == BonsoirDiscoveryEventType.discoveryServiceResolved) {
        final service = event.service;
        if (service is ResolvedBonsoirService) {
          found.add(DiscoveredPeer(name: service.name, host: service.host ?? '', port: service.port));
        }
      }
    });
    await _discovery!.start();
    await completer;
    await _discovery!.stop();
    await _releaseLock();
    return found;
  }

  /// Connects to a discovered peer and runs one full sync round: send my
  /// metadata, react to whatever they request/send back, and apply any
  /// records they push to me.
  /// Manual fallback used by the browser extension (which cannot use mDNS
  /// from a service worker) and as a backup on Flutter too if discovery
  /// doesn't find anything on a hotspot with AP isolation enabled. The
  /// phone app should display its own LAN IP + port (e.g. in the Devices
  /// screen) for the user to type into the extension once.
  Future<void> syncWithHost(String host, int port) => syncWithPeer(DiscoveredPeer(name: host, host: host, port: port));

  Future<void> syncWithPeer(DiscoveredPeer peer) async {
    final socket = await WebSocket.connect('ws://${peer.host}:${peer.port}');
    final conn = _SyncConnection(socket, VaultSession.instance.isUnlocked ? VaultSession.instance.vek : null);

    socket.listen((raw) async {
      final message = SyncMessage.decode(raw as String);
      await _handleIncomingMessage(conn, message);
    });

    conn.sendChallenge();
    final authenticated = await conn.waitForAuthentication();
    print('LanSyncService (Client mode): Handshake resulted in $authenticated');
    if (!authenticated) {
      await socket.close();
      throw Exception('Could not verify this device is a trusted JanusVault peer — refusing to sync.');
    }

    _sendDeviceInfo(conn);
    final mine = await _localMetadata();
    socket.add(SyncMessage(SyncMsgType.metadata, {'entries': mine.map((m) => m.toJson()).toList()}).encode());

    try {
      await socket.done;
    } finally {
      // Reaching here means the peer closed the connection (or an error
      // occurred, which propagates before this). Either way, a genuine
      // two-way exchange was attempted, so record it — this is what keeps
      // "Last synced" on the Trusted devices screen from going stale.
      await DeviceManager.instance.touchSelfLastSynced();
    }
  }

  Future<Map<String, String>> syncWithAllDiscoveredPeers({Duration timeout = const Duration(seconds: 4)}) async {
    final peers = await discoverPeers(timeout: timeout);
    final results = <String, String>{};
    for (final peer in peers) {
      try {
        await syncWithPeer(peer);
        results[peer.name] = 'Success';
      } catch (e) {
        results[peer.name] = 'Failed: $e';
      }
    }
    return results;
  }

  // ---------------------------------------------------------------------
  // Local data access helpers shared by client + server code paths
  // ---------------------------------------------------------------------

  /// `WebSocket.close()` is safe to call more than once in practice, but
  /// both sides of this protocol can end up racing to close the same
  /// connection (each independently decided the round is done) — this
  /// just makes sure that race never surfaces as an uncaught exception.
  Future<void> _closeQuietly(WebSocket socket) async {
    try {
      await socket.close();
    } catch (_) {
      // Already closed/closing — nothing to do.
    }
  }

  Future<List<RecordMeta>> _localMetadata() async {
    return _db.allEntries
        .map((r) => RecordMeta(uuid: r.uuid, hash: r.hash, lastUpdated: r.lastUpdated, deleted: r.deleted))
        .toList();
  }

  Future<List<WireRecord>> _wireRecordsFor(List<String> uuids) async {
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

  /// Applies incoming wire records using the exact same UUID + lastUpdated
  /// merge rule used everywhere else in the app (backup restore, etc.), so
  /// there is only one conflict-resolution policy in the whole system.
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
    if (changed && recordsUpdatedCallback != null) {
      recordsUpdatedCallback!();
    }
  }
}
