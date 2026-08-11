import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/backup/backup_service.dart';

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  String? _statusMessage;
  bool _busy = false;

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _statusMessage = 'Preparing backup...';
    });
    try {
      final bytes = Uint8List.fromList(ref.read(backupServiceProvider).exportBackupBytes());
      final fileName = 'janusvault_backup_${DateTime.now().millisecondsSinceEpoch}.pvault';
      setState(() => _statusMessage = 'Select location to save...');
      
      final savedPath = await FilePicker.platform.saveFile(
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['pvault'],
        bytes: bytes,
      );
      if (savedPath == null) {
        setState(() => _statusMessage = 'Export cancelled.');
      } else {
        setState(() => _statusMessage = 'Backup saved to: $savedPath');
      }
    } catch (e) {
      setState(() => _statusMessage = 'Export failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _restore(RestoreMode mode) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.single.path == null) return;

    setState(() {
      _busy = true;
      _statusMessage = 'Importing archive...';
    });
    
    try {
      await ref.read(backupServiceProvider).importBackup(result.files.single.path!, mode: mode);
      setState(() => _statusMessage = 'Restore complete (${mode.name} mode).');
    } catch (e) {
      setState(() => _statusMessage = 'Restore failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Restore', style: TextStyle(fontWeight: FontWeight.bold))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
                        child: Icon(Icons.download, color: Theme.of(context).colorScheme.primary),
                      ),
                      const SizedBox(width: 16),
                      Text('Export Vault', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Export an encrypted .pvault archive of your entire vault. This backup is fully offline and requires your biometrics/credentials to ever decrypt.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _busy ? null : _export,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Save Backup File', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(12)),
                        child: Icon(Icons.upload, color: Theme.of(context).colorScheme.secondary),
                      ),
                      const SizedBox(width: 16),
                      Text('Import Vault', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Restore from a pre-existing .pvault file you previously exported.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _restore(RestoreMode.replace),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                      side: BorderSide(color: Colors.red.withValues(alpha: 0.5)),
                      foregroundColor: Colors.red,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.warning_amber),
                    label: const Text('Replace existing vault entirely', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _restore(RestoreMode.merge),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.merge),
                    label: const Text('Merge into current vault', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ),
          if (_busy || _statusMessage != null) ...[
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  if (_busy) const CircularProgressIndicator(),
                  if (_busy) const SizedBox(height: 16),
                  if (_statusMessage != null) 
                    Text(
                      _statusMessage!, 
                      style: TextStyle(
                        color: _statusMessage!.contains('failed') ? Colors.red : Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
