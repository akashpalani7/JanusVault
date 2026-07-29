import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ble_peripheral/ble_peripheral.dart';

import '../vault/vault_session.dart';
import 'sync_message_handler.dart';
import 'sync_protocol.dart';

/// PeerVault BLE GATT service UUID — custom 128-bit UUID for discovery.
/// Both the phone (GATT server/peripheral) and browser extension (GATT
/// client/central via Web Bluetooth) use this to find each other.
const String kPeerVaultBleServiceUuid = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';

/// Read/write/notify characteristic for exchanging SyncMessage JSON.
/// Messages are chunked into BLE-sized packets and reassembled.
const String kSyncCharacteristicUuid = 'a1b2c3d4-e5f6-7890-abcd-ef1234567891';

/// MTU-safe chunk size (conservative — most modern devices negotiate
/// 512+ bytes, but 182 bytes per write ensures compatibility with
/// older BLE 4.0 devices that only support 20-byte payloads after
/// overhead). We use 480 as a practical modern default.
const int kBleChunkSize = 480;

/// End-of-message sentinel appended after the last chunk of a message.
/// The receiver accumulates chunks until it sees this marker, then
/// parses the complete JSON. Using a sentinel instead of a length
/// prefix avoids issues with BLE write ordering across transports.
const String kEomMarker = '\x04'; // ASCII EOT

/// BLE GATT server that the phone exposes for PC/browser sync.
///
/// Architecture:
///   - Phone acts as BLE **peripheral** (GATT server)
///   - PC browser extension acts as BLE **central** (GATT client via
///     Web Bluetooth through a Chrome Offscreen Document)
///   - Once connected, the same VEK-based HMAC handshake + SyncMessage
///     protocol runs over BLE characteristic reads/writes
///
/// This enables COMPLETELY OFFLINE sync — no WiFi, no router, no
/// internet. Just Bluetooth radio between two devices.
class BleGattService {
  BleGattService._();
  static final BleGattService instance = BleGattService._();

  bool _isAdvertising = false;
  bool get isAdvertising => _isAdvertising;

  void Function()? recordsUpdatedCallback;
  Future<bool> Function(String actionLabel)? onAuthPromptRequested;
  Future<bool> Function(String deviceName, String pin)? onPairingRequested;

  /// Buffer for reassembling chunked messages from the BLE central.
  final StringBuffer _incomingBuffer = StringBuffer();

  /// The active connection handler (one connection at a time for BLE).
  SyncConnectionHandler? _handler;

  // -------------------------------------------------------------------
  //  Start / stop GATT advertising
  // -------------------------------------------------------------------

  /// Starts advertising PeerVault's BLE GATT service so PC browsers
  /// can discover and connect to sync.
  Future<void> startAdvertising({required String deviceDisplayName}) async {
    if (_isAdvertising) return;

    try {
      // Initialize the BLE peripheral plugin
      await BlePeripheral.initialize();

      // Add our custom sync service + characteristic
      await BlePeripheral.addService(
        BleService(
          uuid: kPeerVaultBleServiceUuid,
          primary: true,
          characteristics: [
            BleCharacteristic(
              uuid: kSyncCharacteristicUuid,
              properties: [
                CharacteristicProperties.read.index,
                CharacteristicProperties.write.index,
                CharacteristicProperties.writeWithoutResponse.index,
                CharacteristicProperties.notify.index,
              ],
              permissions: [
                AttributePermissions.readable.index,
                AttributePermissions.writeable.index,
              ],
            ),
          ],
        ),
      );

      // Listen for incoming writes on the sync characteristic
      BlePeripheral.setWriteRequestCallback(_onWriteRequest);
      BlePeripheral.setReadRequestCallback(_onReadRequest);

      // Start advertising
      await BlePeripheral.startAdvertising(
        services: [kPeerVaultBleServiceUuid],
        localName: null,
      );

      _isAdvertising = true;
      print('BleGattService: Advertising started as PeerVault-$deviceDisplayName');
    } catch (e) {
      String errMsg = e.toString();
      if (errMsg.contains('UnsupportedOperationException')) {
        errMsg = 'Bluetooth is turned off or unsupported on this device.';
      } else if (errMsg.contains('SecurityException')) {
        errMsg = 'Bluetooth permissions missing or denied.';
      }
      print('BleGattService: Failed to start advertising: $errMsg');
      _isAdvertising = false;
      throw Exception(errMsg);
    }
  }

  /// Stops BLE advertising and cleans up.
  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;
    try {
      await BlePeripheral.stopAdvertising();
    } catch (_) {}
    _isAdvertising = false;
    _handler = null;
    _incomingBuffer.clear();
    print('BleGattService: Advertising stopped');
  }

  // -------------------------------------------------------------------
  //  Incoming BLE write handling (central → peripheral)
  // -------------------------------------------------------------------

  /// Called when the BLE central (browser extension on PC) writes data
  /// to our sync characteristic. Data arrives chunked; we accumulate
  /// until we see the EOM marker, then process the complete JSON message.
  WriteRequestResult? _onWriteRequest(String deviceId, String characteristicId, int offset, Uint8List? value) {
    final chunk = utf8.decode(value ?? []);

    _incomingBuffer.write(chunk);
    final currentBuffer = _incomingBuffer.toString();

    if (currentBuffer.endsWith(kEomMarker)) {
      // Last chunk — strip the marker and process
      final completeMessage = currentBuffer.substring(0, currentBuffer.length - kEomMarker.length);
      _incomingBuffer.clear();

      _processIncomingMessage(completeMessage, deviceId);
    }
    return null; // Acknowledge successfully
  }

  ReadRequestResult? _onReadRequest(String deviceId, String characteristicId, int offset, Uint8List? value) {
    return ReadRequestResult(value: Uint8List(0));
  }

  /// Process a complete JSON message received over BLE.
  Future<void> _processIncomingMessage(String rawJson, String deviceId) async {
    try {
      final message = SyncMessage.decode(rawJson);

      // Lazily create the handler on first message (connection start)
      _handler ??= SyncConnectionHandler(
        transport: _BleTransport(deviceId),
        vek: VaultSession.instance.isUnlocked ? VaultSession.instance.vek : null,
        onAuthPromptRequested: onAuthPromptRequested,
        onPairingRequested: onPairingRequested,
        onRecordsUpdated: recordsUpdatedCallback,
      );

      final handler = _handler;
      if (handler == null) return;

      // If this is the first message, also send our challenge
      if (message.type == SyncMsgType.hello && !handler.authenticated) {
        await handler.sendChallenge();
      }

      await handler.handleMessage(message);

      // After successful auth, send device info
      final currentHandler = _handler;
      if (currentHandler != null && currentHandler.authenticated && message.type == SyncMsgType.helloResponse) {
        currentHandler.sendDeviceInfo();
      }
    } catch (e) {
      print('BleGattService: Error processing message: $e');
      final errorMsg = SyncMessage(SyncMsgType.error, {'message': e.toString()});
      _sendChunkedNotification(deviceId, errorMsg.encode());
    }
  }

  // -------------------------------------------------------------------
  //  Outgoing BLE notification (peripheral → central)
  // -------------------------------------------------------------------

  /// Sends a message to the connected central by notifying on the sync
  /// characteristic. Large messages are automatically chunked.
  static void _sendChunkedNotification(String deviceId, String jsonMessage) {
    final data = '$jsonMessage$kEomMarker';
    final bytes = utf8.encode(data);

    for (var offset = 0; offset < bytes.length; offset += kBleChunkSize) {
      final end = (offset + kBleChunkSize > bytes.length) ? bytes.length : offset + kBleChunkSize;
      final chunk = Uint8List.fromList(bytes.sublist(offset, end));
      BlePeripheral.updateCharacteristic(
        characteristicId: kSyncCharacteristicUuid,
        value: chunk,
        deviceId: deviceId,
      );
    }
  }
}

/// BLE transport implementation — sends messages as chunked
/// notifications on the GATT sync characteristic.
class _BleTransport implements SyncTransport {
  final String deviceId;
  _BleTransport(this.deviceId);

  @override
  void send(String jsonMessage) {
    BleGattService._sendChunkedNotification(deviceId, jsonMessage);
  }

  @override
  Future<void> close() async {
    // BLE connections are managed by the central (PC) side.
    // The peripheral just stops responding; the central will
    // disconnect after seeing the 'done' message.
    BleGattService.instance._handler = null;
    BleGattService.instance._incomingBuffer.clear();
  }
}
