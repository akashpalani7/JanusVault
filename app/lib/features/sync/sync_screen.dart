import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/sync/lan_sync_service.dart';

class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
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
    final ip = await ref.read(lanSyncServiceProvider).getSelfLanAddress();
    setState(() => _selfAddress = ip);
  }

  Future<void> _toggleHosting() async {
    final service = ref.read(lanSyncServiceProvider);
    if (_hosting) {
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
      setState(() => _scanning = false);
    }
  }

  Future<void> _syncWith(DiscoveredPeer peer) async {
    setState(() => _status = 'Syncing with ${peer.name}…');
    try {
      await ref.read(lanSyncServiceProvider).syncWithPeer(peer);
      setState(() => _status = 'Synced with ${peer.name}');
      ref.invalidate(filteredEntriesProvider);
    } catch (e) {
      setState(() => _status = 'Sync failed: $e');
    }
  }

  Future<void> _syncByManualHost() async {
    final input = _manualHostCtrl.text.trim();
    if (input.isEmpty) return;
    final parts = input.split(':');
    final host = parts.first;
    final port = parts.length > 1 ? int.tryParse(parts[1]) ?? kSyncPort : kSyncPort;
    setState(() => _status = 'Syncing with $host:$port…');
    try {
      await ref.read(lanSyncServiceProvider).syncWithHost(host, port);
      setState(() => _status = 'Synced with $host:$port');
      ref.invalidate(filteredEntriesProvider);
    } catch (e) {
      setState(() => _status = 'Sync failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sync devices')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('This device', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(_selfAddress == null
                      ? 'Not connected to a network'
                      : 'Address: $_selfAddress:$kSyncPort  (works over WiFi or a phone hotspot)'),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Make this device visible for sync'),
                    value: _hosting,
                    onChanged: (_) => _toggleHosting(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: Text('Nearby devices', style: Theme.of(context).textTheme.titleMedium)),
              IconButton(icon: const Icon(Icons.refresh), onPressed: _scanning ? null : _scan),
            ],
          ),
          if (_scanning) const LinearProgressIndicator(),
          ..._peers.map((p) => ListTile(
                leading: const Icon(Icons.smartphone),
                title: Text(p.name),
                subtitle: Text('${p.host}:${p.port}'),
                trailing: FilledButton(onPressed: () => _syncWith(p), child: const Text('Sync')),
              )),
          const Divider(height: 32),
          Text('Connect by IP manually', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('Use this on a hotspot/network where automatic discovery is blocked, '
              'or when pairing with the browser extension (type the phone\'s address shown above into the extension popup).'),
          const SizedBox(height: 8),
          TextField(
            controller: _manualHostCtrl,
            decoration: const InputDecoration(hintText: '192.168.x.x:51827', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _syncByManualHost, child: const Text('Sync now')),
          if (_status != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_status!)),
        ],
      ),
    );
  }
}
