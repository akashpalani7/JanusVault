// Background entrypoint used by TWO native Android components:
//   1. PeerVaultAutofillService.kt (autofill suggestions/save)
//   2. PeerVaultSyncForegroundService.kt (the always-on "listen for LAN
//      sync + phone-approval requests, even with the app fully closed"
//      background service, toggled via the quick-settings tile or the
//      Sync screen)
// Both talk to native Kotlin over the SAME MethodChannel (see
// AutofillBridge.kt) and reuse the same VaultSession / VaultRepository /
// CryptoEngine / LanSyncService as the main app — there is only ONE
// implementation of vault logic in this whole project; native code never
// touches encryption directly, it only calls into this Dart layer.
//
// Android keeps a small, separate FlutterEngine alive specifically to run
// this entrypoint so both features work even when the main app UI isn't
// open.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'core/storage/vault_database.dart';
import 'core/sync/lan_sync_service.dart';
import 'core/vault/vault_repository.dart';
import 'core/vault/vault_session.dart';

const MethodChannel _channel = MethodChannel('com.peervault.app/autofill');

@pragma('vm:entry-point')
void autofillMain() {
  WidgetsFlutterBinding.ensureInitialized();
  _channel.setMethodCallHandler(_handleCall);
  _initializeThenSignalReady();
}

/// Previously this isolate signalled "ready" to native immediately, before
/// ever loading the vault database — every single autofill request would
/// then see an empty/uninitialized VaultDatabase and report "locked" or
/// find zero entries, regardless of the vault's real state. This is a
/// distinct, separate FlutterEngine/isolate from the main app's, so it
/// must load its own copy of the database; it can't rely on main.dart's
/// `await VaultDatabase.instance.load()` having already happened.
Future<void> _initializeThenSignalReady() async {
  await VaultDatabase.instance.load();
  await _channel.invokeMethod('ready');
}

Future<dynamic> _handleCall(MethodCall call) async {
  switch (call.method) {
    case 'searchEntries':
      return _searchEntries(call.arguments as Map<dynamic, dynamic>);
    case 'unlockVault':
      return _unlockVault();
    case 'isUnlocked':
      return VaultSession.instance.isUnlocked;
    case 'saveCapturedCredential':
      return _saveCapturedCredential(call.arguments as Map<dynamic, dynamic>);
    case 'startSyncListening':
      return _startSyncListening(call.arguments as Map<dynamic, dynamic>);
    case 'stopSyncListening':
      return _stopSyncListening();
    case 'resolveApproval':
      return _resolveApproval(call.arguments as Map<dynamic, dynamic>);
    default:
      throw MissingPluginException('No handler for ${call.method}');
  }
}

/// [query] is a web domain (e.g. "instagram.com", extracted from
/// `ViewNode.webDomain` for browser tabs) or, for native apps without a
/// resolvable web domain, the Android package name (e.g.
/// "com.instagram.android"). Matching here is intentionally simple
/// substring matching against stored website names/URLs — perfect
/// package<->domain association requires verifying Digital Asset Links
/// (assetlinks.json), which is a good v2 improvement but not required for
/// autofill to work.
Future<String> _searchEntries(Map<dynamic, dynamic> args) async {
  final query = (args['query'] as String? ?? '').toLowerCase();
  if (!VaultSession.instance.isUnlocked) {
    return jsonEncode({'locked': true, 'entries': <dynamic>[]});
  }
  final all = await VaultRepository.instance.getAllEntries();
  // Package-name style fallback (e.g. "com.instagram.android" -> "instagram
  // android") — only useful when `query` isn't already a real domain.
  final normalizedQuery = query.replaceAll('.', ' ').replaceAll('com ', '').trim();
  final matches = all.where((e) {
    final haystack = '${e.websiteName} ${e.websiteUrl}'.toLowerCase();
    return haystack.contains(query) ||
        haystack.contains(normalizedQuery) ||
        normalizedQuery.split(' ').any((part) => part.isNotEmpty && haystack.contains(part));
  }).toList();

  return jsonEncode({
    'locked': false,
    'entries': matches
        .map((e) => <String, dynamic>{
              'uuid': e.uuid,
              'websiteName': e.websiteName,
              'username': e.username,
              'password': e.password,
            })
        .toList(),
  });
}

/// Called from PeerVaultAutofillAuthActivity.kt AFTER it has already run a
/// native androidx.biometric.BiometricPrompt check itself and the user
/// passed it. This headless background isolate has no Activity, so it
/// cannot render a biometric dialog (local_auth requires a FragmentActivity)
/// — the native side is responsible for that gate, and only calls this
/// once biometric success has already been confirmed.
Future<bool> _unlockVault() async {
  final settings = VaultDatabase.instance.settings;
  if (settings == null) return false;
  await VaultSession.instance.unlock(selfDeviceId: settings.selfDeviceId);
  return true;
}

/// Called when Android's autofill "save" flow fires after a successful
/// login/signup in another app, with the captured identifier/username/
/// password. Requires the vault to already be unlocked — if it's locked,
/// native side is expected to have prompted for biometrics first via the
/// standard save-request confirmation UI.
Future<bool> _saveCapturedCredential(Map<dynamic, dynamic> args) async {
  if (!VaultSession.instance.isUnlocked) return false;
  final websiteName = args['appIdentifier'] as String? ?? 'Unknown app';
  final username = args['username'] as String? ?? '';
  final password = args['password'] as String? ?? '';
  if (password.isEmpty) return false;

  await VaultRepository.instance.createEntry(
    websiteName: websiteName,
    websiteUrl: websiteName,
    username: username,
    password: password,
  );
  return true;
}

/// Resolved (approved/denied) from PeerVaultRemoteApprovalActivity.kt once
/// the user responds to the "Approve access from your browser?" notification
/// this isolate posted via `showApprovalNotification`. Null while nothing
/// is pending.
Completer<bool>? _pendingApprovalCompleter;

/// Starts the LAN sync server so this device can respond to sync +
/// phone-approval requests with the app fully closed — called from
/// PeerVaultSyncForegroundService.kt, which is what keeps this isolate
/// alive in the background (a plain background isolate with no foreground
/// service would get killed by Android fairly quickly).
///
/// Auto-unlocks silently: reading this device's local wrapping key from
/// FlutterSecureStorage does NOT require biometric confirmation (see
/// SecureKeyStore's doc comment) — only the per-request approval below
/// does. Without this silent unlock, the always-on listener could accept
/// connections but could never actually answer the VEK-derived handshake,
/// making it useless.
Future<void> _startSyncListening(Map<dynamic, dynamic> args) async {
  final displayName = args['displayName'] as String? ?? 'This device';

  if (!VaultSession.instance.isUnlocked) {
    final settings = VaultDatabase.instance.settings;
    if (settings != null) {
      try {
        await VaultSession.instance.unlock(selfDeviceId: settings.selfDeviceId);
      } catch (_) {
        return; // can't unlock (e.g. not yet set up on this device) — nothing to listen with
      }
    }
  }

  // This headless isolate has no Activity, so it can't show a Material
  // dialog the way main.dart's foreground handler does. Instead: post a
  // native notification and wait for PeerVaultRemoteApprovalActivity.kt
  // (launched from that notification, which DOES have an Activity, so it
  // CAN run BiometricPrompt) to call back via `resolveApproval`.
  LanSyncService.instance.onAuthPromptRequested = (actionLabel) async {
    _pendingApprovalCompleter = Completer<bool>();
    await _channel.invokeMethod('showApprovalNotification', {'actionLabel': actionLabel});
    return _pendingApprovalCompleter!.future.timeout(const Duration(seconds: 55), onTimeout: () => false);
  };

  await LanSyncService.instance.startAdvertisingAndServing(deviceDisplayName: displayName);
}

Future<void> _stopSyncListening() async {
  await LanSyncService.instance.stopAdvertisingAndServing();
}

Future<void> _resolveApproval(Map<dynamic, dynamic> args) async {
  final approved = args['approved'] as bool? ?? false;
  _pendingApprovalCompleter?.complete(approved);
  _pendingApprovalCompleter = null;
}
