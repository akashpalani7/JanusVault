// Background entrypoint used ONLY by the native Android AutofillService
// (see android/.../PeerVaultAutofillService.kt + AutofillBridge.kt).
//
// Android keeps a small, separate FlutterEngine alive specifically to run
// this entrypoint so autofill can work even when the main app UI isn't
// open. It talks to native Kotlin over a MethodChannel and reuses the same
// VaultSession / VaultRepository / CryptoEngine as the main app — there is
// only ONE implementation of vault logic in this whole project; native
// code never touches encryption directly, it only calls into this Dart
// layer, which is the entire point of keeping "everything in the Flutter
// app" rather than duplicating vault logic in Kotlin.

import 'dart:convert';

import 'package:flutter/services.dart';

import 'core/storage/vault_database.dart';
import 'core/vault/vault_repository.dart';
import 'core/vault/vault_session.dart';

const MethodChannel _channel = MethodChannel('com.peervault.app/autofill');

@pragma('vm:entry-point')
void autofillMain() {
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
        .map((e) => {
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
