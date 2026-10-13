import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// IMPORTANT: this import has no direct use in this file — main() never
// calls anything from it. It exists purely so the Dart compiler includes
// autofill_entrypoint.dart (and its autofillMain() entry point) in the
// compiled app at all. @pragma('vm:entry-point') only protects an
// ALREADY-INCLUDED function from tree-shaking; it cannot pull in a file
// that nothing imports in the first place. Without this line, native
// Kotlin (AutofillBridge.kt) was calling a Dart entrypoint that simply
// didn't exist in the built app — silently, with no error surfaced
// anywhere, which is exactly why autofill and the background sync
// listener both did nothing at all despite registering correctly with
// Android.
// ignore: unused_import
import 'autofill_entrypoint.dart';
import 'core/auth/biometric_auth.dart';
import 'core/storage/vault_database.dart';
import 'core/vault/vault_repository.dart';
import 'core/sync/ble_gatt_service.dart';
import 'core/sync/lan_sync_service.dart';
import 'features/unlock/setup_screen.dart';
import 'features/unlock/unlock_screen.dart';
import 'core/theme/app_theme.dart';

@pragma('vm:entry-point')
void autofillMain() {
  setupAutofillEntryPoint();
}

/// Lets a non-widget class (LanSyncService) pop a dialog on top of whatever
/// screen is currently showing, even though it has no BuildContext of its
/// own — this is what makes "phone approval" for the browser extension
/// possible at all.
final rootNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await VaultDatabase.instance.load();
  final settings = VaultDatabase.instance.settings;
  if (settings != null) {
      // ignore: unawaited_futures
      VaultRepository.instance.purgeExpiredRecycleBin(retentionDays: settings.recycleBinRetentionDays);
  }

  // Wired up once, globally: any time the browser extension asks this
  // phone to approve revealing/autofilling a password, show an
  // approve/deny prompt and require this device's own biometric/PIN
  // before saying yes. Fails closed (denies) if the app has no visible
  // screen to prompt on, e.g. mid-cold-start.
  LanSyncService.instance.onAuthPromptRequested = (actionLabel) async {
    final context = rootNavigatorKey.currentContext;
    final isBackground =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;

    if (context == null || isBackground) {
      final completer = Completer<bool>();
      const channel = MethodChannel('com.janusvault.app/main_auth');
      channel.setMethodCallHandler((call) async {
        if (call.method == 'resolveApproval') {
          if (!completer.isCompleted) {
            completer.complete(call.arguments['approved'] as bool? ?? false);
          }
        }
      });
      await channel.invokeMethod(
          'showApprovalNotification', {'actionLabel': actionLabel});
      return completer.future
          .timeout(const Duration(seconds: 55), onTimeout: () => false);
    }

    final wantsToApprove = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Approve from your browser?'),
        content: Text(
            'Your JanusVault browser extension wants to $actionLabel. Approve on this phone?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Deny')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Approve')),
        ],
      ),
    );
    if (wantsToApprove != true) return false;

    final result = await BiometricAuthService.instance.authenticate(
      reason: 'Confirm it\'s you to let your browser extension $actionLabel',
    );
    return result.success;
  };

  LanSyncService.instance.onPairingRequested = (deviceName, pin) async {
    final context = rootNavigatorKey.currentContext;
    final isBackground =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;

    if (context == null || isBackground) {
      // In the future, we could add a `showPairingNotification` channel, but for now we must explicitly fail
      // so the PC doesn't hang!
      throw Exception(
          "Cannot authorize new device pairing while the app is in the background. Please open JanusVault on your phone and try again.");
    }

    final wantsToApprove = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Pairing Request'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
                'A new device ("$deviceName") wants to pair with this vault over Wi-Fi/Bluetooth.'),
            const SizedBox(height: 16),
            const Text(
                'Verify this PIN matches what is shown on the new device:',
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(pin,
                style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Deny')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Matches! Approve')),
        ],
      ),
    );

    if (wantsToApprove != true) return false;

    final result = await BiometricAuthService.instance.authenticate(
      reason: 'Confirm it\'s you to approve pairing with $deviceName',
    );
    return result.success;
  };

  // Wire up the same handlers for BLE GATT Sync
  BleGattService.instance.onAuthPromptRequested =
      LanSyncService.instance.onAuthPromptRequested;
  BleGattService.instance.onPairingRequested =
      LanSyncService.instance.onPairingRequested;

  runApp(const ProviderScope(child: JanusVaultApp()));
}

class JanusVaultApp extends StatelessWidget {
  const JanusVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'JanusVault',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: const _RootRouter(),
    );
  }
}

/// Decides, on cold start, whether this device already has a vault
/// (-> UnlockScreen) or needs first-run setup (-> SetupScreen).
class _RootRouter extends StatefulWidget {
  const _RootRouter();

  @override
  State<_RootRouter> createState() => _RootRouterState();
}

class _RootRouterState extends State<_RootRouter> {
  bool? _vaultExists;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final settings = VaultDatabase.instance.settings;
    setState(() => _vaultExists = settings != null);
  }

  @override
  Widget build(BuildContext context) {
    if (_vaultExists == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _vaultExists! ? const UnlockScreen() : const SetupScreen();
  }
}
