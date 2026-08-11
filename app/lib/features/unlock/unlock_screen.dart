import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/storage/vault_database.dart';
import '../permissions/permissions_screen.dart';
import '../recovery/recovery_screen.dart';

class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key});

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> with SingleTickerProviderStateMixin {
  bool _isAuthenticating = false;
  String? _errorMessage;
  late final AnimationController _shakeController;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() {
      _isAuthenticating = true;
      _errorMessage = null;
    });

    try {
      final bioResult = await ref.read(biometricAuthProvider).authenticate();
      if (!bioResult.success) {
        setState(() => _errorMessage = bioResult.errorMessage ?? 'Authentication was not completed');
        _shakeController.forward(from: 0);
        return;
      }

      final settings = VaultDatabase.instance.settings;
      if (settings == null) {
        setState(() => _errorMessage = 'No vault found on this device yet.');
        _shakeController.forward(from: 0);
        return;
      }

      await ref.read(vaultSessionProvider).unlock(selfDeviceId: settings.selfDeviceId);
      ref.read(vaultUnlockedProvider.notifier).state = true;

      if (mounted) {
        PermissionsScreen.checkAndRoute(context, removeUntil: true);
      }
    } catch (e) {
      setState(() => _errorMessage = 'Unlock failed: $e');
      _shakeController.forward(from: 0);
    } finally {
      if (mounted) setState(() => _isAuthenticating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Theme.of(context).colorScheme.surface,
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Card(
              elevation: 8,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedBuilder(
                      animation: _shakeController,
                      builder: (context, child) {
                        final padding = 10.0 * (0.5 - (0.5 - _shakeController.value).abs()) * 2;
                        return Transform.translate(
                          offset: Offset(padding, 0),
                          child: child,
                        );
                      },
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.8, end: 1.0),
                        duration: const Duration(milliseconds: 600),
                        curve: Curves.elasticOut,
                        builder: (context, val, child) {
                          return Transform.scale(
                            scale: val,
                            child: Icon(
                              _errorMessage != null ? Icons.lock : Icons.lock_open,
                              size: 72,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'JanusVault',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_isAuthenticating)
                      const CircularProgressIndicator()
                    else ...[
                      if (_errorMessage != null)
                        Text(_errorMessage!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      InkWell(
                        onTap: _unlock,
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.fingerprint, size: 48, color: Theme.of(context).colorScheme.onPrimaryContainer),
                              const SizedBox(height: 8),
                              Text(
                                'Tap to Unlock',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RecoveryScreen())),
                        child: const Text('Lost your device? Use Recovery Kit'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
