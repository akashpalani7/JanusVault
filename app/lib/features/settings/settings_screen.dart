import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/storage/vault_database.dart';
import '../../core/vault/vault_repository.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int _retentionDays = 30;
  bool _requireBiometricForReveal = true;
  bool _loaded = false;

  void _load() {
    final settings = VaultDatabase.instance.settings;
    if (settings != null) {
      setState(() {
        _retentionDays = settings.recycleBinRetentionDays;
        _requireBiometricForReveal = settings.requireBiometricForReveal;
        _loaded = true;
      });
    }
  }

  Future<void> _save() async {
    final settings = VaultDatabase.instance.settings;
    if (settings == null) return;
    settings.recycleBinRetentionDays = _retentionDays;
    settings.requireBiometricForReveal = _requireBiometricForReveal;
    await VaultDatabase.instance.saveSettings(settings);
  }
  
  Future<void> _handleImportCsv() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.single.path == null) return;

    final file = File(result.files.single.path!);
    final text = await file.readAsString();
    
    final rows = _parseCsv(text);
    if (rows.length < 2) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No password data found in file.")));
      return;
    }

    final header = rows[0].map((h) => h.trim().toLowerCase()).toList();
    final urlIdx = header.indexOf("url");
    final userIdx = header.indexOf("username");
    final passIdx = header.indexOf("password");
    final nameIdx = header.indexOf("name");

    if (urlIdx == -1 || userIdx == -1 || passIdx == -1) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Invalid CSV format (requires url, username, password columns).")));
      return;
    }

    final existingEntries = await VaultRepository.instance.getAllEntries();

    int saved = 0;
    int skipped = 0;
    
    for (int i = 1; i < rows.length; i++) {
      final cols = rows[i];
      final url = urlIdx < cols.length ? cols[urlIdx].trim() : '';
      final username = userIdx < cols.length ? cols[userIdx].trim() : '';
      final password = passIdx < cols.length ? cols[passIdx].trim() : '';
      
      if (url.isEmpty || password.isEmpty) {
        skipped++;
        continue;
      }
      
      String domain = url;
      try {
        if (!url.startsWith('http')) {
          domain = Uri.parse('https://$url').host;
        } else {
          domain = Uri.parse(url).host;
        }
        if (domain.isEmpty) domain = url;
      } catch (_) { }
      
      final websiteName = (nameIdx != -1 && nameIdx < cols.length && cols[nameIdx].trim().isNotEmpty) 
          ? cols[nameIdx].trim() 
          : domain;

      if (existingEntries.any((e) => (e.websiteName == websiteName || e.websiteUrl == url || e.websiteUrl == domain) && e.username == username)) {
        skipped++;
        continue;
      }

      await VaultRepository.instance.createEntry(
        websiteName: websiteName,
        websiteUrl: domain,
        username: username,
        password: password,
      );
      saved++;
    }

    if (mounted) {
      if (saved > 0) {
        ref.invalidate(filteredEntriesProvider);
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Imported $saved entries, skipped $skipped.")));
    }
  }

  List<List<String>> _parseCsv(String text) {
    final List<List<String>> rows = [];
    List<String> row = [];
    String field = "";
    bool inQuotes = false;

    for (int i = 0; i < text.length; i++) {
      final String c = text[i];
      if (inQuotes) {
        if (c == '"' && i + 1 < text.length && text[i + 1] == '"') {
          field += '"';
          i++;
        } else if (c == '"') {
          inQuotes = false;
        } else {
          field += c;
        }
      } else if (c == '"') {
        inQuotes = true;
      } else if (c == ',') {
        row.add(field);
        field = "";
      } else if (c == '\n' || c == '\r') {
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(field);
        rows.add(row);
        row = [];
        field = "";
      } else {
        field += c;
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field);
      rows.add(row);
    }
    return rows.where((r) => r.any((cell) => cell.trim().isNotEmpty)).toList();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Require biometrics to reveal a password'),
            value: _requireBiometricForReveal,
            onChanged: (v) {
              setState(() => _requireBiometricForReveal = v);
              _save();
            },
          ),
          ListTile(
            title: const Text('Recycle Bin retention'),
            subtitle: Text('$_retentionDays days'),
            trailing: DropdownButton<int>(
              value: _retentionDays,
              items: const [7, 14, 30, 60, 90]
                  .map((d) => DropdownMenuItem(value: d, child: Text('$d days')))
                  .toList(),
              onChanged: (v) async {
                if (v == null || v == _retentionDays) return;

                if (v < _retentionDays) {
                  final cutoff = DateTime.now().toUtc().subtract(Duration(days: v));
                  final all = await VaultRepository.instance.getAllEntries(includeDeleted: true);
                  final affectedEntries = all.where((e) => e.deleted && e.lastUpdated.isBefore(cutoff)).toList();

                  if (context.mounted) {
                    late String dialogTitle;
                    late String dialogContent;
                    late String btnLabel;

                    if (affectedEntries.isNotEmpty) {
                      final names = affectedEntries.map((e) => e.websiteName).take(5).join(', ');
                      final more = affectedEntries.length > 5 ? ' and ${affectedEntries.length - 5} more' : '';
                      dialogTitle = 'Warning: Immediate Deletion';
                      dialogContent = 'Decreasing the retention to $v days will instantly and permanently erase ${affectedEntries.length} items currently in the Recycle Bin:\n\n$names$more\n\nAre you sure you want to proceed?';
                      btnLabel = 'Apply and Delete';
                    } else {
                      dialogTitle = 'Confirm Retention Decrease';
                      dialogContent = 'Are you sure you want to decrease the time deleted passwords are kept to $v days? Future and existing deleted items will be purged sooner.';
                      btnLabel = 'Apply';
                    }

                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: Text(dialogTitle),
                        content: Text(dialogContent),
                        actions: [
                          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.of(c).pop(true), child: Text(btnLabel)),
                        ],
                      ),
                    );

                    if (confirm != true) return;
                  }
                }

                setState(() => _retentionDays = v);
                await _save();
                
                final purged = await VaultRepository.instance.purgeExpiredRecycleBin(retentionDays: v);
                if (purged > 0 && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Automatically purged $purged overdue entries.')));
                }
              },
            ),
          ),
          ListTile(
            title: const Text('Purge expired Recycle Bin items now'),
            trailing: const Icon(Icons.delete_sweep_outlined),
            onTap: () async {
              final purged = await VaultRepository.instance.purgeExpiredRecycleBin(retentionDays: _retentionDays);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Purged $purged entries')));
              }
            },
          ),
          ListTile(
            title: const Text('Import from CSV'),
            subtitle: const Text('Restore passwords exported from Chrome, Brave, or Firefox'),
            trailing: const Icon(Icons.upload_file_outlined),
            onTap: _handleImportCsv,
          ),
        ],
      ),
    );
  }
}
