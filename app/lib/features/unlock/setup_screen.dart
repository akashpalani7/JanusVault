import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';

import '../../app_providers.dart';
import '../../core/models/trusted_device.dart';
import '../recovery/recovery_screen.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen>
    with SingleTickerProviderStateMixin {
  bool _creating = false;
  bool _isLoadingName = true;
  String? _errorText;
  final _deviceNameController = TextEditingController();
  late final AnimationController _animController;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, 0.2), end: Offset.zero).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animController.forward();
    _initDeviceName();
  }

  Future<void> _initDeviceName() async {
    String defaultName = 'My phone';
    try {
      if (Platform.isAndroid) {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        defaultName = androidInfo.model;
      } else if (Platform.isIOS) {
        final iosInfo = await DeviceInfoPlugin().iosInfo;
        defaultName = iosInfo.name;
      }
    } catch (_) {} // ignore failures, stick to default

    if (mounted) {
      _deviceNameController.text = defaultName;
      setState(() => _isLoadingName = false);
    }
  }

  @override
  void dispose() {
    _deviceNameController.dispose();
    _animController.dispose();
    super.dispose();
  }

  Future<void> _createVault() async {
    final name = _deviceNameController.text.trim();
    if (name.isEmpty) {
      setState(() => _errorText = 'Device name is required');
      return;
    }
    setState(() {
      _creating = true;
      _errorText = null;
    });

    try {
      await ref.read(deviceManagerProvider).initializeFirstDevice(
            displayName: name,
            platform: Platform.isAndroid
                ? DevicePlatform.androidApp
                : (Platform.isIOS
                    ? DevicePlatform.iosApp
                    : DevicePlatform.windowsApp),
          );
      ref.read(vaultUnlockedProvider.notifier).state = true;
      if (mounted) {
        Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const RecoveryScreen()));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
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
            child: SlideTransition(
              position: _slideAnimation,
              child: Card(
                elevation: 8,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24)),
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.0, end: 1.0),
                        duration: const Duration(milliseconds: 800),
                        curve: Curves.elasticOut,
                        builder: (context, val, child) {
                          return Transform.scale(
                            scale: val,
                            child: Icon(Icons.shield,
                                size: 72,
                                color: Theme.of(context).colorScheme.primary),
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Welcome to JanusVault',
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No cloud account. No master password to remember.\n\n'
                        'Your vault lives on your devices and is protected by your phone\'s biometrics.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.7),
                            ),
                      ),
                      if (_isLoadingName)
                        const SizedBox(
                            height: 56,
                            child: Center(child: CircularProgressIndicator()))
                      else
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(height: 35),
                            TextField(
                              controller: _deviceNameController,
                              decoration: InputDecoration(
                                labelText: 'Device Name',
                                hintText: 'e.g. My Phone',
                                errorText: _errorText,
                                prefixIcon: const Icon(Icons.smartphone),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                filled: true,
                              ),
                              textCapitalization: TextCapitalization.words,
                              onChanged: (val) {
                                if (_errorText != null)
                                  setState(() => _errorText = null);
                              },
                            ),
                          ],
                        ),
                      const SizedBox(height: 32),
                      if (_creating)
                        const CircularProgressIndicator()
                      else ...[
                        FilledButton(
                          onPressed: _createVault,
                          style: FilledButton.styleFrom(
                              minimumSize: const Size(double.infinity, 56)),
                          child: const Text('Create my vault',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: () => Navigator.of(context)
                              .pushReplacement(MaterialPageRoute(
                                  builder: (_) => const RecoveryScreen())),
                          icon: const Icon(Icons.settings_backup_restore),
                          label: const Text('Recover using Recovery Kit'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(double.infinity, 56)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
