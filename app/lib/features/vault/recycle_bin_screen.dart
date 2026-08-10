import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app_providers.dart';

class RecycleBinScreen extends ConsumerWidget {
  const RecycleBinScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(dbListenerProvider);
    final entriesAsync = ref.watch(deletedEntriesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Recycle Bin')),
      body: entriesAsync.when(
        data: (entries) {
          if (entries.isEmpty) {
            return const Center(child: Text('Recycle bin is empty.'));
          }
          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(entry.websiteName),
                subtitle: Text(entry.username),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.restore),
                      tooltip: 'Restore',
                      onPressed: () async {
                        await ref.read(vaultRepositoryProvider).restoreEntry(entry.uuid);
                        ref.invalidate(deletedEntriesProvider);
                        ref.invalidate(filteredEntriesProvider);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_forever, color: Colors.red),
                      tooltip: 'Delete permanently',
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Delete permanently?'),
                            content: const Text('This entry will be permanently removed. This action cannot be undone.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Erase')),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          await ref.read(vaultRepositoryProvider).hardDeleteEntry(entry.uuid);
                          ref.invalidate(deletedEntriesProvider);
                        }
                      },
                    ),
                  ],
                ),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, st) => Center(child: Text('Error: $err')),
      ),
    );
  }
}
