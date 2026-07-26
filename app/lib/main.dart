import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/biometric_auth.dart';
import 'core/storage/vault_database.dart';
import 'core/sync/lan_sync_service.dart';
import 'features/unlock/setup_screen.dart';
import 'features/unlock/unlock_screen.dart';

/// Lets a non-widget class (LanSyncService) pop a dialog on top of whatever
/// screen is currently showing, even though it has no BuildContext of its
/// own — this is what makes "phone approval" for the browser extension
/// possible at all.
final rootNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await VaultDatabase.instance.load();

  // Wired up once, globally: any time the browser extension asks this
  // phone to approve revealing/autofilling a password, show an
  // approve/deny prompt and require this device's own biometric/PIN
  // before saying yes. Fails closed (denies) if the app has no visible
  // screen to prompt on, e.g. mid-cold-start.
  LanSyncService.instance.onAuthPromptRequested = (actionLabel) async {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return false;

    final wantsToApprove = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Approve from your browser?'),
        content: Text('Your PeerVault browser extension wants to $actionLabel. Approve on this phone?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Deny')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Approve')),
        ],
      ),
    );
    if (wantsToApprove != true) return false;

    final result = await BiometricAuthService.instance.authenticate(
      reason: 'Confirm it\'s you to let your browser extension $actionLabel',
    );
    return result.success;
  };

  runApp(const ProviderScope(child: PeerVaultApp()));
}

class PeerVaultApp extends StatelessWidget {
  const PeerVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'PeerVault',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true, brightness: Brightness.dark),
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
