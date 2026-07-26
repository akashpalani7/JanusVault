import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/models/trusted_device.dart';
import '../../core/vault/vault_session.dart';
import '../vault/vault_list_screen.dart';

class RecoveryScreen extends ConsumerStatefulWidget {
  const RecoveryScreen({super.key});

  @override
  ConsumerState<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends ConsumerState<RecoveryScreen> {
  String? _newKitSecret;
  final TextEditingController _recoverInputCtrl = TextEditingController();
  String? _recoverError;
  bool _busy = false;

  Future<void> _generateNewKit() async {
    setState(() => _busy = true);
    try {
      final kit = await ref.read(recoveryServiceProvider).generateNewRecoveryKit();
      setState(() => _newKitSecret = kit.printableSecret);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _recover() async {
    setState(() {
      _busy = true;
      _recoverError = null;
    });
    try {
      await ref.read(recoveryServiceProvider).recoverWithSecret(_recoverInputCtrl.text.trim());
      await ref.read(recoveryServiceProvider).completeRecoveryOnThisDevice(
            displayName: 'Recovered device',
            platform: DevicePlatform.androidApp,
          );
      ref.read(vaultUnlockedProvider.notifier).state = true;
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const VaultListScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      setState(() => _recoverError = 'Recovery failed — check the secret and try again.');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isUnlocked = VaultSession.instance.isUnlocked;

    return Scaffold(
      appBar: AppBar(title: const Text('Recovery Kit')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (isUnlocked) ...[
            const Text(
              'Generating a new Recovery Kit invalidates the previous one. '
              'Write the secret down and store it somewhere safe — it is shown only once.',
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _generateNewKit,
              child: const Text('Generate new Recovery Kit'),
            ),
            if (_newKitSecret != null) ...[
              const SizedBox(height: 24),
              Card(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    _newKitSecret!,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 18, letterSpacing: 1.2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () { 
                  Navigator.of(context).pop();
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VaultListScreen()));
                 },
                child: const Text('Done'),
              ),
            ],
          ] else ...[
            const Text('Lost access to every trusted device? Enter your Recovery Kit secret below.'),
            const SizedBox(height: 16),
            TextField(
              controller: _recoverInputCtrl,
              decoration: const InputDecoration(labelText: 'Recovery secret', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            if (_recoverError != null) Text(_recoverError!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _recover,
              child: _busy ? const CircularProgressIndicator() : const Text('Recover vault'),
            ),
          ],
        ],
      ),
    );
  }
}
