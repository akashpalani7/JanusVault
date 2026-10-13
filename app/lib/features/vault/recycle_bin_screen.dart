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
      appBar: AppBar(
        title: const Text('Recycle Bin', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          entriesAsync.maybeWhen(
            data: (entries) {
              if (entries.isEmpty) return const SizedBox.shrink();
              return PopupMenuButton<String>(
                onSelected: (value) async {
                  final repo = ref.read(vaultRepositoryProvider);
                  if (value == 'restore') {
                    for (final e in entries) {
                      await repo.restoreEntry(e.uuid);
                    }
                  } else if (value == 'empty') {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('Empty Recycle Bin?'),
                        content: const Text('All items will be permanently erased. This cannot be undone.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: Colors.red),
                            onPressed: () => Navigator.of(c).pop(true), 
                            child: const Text('Empty All')
                          ),
                        ],
                      ),
                    ) ?? false;
                    if (confirm) {
                      for (final e in entries) {
                        await repo.hardDeleteEntry(e.uuid);
                      }
                    }
                  }
                  ref.invalidate(deletedEntriesProvider);
                  ref.invalidate(filteredEntriesProvider);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'restore', child: Row(children: [Icon(Icons.restore), SizedBox(width: 8), Text('Restore all')])),
                  PopupMenuItem(value: 'empty', child: Row(children: [Icon(Icons.delete_forever, color: Colors.red), SizedBox(width: 8), Text('Empty all', style: TextStyle(color: Colors.red))])),
                ],
              );
            },
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: entriesAsync.when(
        data: (entries) {
          if (entries.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.delete_outline, size: 64, color: Colors.grey.withValues(alpha: 0.5)),
                  const SizedBox(height: 16),
                  const Text('Recycle bin is empty', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: entries.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (context, index) {
              final entry = entries[index];
              return Dismissible(
                key: Key(entry.uuid),
                direction: DismissDirection.horizontal,
                background: Container(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.only(left: 20),
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(16)),
                  child: const Icon(Icons.restore, color: Colors.white),
                ),
                secondaryBackground: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(16)),
                  child: const Icon(Icons.delete_forever, color: Colors.white),
                ),
                confirmDismiss: (direction) async {
                  if (direction == DismissDirection.endToStart) {
                    return await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('Delete permanently?'),
                        content: const Text('This entry will be permanently removed. This action cannot be undone.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: Colors.red),
                            onPressed: () => Navigator.of(c).pop(true), 
                            child: const Text('Erase')
                          ),
                        ],
                      ),
                    );
                  } else {
                    return true;
                  }
                },
                onDismissed: (direction) async {
                  if (direction == DismissDirection.startToEnd) {
                    await ref.read(vaultRepositoryProvider).restoreEntry(entry.uuid);
                  } else {
                    await ref.read(vaultRepositoryProvider).hardDeleteEntry(entry.uuid);
                  }
                  ref.invalidate(deletedEntriesProvider);
                  ref.invalidate(filteredEntriesProvider);
                },
                child: Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  elevation: 0,
                  color: Theme.of(context).cardTheme.color?.withValues(alpha: 0.5) ?? Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.1)),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: CircleAvatar(
                      backgroundColor: Colors.grey.withValues(alpha: 0.2),
                      foregroundColor: Colors.grey,
                      child: Text(entry.websiteName.isNotEmpty ? entry.websiteName[0].toUpperCase() : '?'),
                    ),
                    title: Text(entry.websiteName, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                    subtitle: Text(entry.username, style: const TextStyle(color: Colors.grey)),
                    trailing: const Icon(Icons.swipe, color: Colors.grey, size: 20),
                  ),
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
