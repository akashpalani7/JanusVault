import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../devices/device_manager.dart';
import '../storage/vault_database.dart';
import 'sync_protocol.dart';

const String kServiceType = '_peervault._tcp';
const int kSyncPort = 51827;

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

  HttpServer? _server;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;

  VaultDatabase get _db => VaultDatabase.instance;

  /// Registered once at app startup (see main.dart) — shows an
  /// approve/deny UI plus a biometric check on THIS device, in response to
  /// a request that arrived over the LAN from a browser extension that
  /// wants to reveal or autofill a password. Returns whether it was
  /// approved. If nothing is registered (e.g. this build doesn't wire up
  /// the UI layer), every remote request is denied by default — fail
  /// closed, never fail open.
  Future<bool> Function(String actionLabel)? onAuthPromptRequested;

  // ---------------------------------------------------------------------
  // Server side: advertise this device + accept sync connections
  // ---------------------------------------------------------------------

  Future<void> startAdvertisingAndServing({required String deviceDisplayName}) async {
    _server ??= await HttpServer.bind(InternetAddress.anyIPv4, kSyncPort);
    _server!.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        _handlePeerConnection(socket);
      } else {
        request.response
          ..statusCode = HttpStatus.upgradeRequired
          ..write('PeerVault sync endpoint — WebSocket upgrade required')
          ..close();
      }
    });

    final service = BonsoirService(name: deviceDisplayName, type: kServiceType, port: kSyncPort);
    _broadcast = BonsoirBroadcast(service: service);
    await _broadcast!.ready;
    await _broadcast!.start();
  }

  Future<void> stopAdvertisingAndServing() async {
    await _broadcast?.stop();
    await _server?.close(force: true);
    _server = null;
  }

  void _handlePeerConnection(WebSocket socket) {
    // Send our device list to whoever just connected, unconditionally and
    // immediately — this is a one-shot broadcast, never replied to with
    // another deviceInfo message, so there's no ping-pong risk (see
    // DeviceManager.mergeIncomingDeviceInfos / touchSelfLastSynced).
    _sendDeviceInfo(socket);

    socket.listen((raw) async {
      try {
        final message = SyncMessage.decode(raw as String);
        await _handleIncomingMessage(socket, message);
      } catch (e) {
        socket.add(SyncMessage(SyncMsgType.error, {'message': e.toString()}).encode());
      }
    });
  }

  void _sendDeviceInfo(WebSocket socket) {
    final deviceManager = DeviceManager.instance;
    final self = deviceManager.selfDeviceInfo();
    if (self == null) return; // vault not initialized yet on this device
    final all = [self, ...deviceManager.knownPeerDeviceInfos()];
    socket.add(SyncMessage(SyncMsgType.deviceInfo, {'devices': all.map((d) => d.toJson()).toList()}).encode());
  }

  Future<void> _handleIncomingMessage(WebSocket socket, SyncMessage message) async {
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
          socket.add(SyncMessage(SyncMsgType.request, {'uuids': diff.uuidsToRequestFromPeer}).encode());
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
        break;

      case SyncMsgType.deviceInfo:
        final infos = (message.payload['devices'] as List)
            .map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>))
            .toList();
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

      case SyncMsgType.hello:
      case SyncMsgType.done:
      case SyncMsgType.error:
      case SyncMsgType.authResponse:
        break;
    }
  }

  // ---------------------------------------------------------------------
  // Client side: discover peers + initiate a sync session
  // ---------------------------------------------------------------------

  /// This device's own LAN IP (WiFi or hotspot interface), for display in
  /// the UI so the browser extension user can type it in manually.
  Future<String?> getSelfLanAddress() => NetworkInfo().getWifiIP();

  Future<List<DiscoveredPeer>> discoverPeers({Duration timeout = const Duration(seconds: 4)}) async {
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
    _sendDeviceInfo(socket);
    final mine = await _localMetadata();
    socket.add(SyncMessage(SyncMsgType.metadata, {'entries': mine.map((m) => m.toJson()).toList()}).encode());

    try {
      await for (final raw in socket) {
        final message = SyncMessage.decode(raw as String);
        await _handleIncomingMessage(socket, message);
      }
    } finally {
      // Reaching here means the peer closed the connection (or an error
      // occurred, which propagates before this). Either way, a genuine
      // two-way exchange was attempted, so record it — this is what keeps
      // "Last synced" on the Trusted devices screen from going stale.
      await DeviceManager.instance.touchSelfLastSynced();
    }
  }

  // ---------------------------------------------------------------------
  // Local data access helpers shared by client + server code paths
  // ---------------------------------------------------------------------

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
      }
    }
  }
}
