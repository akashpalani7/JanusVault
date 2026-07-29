import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app_providers.dart';
import '../../core/sync/lan_sync_service.dart';

class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Sync Vault'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.wifi), text: 'WiFi / LAN'),
              Tab(icon: Icon(Icons.bluetooth), text: 'Bluetooth / PC'),
              Tab(icon: Icon(Icons.sensors), text: 'Nearby / Android'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _LanSyncTab(),
            _BleGattTab(),
            _NearbySyncTab(),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------
//  WIFI (LAN) TAB
// -------------------------------------------------------------
class _LanSyncTab extends ConsumerStatefulWidget {
  const _LanSyncTab();
  @override
  ConsumerState<_LanSyncTab> createState() => _LanSyncTabState();
}

class _LanSyncTabState extends ConsumerState<_LanSyncTab> {
  String? _selfAddress;
  bool _hosting = false;
  List<DiscoveredPeer> _peers = [];
  bool _scanning = false;
  String? _status;
  final _manualHostCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSelfAddress();
  }

  Future<void> _loadSelfAddress() async {
    final service = ref.read(lanSyncServiceProvider);
    final ip = await service.getSelfLanAddress();
    setState(() => _selfAddress = ip);
    if (!_hosting) {
      try {
        await service.startAdvertisingAndServing(
            deviceDisplayName: 'PeerVault');
        if (mounted) setState(() => _hosting = true);
      } catch (_) {}
    }
  }

  Future<void> _toggleHosting(bool value) async {
    final service = ref.read(lanSyncServiceProvider);
    if (!value) {
      await service.stopAdvertisingAndServing();
      setState(() => _hosting = false);
    } else {
      await service.startAdvertisingAndServing(deviceDisplayName: 'PeerVault');
      setState(() => _hosting = true);
    }
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _status = null;
    });
    try {
      final peers = await ref.read(lanSyncServiceProvider).discoverPeers();
      setState(() => _peers = peers);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _syncWith(DiscoveredPeer peer) async {
    setState(() => _status = 'Syncing with ${peer.name}…');
    try {
      await ref.read(lanSyncServiceProvider).syncWithPeer(peer);
      if (mounted) setState(() => _status = 'Synced with ${peer.name}');
    } catch (e) {
      if (mounted) setState(() => _status = 'Sync failed: $e');
    }
  }

  Future<void> _syncByManualHost() async {
    final input = _manualHostCtrl.text.trim();
    if (input.isEmpty) return;
    final parts = input.split(':');
    final host = parts.first;
    final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 51827 : 51827;
    setState(() => _status = 'Syncing with $host:$port…');
    try {
      await ref.read(lanSyncServiceProvider).syncWithHost(host, port);
      if (mounted) setState(() => _status = 'Synced with $host:$port');
    } catch (e) {
      if (mounted) setState(() => _status = 'Sync failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          title: const Text('Make this device discoverable on WiFi'),
          subtitle: Text(_selfAddress == null
              ? 'Connect to WiFi or hotspot first'
              : 'IP Address: $_selfAddress:${ref.read(lanSyncServiceProvider).boundPort}'),
          value: _hosting,
          onChanged: _toggleHosting,
        ),
        const Divider(height: 32),
        Row(
          children: [
            Expanded(
              child: Text('Discovered Devices',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _scanning ? null : _scan),
          ],
        ),
        if (_scanning) const LinearProgressIndicator(),
        ..._peers.map((p) => ListTile(
              leading: const Icon(Icons.computer),
              title: Text(p.name),
              subtitle: Text('${p.host}:${p.port}'),
              trailing: FilledButton(
                  onPressed: () => _syncWith(p), child: const Text('Sync')),
            )),
        if (_peers.isEmpty && !_scanning)
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
                'No devices found on LAN. Ensure both devices are on the same network or hotspot.'),
          ),
        const Divider(height: 32),
        Text('Connect manually by IP',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _manualHostCtrl,
          decoration: const InputDecoration(
            hintText: '192.168.x.x:51827',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _syncByManualHost,
          child: const Text('Connect'),
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(_status!,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.blue)),
          ),
      ],
    );
  }
}

// -------------------------------------------------------------
//  BLE GATT (PC ↔ MOBILE) TAB
// -------------------------------------------------------------
class _BleGattTab extends ConsumerStatefulWidget {
  const _BleGattTab();
  @override
  ConsumerState<_BleGattTab> createState() => _BleGattTabState();
}

class _BleGattTabState extends ConsumerState<_BleGattTab> {
  bool _hosting = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _hosting = ref.read(bleGattServiceProvider).isAdvertising;
  }

  Future<bool> _checkPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ].request();
    // We rely on the native plugin's SecurityException to catch actual denials.
    // This allows Android 11 and below devices to proceed even when API 31+ permissions are instantly denied.
    return true;
  }

  Future<void> _toggleHosting(bool value) async {
    final service = ref.read(bleGattServiceProvider);
    if (value) {
      setState(() => _status = 'Requesting permissions...');
      final granted = await _checkPermissions();
      if (!granted) {
        if (mounted)
          setState(() {
            _status = 'Bluetooth permissions denied';
            _hosting = false;
          });
        return;
      }
      setState(() => _status = 'Starting BLE...');
      try {
        await service.startAdvertising(deviceDisplayName: 'Phone');
        if (mounted)
          setState(() {
            _hosting = service.isAdvertising;
            _status = _hosting
                ? 'Waiting for PC to connect via browser extension...'
                : 'Failed to start BLE';
          });
      } catch (e) {
        if (mounted)
          setState(() {
            _hosting = false;
            _status = e.toString().replaceAll('Exception: ', '');
          });
      }
    } else {
      await service.stopAdvertising();
      setState(() {
        _hosting = false;
        _status = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isFuchsia) return const Center(child: Text('Unsupported'));

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
              'Bluetooth Sync is designed for securely syncing with the desktop browser extension without needing WiFi or an internet connection.'),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('Advertise via Bluetooth (GATT)'),
            subtitle: const Text(
                'Turn this on and click "Sync via Bluetooth" in the browser extension popup.'),
            value: _hosting,
            onChanged: _toggleHosting,
          ),
          const SizedBox(height: 24),
          if (_status.isNotEmpty)
            Expanded(
              child: SingleChildScrollView(
                child: Center(
                  child: Text(
                    _status,
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------
//  NEARBY CONNECTIONS (ANDROID ↔ ANDROID) TAB
// -------------------------------------------------------------
class _NearbySyncTab extends ConsumerStatefulWidget {
  const _NearbySyncTab();
  @override
  ConsumerState<_NearbySyncTab> createState() => _NearbySyncTabState();
}

class _NearbySyncTabState extends ConsumerState<_NearbySyncTab> {
  bool _advertising = false;
  bool _discovering = false;
  String _status = '';

  // We store a list of Maps since we need both id and name
  List<Map<String, String>> _foundPeers = [];

  @override
  void initState() {
    super.initState();
    final service = ref.read(nearbySyncServiceProvider);
    _advertising = service.isAdvertising;
    _discovering = service.isDiscovering;

    service.onStatusChanged = (msg) {
      if (mounted) setState(() => _status = msg);
    };
    service.onPeerDiscovered = (id, name) {
      if (mounted)
        setState(() {
          _foundPeers.removeWhere((p) => p['id'] == id);
          _foundPeers.add({'id': id, 'name': name});
        });
    };
    service.onPeerLost = (id) {
      if (mounted)
        setState(() {
          _foundPeers.removeWhere((p) => p['id'] == id);
        });
    };
  }

  Future<bool> _checkPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.nearbyWifiDevices,
      Permission.location,
    ].request();
    return true; // nearby_connections plugin often triggers its own prompts if needed, but we try our best.
  }

  Future<void> _toggleAdvertising(bool value) async {
    final service = ref.read(nearbySyncServiceProvider);
    if (value) {
      await _checkPermissions();
      try {
        await service.startAdvertising(deviceDisplayName: 'Android');
        if (mounted) setState(() => _advertising = service.isAdvertising);
      } catch (e) {
        if (mounted)
          setState(() => _status = e.toString().replaceAll('Exception: ', ''));
      }
    } else {
      await service.stopAdvertising();
      if (mounted) setState(() => _advertising = false);
    }
  }

  Future<void> _toggleDiscovering(bool value) async {
    final service = ref.read(nearbySyncServiceProvider);
    if (value) {
      await _checkPermissions();
      try {
        await service.startDiscovery();
        if (mounted) setState(() => _discovering = service.isDiscovering);
      } catch (e) {
        if (mounted)
          setState(() => _status = e.toString().replaceAll('Exception: ', ''));
      }
    } else {
      await service.stopDiscovery();
      if (mounted) {
        setState(() {
          _discovering = false;
          _foundPeers.clear();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid)
      return const Center(child: Text('Only available on Android'));
    final service = ref.read(nearbySyncServiceProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
            'Use Nearby Connections to sync between two Android phones automatically, upgrading to WiFi Direct for speed.'),
        const SizedBox(height: 16),
        SwitchListTile(
          title: const Text('Make this device discoverable'),
          subtitle: const Text('Allow other Android devices to find you'),
          value: _advertising,
          onChanged: _toggleAdvertising,
        ),
        SwitchListTile(
          title: const Text('Scan for other devices'),
          subtitle: const Text('Find nearby Android devices running PeerVault'),
          value: _discovering,
          onChanged: _toggleDiscovering,
        ),
        const Divider(height: 32),
        if (_status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(_status,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.blue)),
          ),
        if (_foundPeers.isNotEmpty)
          ..._foundPeers.map((p) => ListTile(
                leading: const Icon(Icons.phone_android),
                title: Text(p['name']!),
                trailing: FilledButton(
                    onPressed: () =>
                        service.connectToPeer(p['id']!, p['name']!),
                    child: const Text('Sync')),
              )),
        if (_discovering && _foundPeers.isEmpty)
          const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}
