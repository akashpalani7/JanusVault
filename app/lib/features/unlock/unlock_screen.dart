import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/storage/vault_database.dart';
import '../recovery/recovery_screen.dart';
import '../vault/vault_list_screen.dart';

class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key});

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> {
  bool _isAuthenticating = false;
  String? _errorMessage;

  Future<void> _unlock() async {
    setState(() {
      _isAuthenticating = true;
      _errorMessage = null;
    });

    try {
      final bioResult = await ref.read(biometricAuthProvider).authenticate();
      if (!bioResult.success) {
        setState(() => _errorMessage = bioResult.errorMessage ?? 'Authentication was not completed');
        return;
      }

      final settings = VaultDatabase.instance.settings;
      if (settings == null) {
        setState(() => _errorMessage = 'No vault found on this device yet.');
        return;
      }

      await ref.read(vaultSessionProvider).unlock(selfDeviceId: settings.selfDeviceId);
      ref.read(vaultUnlockedProvider.notifier).state = true;

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const VaultListScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      setState(() => _errorMessage = 'Unlock failed: $e');
    } finally {
      if (mounted) setState(() => _isAuthenticating = false);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
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
              const Icon(Icons.lock_outline, size: 72),
              const SizedBox(height: 16),
              Text('PeerVault', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 24),
              if (_isAuthenticating) const CircularProgressIndicator(),
              if (_errorMessage != null) ...[
                Text(_errorMessage!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _unlock,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Try again'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RecoveryScreen())),
                  child: const Text('Lost your device? Use Recovery Kit'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
