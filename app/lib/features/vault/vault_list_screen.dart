import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/models/vault_entry.dart';
import '../../core/vault/vault_session.dart';
import '../backup/backup_screen.dart';
import '../devices/devices_screen.dart';
import '../recovery/recovery_screen.dart';
import '../settings/settings_screen.dart';
import '../sync/sync_screen.dart';
import 'entry_editor_screen.dart';

class VaultListScreen extends ConsumerStatefulWidget {
  const VaultListScreen({super.key});

  @override
  ConsumerState<VaultListScreen> createState() => _VaultListScreenState();
}

class _VaultListScreenState extends ConsumerState<VaultListScreen> {
  bool _autoSynced = false;

  @override
  void initState() {
    super.initState();
    _startAutoSync();
  }

  Future<void> _startAutoSync() async {
    if (_autoSynced) return;
    _autoSynced = true;
    final syncService = ref.read(lanSyncServiceProvider);
    
    // Automatically make device visible for sync
    try {
      await syncService.startAdvertisingAndServing(deviceDisplayName: 'PeerVault');
    } catch (_) {}

    // Auto-discover and sync with peers
    try {
      final peers = await syncService.discoverPeers();
      for (final peer in peers) {
        try {
          await syncService.syncWithPeer(peer);
          if (mounted) {
            ref.invalidate(filteredEntriesProvider);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(filteredEntriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('PeerVault'),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Sync devices',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SyncScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.devices_other),
            tooltip: 'Trusted devices',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DevicesScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.shield_outlined),
            tooltip: 'Recovery Kit',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RecoveryScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.lock),
            tooltip: 'Lock vault',
            onPressed: () {
              VaultSession.instance.lock();
              ref.read(vaultUnlockedProvider.notifier).state = false;
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search vault…',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => ref.read(searchQueryProvider.notifier).state = value,
            ),
          ),
          Expanded(
            child: entriesAsync.when(
              data: (entries) {
                if (entries.isEmpty) {
                  return const Center(child: Text('No saved passwords yet. Tap + to add one.'));
                }
                return ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return ListTile(
                      leading: CircleAvatar(child: Text(entry.websiteName.isNotEmpty ? entry.websiteName[0].toUpperCase() : '?')),
                      title: Text(entry.websiteName),
                      subtitle: Text(entry.username),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => EntryEditorScreen(existing: entry)),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await ref.read(vaultRepositoryProvider).softDeleteEntry(entry.uuid);
                          ref.invalidate(filteredEntriesProvider);
                        },
                      ),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, st) => Center(child: Text('Error: $err')),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EntryEditorScreen()));
          ref.invalidate(filteredEntriesProvider);
        },
        child: const Icon(Icons.add),
      ),
      bottomNavigationBar: BottomAppBar(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BackupScreen())),
              icon: const Icon(Icons.import_export),
              label: const Text('Backup / Restore'),
            ),
          ],
        ),
      ),
    );
  }
}
