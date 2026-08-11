// Background entrypoint used by TWO native Android components:
//   1. JanusVaultAutofillService.kt (autofill suggestions/save)
//   2. JanusVaultSyncForegroundService.kt (the always-on "listen for LAN
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
import 'core/sync/ble_gatt_service.dart';
import 'core/sync/lan_sync_service.dart';
import 'core/vault/vault_repository.dart';
import 'core/vault/vault_session.dart';

const MethodChannel _channel = MethodChannel('com.janusvault.app/autofill');

void setupAutofillEntryPoint() {
  print('==== autofillMain STARTED ====');
  WidgetsFlutterBinding.ensureInitialized();
  print('==== WidgetsFlutterBinding initialized ====');
  _channel.setMethodCallHandler(_handleCall);
  _initializeThenSignalReady();
}

Future<void> _initializeThenSignalReady() async {
  print('==== _initializeThenSignalReady STARTED ====');
  try {
    await VaultDatabase.instance.load();
    print('Autofill isolate: VaultDatabase loaded');
  } catch (e, stack) {
    print('Autofill isolate: VaultDatabase failed to load - $e\n$stack');
  }
  print('==== sending ready to channel ====');
  try {
    await _channel.invokeMethod('ready');
    print('==== ready sent ====');
  } catch (e, stack) {
    print('==== failed to send ready - $e\n$stack ====');
  }
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
/// "com.instagram.android"). Uses domain-level matching for web domains
/// and keyword-based fallback for package names.
Future<String> _searchEntries(Map<dynamic, dynamic> args) async {
  final query = (args['query'] as String? ?? '').toLowerCase().trim();
  if (!VaultSession.instance.isUnlocked) {
    return jsonEncode({'locked': true, 'entries': <dynamic>[]});
  }
  await VaultDatabase.instance.load(force: true);
  final all = await VaultRepository.instance.getAllEntries();

  // Extract domain from query (handles both "example.com" and "com.example.app")
  final isPackageName = query.startsWith('com.') ||
      query.startsWith('org.') ||
      query.startsWith('net.');
  final queryDomain = isPackageName
      ? _packageToDomain(query)
      : query
          .replaceAll(RegExp(r'^(https?://)?'), '')
          .replaceAll(RegExp(r'/.*$'), '');

  final matches = all.where((e) {
    final name = e.websiteName.toLowerCase();
    final url = e.websiteUrl.toLowerCase();

    // Domain-level matching: check if stored URL/name contains the query domain
    final storedDomain =
        _extractDomain(url).isNotEmpty ? _extractDomain(url) : name;

    // If queryDomain is totally empty, we cannot do a safe blind search. 
    // Fall back to matching if stored domain is ALSO empty (which is extremely rare),
    // but absolutely do not let `.endsWith('')` and `.contains('')` evaluate to true.
    if (queryDomain.isEmpty) return false;

    // Exact domain match or suffix match (e.g. "github.com" matches "www.github.com")
    if (storedDomain == queryDomain || storedDomain.endsWith('.$queryDomain'))
      return true;
    if (queryDomain == storedDomain || queryDomain.endsWith('.$storedDomain'))
      return true;

    // Fallback: keyword containment for package names or partial matches
    if (name.contains(queryDomain) || url.contains(queryDomain)) return true;

    return false;
  }).toList();

  return jsonEncode({
    'locked': false,
    'entries': matches
        .map((e) => <String, dynamic>{
              'uuid': e.uuid,
              'websiteName': e.websiteName.trim().isNotEmpty ? e.websiteName : (e.websiteUrl.isNotEmpty ? e.websiteUrl : 'Unnamed'),
              'websiteUrl': e.websiteUrl,
              'username': e.username,
              'password': e.password,
            })
        .toList(),
  });
}

/// Extracts the domain from a URL string (e.g. "https://www.github.com/login" -> "github.com").
String _extractDomain(String url) {
  final cleaned = url
      .replaceAll(RegExp(r'^(https?://)?'), '')
      .replaceAll(RegExp(r'/.*$'), '');
  return cleaned.replaceAll(RegExp(r'^www\.'), '');
}

/// Converts an Android package name to a likely domain (e.g. "com.instagram.android" -> "instagram").
String _packageToDomain(String pkg) {
  final parts = pkg.split('.');
  // "com.instagram.android" -> "instagram", "com.whatsapp" -> "whatsapp"
  if (parts.length >= 2) return parts[1];
  return pkg;
}

/// Called from JanusVaultAutofillAuthActivity.kt AFTER it has already run a
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
  final websiteName = args['websiteName'] as String? ?? args['appIdentifier'] as String? ?? 'Unknown app';
  final websiteUrl = args['websiteUrl'] as String? ?? args['appIdentifier'] as String? ?? '';
  final username = args['username'] as String? ?? '';
  final password = args['password'] as String? ?? '';
  if (password.isEmpty) return false;

  await VaultRepository.instance.createEntry(
    websiteName: websiteName,
    websiteUrl: websiteUrl,
    username: username,
    password: password,
  );
  return true;
}

/// Resolved (approved/denied) from JanusVaultRemoteApprovalActivity.kt once
/// the user responds to the "Approve access from your browser?" notification
/// this isolate posted via `showApprovalNotification`. Null while nothing
/// is pending.
Completer<bool>? _pendingApprovalCompleter;

/// Starts the LAN sync server so this device can respond to sync +
/// phone-approval requests with the app fully closed — called from
/// JanusVaultSyncForegroundService.kt, which is what keeps this isolate
/// alive in the background (a plain background isolate with no foreground
/// service would get killed by Android fairly quickly).
///
/// Auto-unlocks silently: reading this device's local wrapping key from
/// FlutterSecureStorage does NOT require biometric confirmation (see
/// SecureKeyStore's doc comment) — only the per-request approval below
/// does. Without this silent unlock, the always-on listener could accept
/// connections but could never actually answer the VEK-derived handshake,
/// making it useless.
Timer? _syncShutdownTimer;

Future<void> _startSyncListening(Map<dynamic, dynamic> args) async {
  _syncShutdownTimer?.cancel();
  _syncShutdownTimer = Timer(const Duration(minutes: 2), () {
    print('BLE Listener timed out after 2 minutes. Auto-stopping.');
    _stopSyncListening();
  });

  final displayName = args['displayName'] as String? ?? 'This device';
  final bluetoothEnabled = args['bluetoothEnabled'] as bool? ?? true;

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
  // native notification and wait for JanusVaultRemoteApprovalActivity.kt
  // (launched from that notification, which DOES have an Activity, so it
  // CAN run BiometricPrompt) to call back via `resolveApproval`.
  LanSyncService.instance.onAuthPromptRequested = (actionLabel) async {
    _pendingApprovalCompleter = Completer<bool>();
    await _channel
        .invokeMethod('showApprovalNotification', {'actionLabel': actionLabel});
    return _pendingApprovalCompleter!.future
        .timeout(const Duration(seconds: 55), onTimeout: () => false);
  };
  BleGattService.instance.onAuthPromptRequested =
      LanSyncService.instance.onAuthPromptRequested;

  try {
    await LanSyncService.instance
        .startAdvertisingAndServing(deviceDisplayName: displayName);
  } catch (e) {
    print('LanSync autofill start failed: $e');
  }

  if (bluetoothEnabled) {
    try {
      await BleGattService.instance
          .startAdvertising(deviceDisplayName: displayName);
    } catch (e) {
      print('Ble autofill start failed: $e');
    }
  } else {
    print('Bluetooth is off. Skipping BleGattService to prevent intrusive OS dialogs.');
  }
}

Future<void> _stopSyncListening() async {
  _syncShutdownTimer?.cancel();
  await LanSyncService.instance.stopAdvertisingAndServing();
  await BleGattService.instance.stopAdvertising();
}

Future<void> _resolveApproval(Map<dynamic, dynamic> args) async {
  final approved = args['approved'] as bool? ?? false;
  _pendingApprovalCompleter?.complete(approved);
  _pendingApprovalCompleter = null;
}
