import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';

import '../vault/vault_session.dart';
import 'sync_message_handler.dart';
import 'sync_protocol.dart';

/// Android-to-Android sync using Google's Nearby Connections API.
///
/// Uses a layered protocol identical to Quick Share:
///   1. BLE for device discovery (low power, works in background)
///   2. Auto-upgrade to WiFi Direct for high-bandwidth data transfer
///   3. All handled transparently by the Nearby Connections library
///
/// The sync protocol is identical to WiFi/WebSocket and BLE GATT:
/// same VEK-based HMAC handshake, same SyncMessage JSON exchange.
/// Only the transport changes — security model is unchanged.
class NearbySyncService {
  NearbySyncService._();
  static final NearbySyncService instance = NearbySyncService._();

  static const String _serviceId = 'com.janusvault.nearby';
  static const Strategy _strategy = Strategy.P2P_POINT_TO_POINT;

  bool _isAdvertising = false;
  bool _isDiscovering = false;
  bool get isAdvertising => _isAdvertising;
  bool get isDiscovering => _isDiscovering;

  void Function()? recordsUpdatedCallback;
  Future<bool> Function(String actionLabel)? onAuthPromptRequested;
  Future<bool> Function(String deviceName, String pin)? onPairingRequested;

  /// Called when a new peer is discovered during scanning.
  void Function(String endpointId, String endpointName)? onPeerDiscovered;

  /// Called when a peer is lost (went out of range / stopped advertising).
  void Function(String endpointId)? onPeerLost;

  /// Called when sync status changes (for UI updates).
  void Function(String status)? onStatusChanged;

  /// Active connection handlers, keyed by endpoint ID.
  final Map<String, SyncConnectionHandler> _connections = {};

  // -------------------------------------------------------------------
  //  Advertise (make this device discoverable to other Android devices)
  // -------------------------------------------------------------------

  Future<bool> startAdvertising({required String deviceDisplayName}) async {
    if (_isAdvertising) return true;

    try {
      final result = await Nearby().startAdvertising(
        deviceDisplayName,
        _strategy,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: _serviceId,
      );
      _isAdvertising = result;
      if (result) {
        debugPrint(
            'NearbySyncService: Advertising started as $deviceDisplayName');
        onStatusChanged?.call('Discoverable via Bluetooth');
      }
      return result;
    } catch (e) {
      debugPrint('NearbySyncService: Failed to start advertising: $e');
      return false;
    }
  }

  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;
    try {
      await Nearby().stopAdvertising();
    } catch (_) {}
    _isAdvertising = false;
    onStatusChanged?.call('Not discoverable');
  }

  // -------------------------------------------------------------------
  //  Discover (scan for nearby JanusVault Android devices)
  // -------------------------------------------------------------------

  Future<bool> startDiscovery() async {
    if (_isDiscovering) return true;

    try {
      final result = await Nearby().startDiscovery(
        'JanusVault', // our name visible to peers
        _strategy,
        onEndpointFound: (id, name, serviceId) {
          debugPrint('NearbySyncService: Found peer $name ($id)');
          onPeerDiscovered?.call(id, name);
        },
        onEndpointLost: (id) {
          final String safeId = id ?? '';
          debugPrint('NearbySyncService: Lost peer $safeId');
          onPeerLost?.call(safeId);
        },
        serviceId: _serviceId,
      );
      _isDiscovering = result;
      if (result) {
        onStatusChanged?.call('Scanning for nearby devices...');
      }
      return result;
    } catch (e) {
      debugPrint('NearbySyncService: Failed to start discovery: $e');
      return false;
    }
  }

  Future<void> stopDiscovery() async {
    if (!_isDiscovering) return;
    try {
      await Nearby().stopDiscovery();
    } catch (_) {}
    _isDiscovering = false;
  }

  // -------------------------------------------------------------------
  //  Connect and sync with a discovered peer
  // -------------------------------------------------------------------

  Future<void> connectToPeer(String endpointId, String endpointName) async {
    onStatusChanged?.call('Connecting...');
    try {
      await Nearby().requestConnection(
        endpointName,
        endpointId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      onStatusChanged?.call('Connection failed: $e');
    }
  }

  // -------------------------------------------------------------------
  //  Connection lifecycle callbacks
  // -------------------------------------------------------------------

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    debugPrint(
        'NearbySyncService: Connection initiated with ${info.endpointName}');
    // Auto-accept — VEK handshake provides our own authentication layer
    Nearby().acceptConnection(
      endpointId,
      onPayLoadRecieved: (endpointId, payload) {
        _onPayloadReceived(endpointId, payload);
      },
      onPayloadTransferUpdate: (endpointId, update) {
        // Could report progress here for large transfers
      },
    );
  }

  void _onConnectionResult(String endpointId, Status status) {
    if (status == Status.CONNECTED) {
      debugPrint('NearbySyncService: Connected to $endpointId');
      onStatusChanged?.call('Connected — authenticating...');

      // Create handler and start VEK handshake
      final handler = SyncConnectionHandler(
        transport: _NearbyTransport(endpointId),
        vek:
            VaultSession.instance.isUnlocked ? VaultSession.instance.vek : null,
        onAuthPromptRequested: onAuthPromptRequested,
        onPairingRequested: onPairingRequested,
        onRecordsUpdated: recordsUpdatedCallback,
      );
      _connections[endpointId] = handler;

      // Initiate handshake
      handler.sendChallenge();
      handler.waitForAuthentication().then((ok) {
        if (ok) {
          onStatusChanged?.call('Authenticated — syncing...');
          handler.sendDeviceInfo();
          // Send our metadata to start the sync exchange
          final mine = handler.localMetadata();
          handler.transport.send(
            SyncMessage(SyncMsgType.metadata, {
              'entries': mine.map((m) => m.toJson()).toList(),
            }).encode(),
          );
        } else {
          onStatusChanged?.call('Authentication failed — not a trusted device');
          Nearby().disconnectFromEndpoint(endpointId);
        }
      });
    } else {
      onStatusChanged?.call('Connection rejected');
    }
  }

  void _onDisconnected(String endpointId) {
    debugPrint('NearbySyncService: Disconnected from $endpointId');
    _connections.remove(endpointId);
    onStatusChanged?.call('Disconnected');
  }

  // -------------------------------------------------------------------
  //  Payload handling
  // -------------------------------------------------------------------

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type != PayloadType.BYTES) return;
    final bytes = payload.bytes;
    if (bytes == null) return;

    final rawJson = utf8.decode(bytes);
    final handler = _connections[endpointId];
    if (handler == null) return;

    try {
      final message = SyncMessage.decode(rawJson);
      handler.handleMessage(message).then((_) {
        // Check if sync completed
        if (message.type == SyncMsgType.done) {
          onStatusChanged?.call('Sync complete!');
          Nearby().disconnectFromEndpoint(endpointId);
          _connections.remove(endpointId);
        }
      });
    } catch (e) {
      debugPrint('NearbySyncService: Error processing payload: $e');
    }
  }

  // -------------------------------------------------------------------
  //  Cleanup
  // -------------------------------------------------------------------

  Future<void> stopAll() async {
    await stopAdvertising();
    await stopDiscovery();
    for (final id in _connections.keys.toList()) {
      try {
        await Nearby().disconnectFromEndpoint(id);
      } catch (_) {}
    }
    _connections.clear();
    try {
      await Nearby().stopAllEndpoints();
    } catch (_) {}
  }
}

/// Nearby Connections transport — sends messages as byte payloads.
class _NearbyTransport implements SyncTransport {
  final String endpointId;
  _NearbyTransport(this.endpointId);

  @override
  void send(String jsonMessage) {
    final bytes = Uint8List.fromList(utf8.encode(jsonMessage));
    Nearby().sendBytesPayload(endpointId, bytes);
  }

  @override
  Future<void> close() async {
    try {
      await Nearby().disconnectFromEndpoint(endpointId);
    } catch (_) {}
    NearbySyncService.instance._connections.remove(endpointId);
  }
}
