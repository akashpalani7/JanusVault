import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app_providers.dart';
import '../../core/sync/lan_sync_service.dart';

Widget _buildStatusChip(String? status) {
  if (status == null || status.isEmpty) return const SizedBox.shrink();
  Color color = Colors.amber;
  IconData icon = Icons.sync;
  final s = status.toLowerCase();
  
  if (s.contains('failed') || s.contains('denied') || s.contains('unsupported') || s.contains('error')) {
    color = Colors.red;
    icon = Icons.error_outline;
  } else if (s.contains('synced') || s.contains('success')) {
    color = Colors.green;
    icon = Icons.check_circle_outline;
  } else if (s.contains('waiting') || s.contains('starting')) {
    color = Colors.blue;
    icon = Icons.hourglass_empty;
  }
  
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Flexible(child: Text(status, style: TextStyle(color: color, fontWeight: FontWeight.w900))),
      ],
    ),
  );
}

class SyncScreen extends ConsumerWidget {
  final TabController? controller;
  
  const SyncScreen({super.key, this.controller});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TabBarView(
      controller: controller,
      children: const [
        _LanSyncTab(),
        _BleGattTab(),
        _NearbySyncTab(),
      ],
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

class _LanSyncTabState extends ConsumerState<_LanSyncTab> with AutomaticKeepAliveClientMixin {
  String? _selfAddress;
  bool _hosting = false;
  List<DiscoveredPeer> _peers = [];
  bool _scanning = false;
  String? _status;
  final _manualHostCtrl = TextEditingController();

  @override
  bool get wantKeepAlive => true;

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
        await service.startAdvertisingAndServing(deviceDisplayName: 'JanusVault');
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
      await service.startAdvertisingAndServing(deviceDisplayName: 'JanusVault');
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

  Future<void> _syncAll() async {
    setState(() {
      _scanning = true;
      _status = 'Discovering and syncing with all...';
    });
    try {
      final results = await ref.read(lanSyncServiceProvider).syncWithAllDiscoveredPeers();
      if (mounted) {
        setState(() {
          _status = 'Multi-sync complete. ${results.values.where((v) => v == 'Success').length}/${results.length} succeeded.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Multi-sync failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              SwitchListTile(
                secondary: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, shape: BoxShape.circle),
                  child: Icon(Icons.wifi_tethering, color: Theme.of(context).colorScheme.onPrimaryContainer),
                ),
                title: const Text('Make discoverable on WiFi', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(_selfAddress == null
                    ? 'Connect to WiFi or hotspot first'
                    : 'Enter on PC: $_selfAddress:${ref.read(lanSyncServiceProvider).boundPort ?? 51827}'),
                value: _hosting,
                onChanged: _toggleHosting,
              ),
            ],
          ),
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Center(child: _buildStatusChip(_status)),
          ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Discovered Devices', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
                    Row(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.sync),
                          label: const Text('Sync All'),
                          onPressed: _scanning ? null : _syncAll,
                        ),
                        IconButton(icon: const Icon(Icons.refresh), onPressed: _scanning ? null : _scan),
                      ],
                    ),
                  ],
                ),
              ),
              if (_scanning) const LinearProgressIndicator(),
              if (_peers.isEmpty && !_scanning)
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Text('No devices found on LAN. Ensure both devices are on the same network or hotspot.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
                ),
              ..._peers.map((p) => ListTile(
                leading: const CircleAvatar(child: Icon(Icons.computer)),
                title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('${p.host}:${p.port}'),
                trailing: FilledButton.icon(
                  icon: const Icon(Icons.sync),
                  label: const Text('Sync'),
                  onPressed: () => _syncWith(p),
                ),
              )),
              const SizedBox(height: 8),
            ],
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Connect manually by IP', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
                const SizedBox(height: 16),
                TextField(
                  controller: _manualHostCtrl,
                  decoration: InputDecoration(
                    hintText: '192.168.x.x:51827',
                    prefixIcon: const Icon(Icons.private_connectivity),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _syncByManualHost,
                  icon: const Icon(Icons.power),
                  label: const Text('Connect'),
                ),
              ],
            ),
          ),
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

class _BleGattTabState extends ConsumerState<_BleGattTab> with AutomaticKeepAliveClientMixin {
  bool _hosting = false;
  String _status = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final service = ref.read(bleGattServiceProvider);
    _hosting = service.isAdvertising;
    service.onStatusChanged = (status) {
      if (mounted) {
        setState(() {
          _status = status;
          _hosting = ref.read(bleGattServiceProvider).isAdvertising;
        });
      }
    };
  }

  Future<bool> _checkPermissions() async {
    final statuses = await [
      Permission.bluetooth,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    if (statuses[Permission.bluetoothAdvertise]?.isPermanentlyDenied == true ||
        statuses[Permission.bluetoothConnect]?.isPermanentlyDenied == true) {
      return false;
    }
    return true;
  }

  Future<void> _toggleHosting(bool value) async {
    final service = ref.read(bleGattServiceProvider);
    if (value) {
      setState(() => _status = 'Requesting permissions...');
      final granted = await _checkPermissions();
      if (!granted) {
        if (mounted) {
          setState(() {
            _status = 'Bluetooth permissions denied';
            _hosting = false;
          });
        }
        return;
      }
      setState(() => _status = 'Starting BLE...');
      try {
        await service.startAdvertising(deviceDisplayName: 'Phone');
        if (mounted) {
          setState(() {
            _hosting = service.isAdvertising;
            _status = _hosting ? 'Waiting for PC to connect via browser extension...' : 'Failed to start BLE';
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _hosting = false;
            _status = e.toString().replaceAll('Exception: ', '');
          });
        }
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
    super.build(context);
    if (Platform.isFuchsia) return const Center(child: Text('Unsupported'));

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Text(
            'Bluetooth Sync is designed for securely syncing with the desktop browser extension without needing WiFi or an internet connection.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              SwitchListTile(
                secondary: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, shape: BoxShape.circle),
                  child: Icon(Icons.bluetooth_audio, color: Theme.of(context).colorScheme.onPrimaryContainer),
                ),
                title: const Text('Advertise via Bluetooth', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text('Turn this on and click "Sync via Bluetooth" in the browser extension.'),
                value: _hosting,
                onChanged: _toggleHosting,
              ),
            ],
          ),
        ),
        if (_status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Center(child: _buildStatusChip(_status)),
          ),
      ],
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

class _NearbySyncTabState extends ConsumerState<_NearbySyncTab> with AutomaticKeepAliveClientMixin {
  bool _advertising = false;
  bool _discovering = false;
  String _status = '';
  final List<Map<String, String>> _foundPeers = [];

  @override
  bool get wantKeepAlive => true;

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
      if (mounted) {
        setState(() {
          _foundPeers.removeWhere((p) => p['id'] == id);
          _foundPeers.add({'id': id, 'name': name});
        });
      }
    };
    service.onPeerLost = (id) {
      if (mounted) {
        setState(() {
          _foundPeers.removeWhere((p) => p['id'] == id);
        });
      }
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
    return true;
  }

  Future<void> _toggleAdvertising(bool value) async {
    final service = ref.read(nearbySyncServiceProvider);
    if (value) {
      await _checkPermissions();
      try {
        await service.startAdvertising(deviceDisplayName: 'Android');
        if (mounted) setState(() => _advertising = service.isAdvertising);
      } catch (e) {
        if (mounted) setState(() => _status = e.toString().replaceAll('Exception: ', ''));
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
        if (mounted) setState(() => _status = e.toString().replaceAll('Exception: ', ''));
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
    super.build(context);
    if (!Platform.isAndroid) return const Center(child: Text('Only available on Android'));
    final service = ref.read(nearbySyncServiceProvider);

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Text(
            'Use Nearby Connections to sync between two Android phones automatically, upgrading to WiFi Direct for speed.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              SwitchListTile(
                secondary: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, shape: BoxShape.circle),
                  child: Icon(Icons.podcasts, color: Theme.of(context).colorScheme.onPrimaryContainer),
                ),
                title: const Text('Make discoverable', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text('Allow other Android devices to find you'),
                value: _advertising,
                onChanged: _toggleAdvertising,
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondaryContainer, shape: BoxShape.circle),
                  child: Icon(Icons.radar, color: Theme.of(context).colorScheme.onSecondaryContainer),
                ),
                title: const Text('Scan for peers', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text('Find nearby devices running JanusVault'),
                value: _discovering,
                onChanged: _toggleDiscovering,
              ),
            ],
          ),
        ),
        if (_status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Center(child: _buildStatusChip(_status)),
          ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_foundPeers.isNotEmpty || _discovering) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text('Found Devices', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
                ),
                if (_discovering && _foundPeers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24.0),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ..._foundPeers.map((p) => ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.phone_android)),
                  title: Text(p['name']!, style: const TextStyle(fontWeight: FontWeight.bold)),
                  trailing: FilledButton.icon(
                    icon: const Icon(Icons.sync),
                    label: const Text('Sync'),
                    onPressed: () => service.connectToPeer(p['id']!, p['name']!),
                  ),
                )),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
