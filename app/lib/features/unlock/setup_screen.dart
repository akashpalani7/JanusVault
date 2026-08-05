import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/models/trusted_device.dart';
import '../recovery/recovery_screen.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  bool _creating = false;

  Future<void> _createVault() async {
    setState(() => _creating = true);
    try {
      await ref.read(deviceManagerProvider).initializeFirstDevice(
            displayName: 'My phone',
            platform: DevicePlatform.androidApp,
          );
      ref.read(vaultUnlockedProvider.notifier).state = true;
      if (mounted) {
        // Immediately push the user to write down their first Recovery Kit
        // — a vault with zero recovery options is a support nightmare.
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const RecoveryScreen()));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.shield, size: 72),
              const SizedBox(height: 16),
              Text('Welcome to PeerVault', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              const Text(
                'No cloud account. No master password to remember.\n'
                'Your vault lives on your devices and is protected by your phone\'s biometrics.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              if (_creating)
                const CircularProgressIndicator()
              else ...[
                FilledButton(
                  onPressed: _createVault,
                  child: const Text('Create my vault'),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const RecoveryScreen())
                  ),
                  icon: const Icon(Icons.settings_backup_restore),
                  label: const Text('Recover using Recovery Kit'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
