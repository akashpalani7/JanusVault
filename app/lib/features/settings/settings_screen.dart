import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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


  @override
  void initState() {
    super.initState();
    _load();
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold))),
      body: ListView(
        children: [
          _buildSectionHeader('Security'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: SwitchListTile(
              secondary: const Icon(Icons.fingerprint),
              title: const Text('Require biometrics'),
              subtitle: const Text('Ask for fingerprint before revealing passwords'),
              value: _requireBiometricForReveal,
              onChanged: (v) {
                setState(() => _requireBiometricForReveal = v);
                _save();
              },
            ),
          ),
          
          _buildSectionHeader('Data Management'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.auto_delete_outlined),
                  title: const Text('Recycle Bin retention'),
                  subtitle: Text('Items deleted over $_retentionDays days ago are purged automatically'),
                  trailing: DropdownButton<int>(
                    value: _retentionDays,
                    underline: const SizedBox.shrink(),
                    borderRadius: BorderRadius.circular(12),
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
                    items: const [
                      DropdownMenuItem(value: 7, child: Text('7 days')),
                      DropdownMenuItem(value: 14, child: Text('14 days')),
                      DropdownMenuItem(value: 30, child: Text('30 days')),
                      DropdownMenuItem(value: 60, child: Text('60 days')),
                      DropdownMenuItem(value: 90, child: Text('90 days')),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined, color: Colors.red),
                  title: const Text('Purge expired items now'),
                  subtitle: const Text('Manually clean up Recycle Bin'),
                  onTap: () async {
                    final purged = await VaultRepository.instance.purgeExpiredRecycleBin(retentionDays: _retentionDays);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Purged $purged entries')));
                    }
                  },
                ),

              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
