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
    setState(() => _busy = true);
    try {
      final bytes = Uint8List.fromList(ref.read(backupServiceProvider).exportBackupBytes());
      final fileName = 'peervault_backup_${DateTime.now().millisecondsSinceEpoch}.pvault';
      // saveFile() opens the OS's native "Save as" picker (Storage Access
      // Framework on Android) so the user chooses a real, visible folder —
      // Documents, Downloads, Drive, etc. — rather than this silently
      // landing in the app's private data directory. Needs no storage
      // permission on any platform.
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

    setState(() => _busy = true);
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
      appBar: AppBar(title: const Text('Backup & Restore')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Export an encrypted .pvault archive of your entire vault.'),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.upload_file),
            label: const Text('Export backup'),
          ),
          const Divider(height: 32),
          const Text('Restore from a .pvault file:'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _restore(RestoreMode.replace),
            icon: const Icon(Icons.restore_page),
            label: const Text('Replace vault entirely'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _restore(RestoreMode.merge),
            icon: const Icon(Icons.merge),
            label: const Text('Merge into current vault'),
          ),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: CircularProgressIndicator()),
          if (_statusMessage != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_statusMessage!)),
        ],
      ),
    );
  }
}
