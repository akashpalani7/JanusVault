import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../home/main_screen.dart';

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  static Future<void> checkAndRoute(BuildContext context, {bool removeUntil = false}) async {
    final isNotificationGranted = await Permission.notification.isGranted;
    if (!context.mounted) return;
    
    final target = isNotificationGranted ? const MainScreen() : const PermissionsScreen();
    
    if (removeUntil) {
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => target), (route) => false);
    } else {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => target));
    }
  }

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> with WidgetsBindingObserver {
  bool _isLoading = true;
  bool _notificationGranted = false;
  bool _bluetoothGranted = false;
  bool _locationGranted = false;
  bool _isProcessingPerms = false; // Used to show loading state during request

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Passing true so it silently skips on cold boot if already granted
    _checkStatusesOnly(startupCheck: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Don't auto-skip when resuming (e.g. back from App Settings), just update the UI
      _checkStatusesOnly(startupCheck: false);
    }
  }

  Future<void> _checkStatusesOnly({bool startupCheck = false}) async {
    if (!mounted) return;
    if (startupCheck) setState(() => _isLoading = true);
    
    final notifStatus = await Permission.notification.status;
    _notificationGranted = notifStatus.isGranted;

    bool btGranted = false;
    if (Platform.isAndroid) {
      final c = await Permission.bluetoothConnect.status;
      final s = await Permission.bluetoothScan.status;
      final a = await Permission.bluetoothAdvertise.status;
      btGranted = (c.isGranted && s.isGranted && a.isGranted);
    } else {
      btGranted = (await Permission.bluetooth.status).isGranted;
    }

    final locStatus = await Permission.location.status;
    final locGranted = locStatus.isGranted;

    if (mounted) {
      setState(() {
        _bluetoothGranted = btGranted;
        _locationGranted = locGranted;
        _isLoading = false;
      });
    }

    // Bug Fix: Only auto-skip if this check was triggered strictly from initState (startupCheck == true)
    // If the user grants notification in the UI, do NOT rip the page away. Let them tap "Continue".
    if (startupCheck && _notificationGranted) {
      _continue(autoSkip: true);
    }
  }

  Future<void> _requestNotification() async {
    setState(() => _isProcessingPerms = true);
    final status = await Permission.notification.request();
    if (status.isPermanentlyDenied) {
      await openAppSettings();
    } else {
      await _checkStatusesOnly(startupCheck: false);
    }
    if (mounted) setState(() => _isProcessingPerms = false);
  }

  Future<void> _requestBluetooth() async {
    setState(() => _isProcessingPerms = true);
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
      ].request();
      if (statuses.values.any((s) => s.isPermanentlyDenied)) {
        await openAppSettings();
      }
    } else {
      final status = await Permission.bluetooth.request();
      if (status.isPermanentlyDenied) {
        await openAppSettings();
      }
    }
    await _checkStatusesOnly(startupCheck: false);
    if (mounted) setState(() => _isProcessingPerms = false);
  }

  Future<void> _requestLocation() async {
    setState(() => _isProcessingPerms = true);
    final status = await Permission.location.request();
    if (status.isPermanentlyDenied) {
      await openAppSettings();
    } else {
      await _checkStatusesOnly(startupCheck: false);
    }
    if (mounted) setState(() => _isProcessingPerms = false);
  }

  void _continue({bool autoSkip = false}) {
    if (!autoSkip && !mounted) return;
    
    if (mounted) {
      void route() => Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const MainScreen()),
          );
      if (autoSkip) {
        route();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) => route());
      }
    }
  }

  Widget _buildPermissionCard({
    required IconData icon,
    required String title,
    required String description,
    required bool isGranted,
    required VoidCallback onRequest,
    required bool isMandatory,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    // Premium dynamic color assignment based on status
    final cardColor = isGranted ? colorScheme.primaryContainer.withAlpha(50) : colorScheme.surfaceContainerHighest.withAlpha(50);
    final borderColor = isGranted ? colorScheme.primary.withAlpha(100) : colorScheme.outline.withAlpha(60);
    final iconColor = isGranted ? colorScheme.primary : colorScheme.onSurfaceVariant;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: borderColor, width: 1.5),
      ),
      color: cardColor,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      )
                    ],
                  ),
                  child: Icon(icon, size: 28, color: iconColor),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: colorScheme.onSurface,
                              ),
                            ),
                          ),
                          if (isMandatory)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: colorScheme.errorContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                'Required',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onErrorContainer,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        description,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                if (isGranted) ...[
                  const Icon(Icons.check_circle_rounded, color: Colors.green, size: 24),
                  const SizedBox(width: 8),
                  const Text('Access Granted', style: TextStyle(color: Colors.green, fontWeight: FontWeight.w600, fontSize: 14)),
                ] else ...[
                  const Icon(Icons.cancel_rounded, color: Colors.redAccent, size: 24),
                  const SizedBox(width: 8),
                  const Text('Missing', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600, fontSize: 14)),
                  const Spacer(),
                  FilledButton.tonal(
                    onPressed: _isProcessingPerms ? null : onRequest,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
                    ),
                    child: _isProcessingPerms
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Grant Access', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final allMandatoryMet = _notificationGranted; // Only logic required is Notification

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
                physics: const BouncingScrollPhysics(),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colorScheme.primaryContainer,
                      ),
                      child: Icon(Icons.shield_rounded, size: 64, color: colorScheme.onPrimaryContainer),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Ready to Sync',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'JanusVault needs permissions to reliably sync your offline passwords across your devices without tracking you.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 32),
                    // Notification Card (Mandatory)
                    _buildPermissionCard(
                      icon: Icons.notifications_active_rounded,
                      title: 'Background Notifications',
                      description: 'Strictly required to silently approve autofill requests from your PC without opening the app.',
                      isGranted: _notificationGranted,
                      onRequest: _requestNotification,
                      isMandatory: true,
                    ),
                    // Bluetooth Card (Optional)
                    _buildPermissionCard(
                      icon: Icons.bluetooth_connected_rounded,
                      title: 'Nearby Devices (Bluetooth)',
                      description: 'Allows JanusVault to advertise and sync directly with your PC over BLE entirely offline.',
                      isGranted: _bluetoothGranted,
                      onRequest: _requestBluetooth,
                      isMandatory: false,
                    ),
                    // Device Location Card (Optional for Nearby Share)
                    if (Platform.isAndroid)
                      _buildPermissionCard(
                        icon: Icons.location_on_outlined,
                        title: 'Device Location',
                        description: 'Required by Android to discover and sync with nearby peer devices (Nearby Share) entirely offline without tracking your GPS.',
                        isGranted: _locationGranted,
                        onRequest: _requestLocation,
                        isMandatory: false,
                      ),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer.withAlpha(128),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colorScheme.secondary.withAlpha(76)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.tips_and_updates, color: colorScheme.secondary),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              'Autofill Tip: If the keyboard chip is hidden by a paste suggestion, long-press the input field → tap \'Autofill\' to trigger JanusVault manually.',
                              style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSecondaryContainer),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Bottom Sticky Action Bar
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor,
                border: Border(top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.1))),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.02),
                    offset: const Offset(0, -4),
                    blurRadius: 16,
                  )
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    onPressed: allMandatoryMet ? () => _continue() : null,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: Text(
                      allMandatoryMet 
                        ? 'Continue to Vault Setup'
                        : 'Action Required to Continue',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (!allMandatoryMet)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Please grant the required permissions above',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.error),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
