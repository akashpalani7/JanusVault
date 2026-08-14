import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/models/vault_entry.dart';
import 'entry_editor_screen.dart';

class VaultListScreen extends ConsumerStatefulWidget {
  const VaultListScreen({super.key});

  @override
  ConsumerState<VaultListScreen> createState() => _VaultListScreenState();
}

class _VaultListScreenState extends ConsumerState<VaultListScreen> {
  bool _autoSynced = false;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  bool _isFabExtended = true;

  @override
  void initState() {
    super.initState();
    _startAutoSync();
    _scrollController.addListener(() {
      if (_scrollController.position.userScrollDirection == ScrollDirection.reverse) {
        if (_isFabExtended) setState(() => _isFabExtended = false);
      } else if (_scrollController.position.userScrollDirection == ScrollDirection.forward) {
        if (!_isFabExtended) setState(() => _isFabExtended = true);
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _startAutoSync() async {
    if (_autoSynced) return;
    _autoSynced = true;
    final syncService = ref.read(lanSyncServiceProvider);
    
    // Automatically make device visible for sync
    try {
      await syncService.startAdvertisingAndServing(deviceDisplayName: 'JanusVault');
    } catch (e) {
      debugPrint('Auto-sync server error: $e');
    }

    // Auto-discover and sync with peers
    try {
      final peers = await syncService.discoverPeers();
      for (final peer in peers) {
        try {
          await syncService.syncWithPeer(peer);
          if (mounted) {
            ref.invalidate(filteredEntriesProvider);
          }
        } catch (e) {
          debugPrint('Auto-sync peer error: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to sync with peer: $e'), duration: const Duration(seconds: 2)));
          }
        }
      }
    } catch (e) {
      debugPrint('Auto-sync discovery error: $e');
    }
  }

  Color _getHashColor(String text) {
    if (text.isEmpty) return Colors.grey;
    int hash = 0;
    for (var i = 0; i < text.length; i++) {
      hash = text.codeUnitAt(i) + ((hash << 5) - hash);
    }
    final hue = (hash % 360).abs().toDouble();
    return HSVColor.fromAHSV(1.0, hue, 0.6, 0.8).toColor();
  }



  @override
  Widget build(BuildContext context) {
    ref.watch(dbListenerProvider);
    final entriesAsync = ref.watch(filteredEntriesProvider);

    return Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SearchBar(
                controller: _searchController,
                leading: const Icon(Icons.search, color: Colors.grey),
                hintText: 'Search vault…',
                elevation: WidgetStateProperty.all(2),
                shape: WidgetStateProperty.all(
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 16)),
                onChanged: (value) => ref.read(searchQueryProvider.notifier).state = value,
                trailing: [
                  if (ref.watch(searchQueryProvider).isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        final FocusScopeNode currentFocus = FocusScope.of(context);
                        if (!currentFocus.hasPrimaryFocus) {
                          currentFocus.unfocus();
                        }
                        _searchController.clear();
                        ref.read(searchQueryProvider.notifier).state = '';
                      },
                    ),
                ],
              ),
            ),
            Expanded(
              child: entriesAsync.when(
                data: (entries) {
                  if (entries.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.vpn_key_off_outlined, size: 64, color: Colors.grey.withValues(alpha: 0.5)),
                          const SizedBox(height: 16),
                          const Text(
                            'No saved passwords yet.',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Tap + to add one.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView.separated(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(bottom: 80),
                    itemCount: entries.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 4),
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final color = _getHashColor(entry.websiteName);
                      final initial = entry.websiteName.isNotEmpty ? entry.websiteName[0].toUpperCase() : '?';
                      
                      return Dismissible(
                        key: Key(entry.uuid),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.redAccent,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        confirmDismiss: (direction) async {
                          return await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Move to Recycle Bin?'),
                              content: const Text('This entry will be moved to the recycle bin.'),
                              actions: [
                                TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
                                TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Move')),
                              ],
                            ),
                          ) ?? false;
                        },
                        onDismissed: (direction) async {
                          await ref.read(vaultRepositoryProvider).softDeleteEntry(entry.uuid);
                          ref.invalidate(filteredEntriesProvider);
                        },
                        child: Card(
                          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          elevation: 1,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => EntryEditorScreen(existing: entry)),
                            ).then((_) => ref.invalidate(filteredEntriesProvider)),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              child: Row(
                                children: [
                                  Hero(
                                    tag: 'icon_${entry.uuid}',
                                    child: Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [color.withValues(alpha: 0.7), color],
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Center(
                                        child: Text(
                                          initial,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          entry.websiteName.isEmpty ? 'Unknown' : entry.websiteName,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        if (entry.username.isNotEmpty) ...[
                                          const SizedBox(height: 4),
                                          Text(
                                            entry.username,
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: Theme.of(context).textTheme.bodySmall?.color?.withValues(alpha: 0.7) ?? Colors.grey,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.chevron_right, color: Colors.grey),
                                ],
                              ),
                            ),
                          ),
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
        Positioned(
          bottom: 16,
          right: 16,
          child: FloatingActionButton.extended(
            heroTag: null,
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EntryEditorScreen()));
              ref.invalidate(filteredEntriesProvider);
            },
            icon: const Icon(Icons.add),
            label: const Text('Add Login'),
            isExtended: _isFabExtended,
          ),
        ),
      ],
    );
  }
}
