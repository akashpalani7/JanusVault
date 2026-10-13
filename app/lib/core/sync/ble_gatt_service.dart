import 'dart:async';
import 'dart:convert';

import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter/foundation.dart';

import '../vault/vault_session.dart';
import 'sync_message_handler.dart';
import 'sync_protocol.dart';

/// JanusVault BLE GATT service UUID — custom 128-bit UUID for discovery.
/// Both the phone (GATT server/peripheral) and browser extension (GATT
/// client/central via Web Bluetooth) use this to find each other.
const String kJanusVaultBleServiceUuid = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';

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
  bool _isInitialized = false;

  void Function()? recordsUpdatedCallback;
  Future<bool> Function(String actionLabel)? onAuthPromptRequested;
  Future<bool> Function(String deviceName, String pin)? onPairingRequested;
  void Function(String status)? onStatusChanged;

  /// Buffer for reassembling chunked messages from the BLE central.
  final StringBuffer _incomingBuffer = StringBuffer();

  /// The active connection handler (one connection at a time for BLE).
  SyncConnectionHandler? _handler;
  String? _activeDeviceId;

  // -------------------------------------------------------------------
  //  Start / stop GATT advertising
  // -------------------------------------------------------------------

  /// Starts advertising JanusVault's BLE GATT service so PC browsers
  /// can discover and connect to sync.
  Future<void> startAdvertising({required String deviceDisplayName}) async {
    if (_isAdvertising) return;

    try {
      if (!_isInitialized) {
        // Initialize the BLE peripheral plugin
        await BlePeripheral.initialize();

        // Add our custom sync service + characteristic
        await BlePeripheral.addService(
          BleService(
            uuid: kJanusVaultBleServiceUuid,
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
        _isInitialized = true;
      }

      // Track status updates from the native BLE stack
      BlePeripheral.setAdvertisingStatusUpdateCallback(
          (bool advertising, String? error) {
        debugPrint(
            'BleGattService: Advertising update: advertising=$advertising, error=$error');
        _isAdvertising = advertising;
        if (error != null && error.isNotEmpty) {
          onStatusChanged?.call('BLE Error: $error');
        } else if (advertising) {
          onStatusChanged?.call('Waiting for PC to connect via browser extension...');
        } else {
          onStatusChanged?.call('Bluetooth advertising stopped');
        }
      });

      // Listen for incoming writes on the sync characteristic
      BlePeripheral.setWriteRequestCallback(_onWriteRequest);
      BlePeripheral.setReadRequestCallback(_onReadRequest);
      BlePeripheral.setConnectionStateChangeCallback(
          (String deviceId, bool connected) {
        debugPrint('BleGattService: Device $deviceId connected=$connected');
        if (!connected) {
          _handler = null;
          _incomingBuffer.clear();
          _activeDeviceId = null;
          debugPrint('BleGattService: Cleaned up after disconnect');
        }
      });

      // Start advertising: pass localName: null so Android does NOT attempt
      // to insert the device name into the 31-byte legacy advertisement packet,
      // which would cause ADVERTISE_FAILED_DATA_TOO_LARGE. The 128-bit UUID
      // alone fits comfortably within 31 bytes.
      await BlePeripheral.startAdvertising(
        services: [kJanusVaultBleServiceUuid],
        localName: null,
      );

      _isAdvertising = true;
      onStatusChanged?.call('Waiting for PC to connect via browser extension...');
      debugPrint('BleGattService: Advertising started with UUID $kJanusVaultBleServiceUuid');
    } catch (e) {
      String errMsg = e.toString();
      if (errMsg.contains('UnsupportedOperationException')) {
        errMsg = 'Bluetooth is turned off or unsupported on this device.';
      } else if (errMsg.contains('SecurityException')) {
        errMsg = 'Bluetooth permissions missing or denied.';
      }
      debugPrint('BleGattService: Failed to start advertising: $errMsg');
      _isAdvertising = false;
      onStatusChanged?.call(errMsg);
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
    _activeDeviceId = null;
    debugPrint('BleGattService: Advertising stopped');
  }

  // -------------------------------------------------------------------
  //  Incoming BLE write handling (central → peripheral)
  // -------------------------------------------------------------------

  /// Called when the BLE central (browser extension on PC) writes data
  /// to our sync characteristic. Data arrives chunked; we accumulate
  /// until we see the EOM marker, then process the complete JSON message.
  WriteRequestResult? _onWriteRequest(
      String deviceId, String characteristicId, int offset, Uint8List? value) {
    if (_activeDeviceId != null && _activeDeviceId != deviceId) {
      debugPrint('BleGattService: Automatically terminating stale connection $_activeDeviceId because another device ($deviceId) wrote data!');
      _handler = null;
      _incomingBuffer.clear();
      _activeDeviceId = deviceId;
    }
    _activeDeviceId ??= deviceId;

    if (value == null || value.isEmpty) return WriteRequestResult(status: 0);

    final chunk = utf8.decode(value, allowMalformed: true);
    debugPrint(
        'BleGattService: _onWriteRequest chunk length: ${chunk.length}, EOM: ${chunk.contains(kEomMarker)}');
    _incomingBuffer.write(chunk);
    final currentBuffer = _incomingBuffer.toString();

    if (currentBuffer.contains(kEomMarker)) {
      final parts = currentBuffer.split(kEomMarker);
      _incomingBuffer.clear();

      // If the last part is not complete (didn't end with EOM), keep it in buffer
      if (parts.last.isNotEmpty) {
        _incomingBuffer.write(parts.last);
      }

      for (var i = 0; i < parts.length - 1; i++) {
        final completeMessage = parts[i].trim();
        if (completeMessage.isNotEmpty) {
          _processIncomingMessage(completeMessage, deviceId);
        }
      }
    }
    return WriteRequestResult(status: 0); // GATT_SUCCESS
  }

  ReadRequestResult? _onReadRequest(
      String deviceId, String characteristicId, int offset, Uint8List? value) {
    return ReadRequestResult(value: Uint8List(0));
  }

  /// Process a complete JSON message received over BLE.
  Future<void> _processIncomingMessage(String rawJson, String deviceId) async {
    try {
      final message = SyncMessage.decode(rawJson);

      // Lazily create the handler on first message (connection start)
      _handler ??= SyncConnectionHandler(
        transport: _BleTransport(deviceId),
        vek:
            VaultSession.instance.isUnlocked ? VaultSession.instance.vek : null,
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
      if (currentHandler != null &&
          currentHandler.authenticated &&
          message.type == SyncMsgType.helloResponse) {
        currentHandler.sendDeviceInfo();
      }
    } catch (e) {
      debugPrint('BleGattService: Error processing message: $e');
      final errorMsg =
          SyncMessage(SyncMsgType.error, {'message': e.toString()});
      _sendChunkedNotification(deviceId, errorMsg.encode());
    }
  }

  // -------------------------------------------------------------------
  //  Outgoing BLE notification (peripheral → central)
  // -------------------------------------------------------------------

  /// Sends a message to the connected central by notifying on the sync
  /// characteristic. Large messages are automatically chunked.
  static Future<void> _sendChunkedNotification(
      String deviceId, String jsonMessage) async {
    debugPrint(
        'BleGattService: _sendChunkedNotification (len=${jsonMessage.length})');
    final data = '$jsonMessage$kEomMarker';
    final bytes = utf8.encode(data);

    for (var offset = 0; offset < bytes.length; offset += kBleChunkSize) {
      final end = (offset + kBleChunkSize > bytes.length)
          ? bytes.length
          : offset + kBleChunkSize;
      final chunk = Uint8List.fromList(bytes.sublist(offset, end));
      try {
        debugPrint(
            'BleGattService: Instructing native plugin to notify chunk len=${chunk.length} to deviceId=$deviceId');
        BlePeripheral.updateCharacteristic(
          characteristicId: kSyncCharacteristicUuid,
          value: chunk,
        );
        debugPrint(
            'BleGattService: updateCharacteristic returned successfully for chunk');

        // Critical: Provide generous spacing between Bluetooth notifications.
        // Windows and certain generic Android adapters will silently discard overlapping
        // synchronous notifications if pushed too quickly inside the same GATT interval.
        await Future.delayed(const Duration(milliseconds: 60));
      } catch (e) {
        debugPrint('BleGattService: FAILED to updateCharacteristic: $e');
      }
    }
  }
}

/// BLE transport implementation — sends messages as chunked
/// notifications on the GATT sync characteristic.
class _BleTransport implements SyncTransport {
  final String deviceId;

  _BleTransport(this.deviceId);

  final List<Future<void> Function()> _queue = [];
  bool _processing = false;

  @override
  void send(String jsonMessage) {
    // We queue writes asynchronously to guarantee they space out.
    // Synchronous calls to the Flutter bridge will instantly collide in the OS radio
    // and drop the notification packets entirely.
    _queue.add(() async {
      // Fast-bounce delay: Windows GATT stack often drops incoming notifications
      // if they arrive within ~100ms of a successful Write operation finishing.
      // E.g. PC Writes pairingRequest -> Flutter gets it -> Flutter Notifies instantly ->
      // PC drops it because its GATT client is still resolving the Write ACK.
      await Future.delayed(const Duration(milliseconds: 250));
      await BleGattService._sendChunkedNotification(deviceId, jsonMessage);
    });
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_processing) return;
    _processing = true;
    try {
      while (_queue.isNotEmpty) {
        final task = _queue.removeAt(0);
        try {
          await task();
        } catch (e) {
          debugPrint('BleGattService: Caught exception in queue task $e');
        }
      }
    } finally {
      _processing = false;
    }
  }

  @override
  Future<void> close() async {
    while (_queue.isNotEmpty || _processing) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    BleGattService.instance._handler = null;
    BleGattService.instance._incomingBuffer.clear();
    BleGattService.instance._activeDeviceId = null;
  }
}
