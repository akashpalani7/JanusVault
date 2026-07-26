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
              onChanged: (v) {
                if (v == null) return;
                setState(() => _retentionDays = v);
                _save();
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
        ],
      ),
    );
  }
}
