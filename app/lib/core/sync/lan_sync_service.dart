import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../devices/device_manager.dart';
import '../vault/vault_session.dart';
import 'sync_message_handler.dart';
import 'sync_protocol.dart';

const String kServiceType = '_janusvault._tcp';

class WebSocketSyncTransport implements SyncTransport {
  final WebSocket socket;
  WebSocketSyncTransport(this.socket);

  @override
  void send(String jsonMessage) {
    if (socket.readyState == WebSocket.open) {
      socket.add(jsonMessage);
    }
  }

  @override
  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {}
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

  final List<SyncConnectionHandler> _activeHandlers = [];

  void disconnectRevokedDevice(String deviceId) {
    for (final handler in List.of(_activeHandlers)) {
      if (handler.peerDeviceId == deviceId) {
        try {
          handler.transport.send(SyncMessage(SyncMsgType.error, {'message': 'Device connection rejected (revoked).'}).encode());
          handler.transport.close();
        } catch (_) {}
        _activeHandlers.remove(handler);
      }
    }
  }

  void _handlePeerConnection(WebSocket socket) {
    debugPrint('LanSyncService: Incoming WebSocket connection from peer');
    if (!VaultSession.instance.isUnlocked) {
      debugPrint('LanSyncService: Vault is locked, rejecting peer connection');
      socket.add(SyncMessage(SyncMsgType.error, {
        'message': "This device's vault is locked. Open JanusVault and unlock it, then try again.",
      }).encode());
      socket.close();
      return;
    }

    final transport = WebSocketSyncTransport(socket);
    final handler = SyncConnectionHandler(
      transport: transport,
      vek: VaultSession.instance.vek,
      onAuthPromptRequested: onAuthPromptRequested,
      onPairingRequested: onPairingRequested,
      onRecordsUpdated: recordsUpdatedCallback,
    );
    _activeHandlers.add(handler);

    socket.listen(
      (raw) async {
        try {
          final message = SyncMessage.decode(raw as String);
          await handler.handleMessage(message);
        } catch (e) {
          transport.send(SyncMessage(SyncMsgType.error, {'message': e.toString()}).encode());
        }
      },
      onDone: () => _activeHandlers.remove(handler),
      onError: (_) => _activeHandlers.remove(handler),
    );

    handler.sendChallenge();
    handler.waitForAuthentication().then((ok) {
      debugPrint('LanSyncService: waitForAuthentication completed with ok=$ok');
      if (ok) {
        handler.sendDeviceInfo();
      }
    });
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
  Future<void> syncWithHost(String host, int port) => syncWithPeer(DiscoveredPeer(name: host, host: host, port: port));

  Future<void> syncWithPeer(DiscoveredPeer peer) async {
    final socket = await WebSocket.connect('ws://${peer.host}:${peer.port}');
    final transport = WebSocketSyncTransport(socket);
    final handler = SyncConnectionHandler(
      transport: transport,
      vek: VaultSession.instance.isUnlocked ? VaultSession.instance.vek : null,
      onAuthPromptRequested: onAuthPromptRequested,
      onPairingRequested: onPairingRequested,
      onRecordsUpdated: recordsUpdatedCallback,
    );

    socket.listen(
      (raw) async {
        try {
          final message = SyncMessage.decode(raw as String);
          await handler.handleMessage(message);
        } catch (_) {}
      },
    );

    handler.sendChallenge();
    final authenticated = await handler.waitForAuthentication();
    debugPrint('LanSyncService (Client mode): Handshake resulted in $authenticated');
    if (!authenticated) {
      await transport.close();
      throw Exception('Could not verify this device is a trusted JanusVault peer — refusing to sync.');
    }

    handler.sendDeviceInfo();
    final mine = handler.localMetadata();
    transport.send(SyncMessage(SyncMsgType.metadata, {'entries': mine.map((m) => m.toJson()).toList()}).encode());

    try {
      await socket.done;
    } finally {
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
}
