import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/biometric_auth.dart';
import 'core/backup/backup_service.dart';
import 'core/devices/device_manager.dart';
import 'core/generator/password_generator.dart';
import 'core/models/vault_entry.dart';
import 'core/recovery/recovery_service.dart';
import 'core/sync/lan_sync_service.dart';
import 'core/vault/vault_repository.dart';
import 'core/vault/vault_session.dart';

final biometricAuthProvider = Provider((ref) => BiometricAuthService.instance);
final vaultRepositoryProvider = Provider((ref) => VaultRepository.instance);
final vaultSessionProvider = Provider((ref) => VaultSession.instance);
final deviceManagerProvider = Provider((ref) => DeviceManager.instance);
final recoveryServiceProvider = Provider((ref) => RecoveryService.instance);
final backupServiceProvider = Provider((ref) => BackupService.instance);
final lanSyncServiceProvider = Provider((ref) {
  final service = LanSyncService.instance;
  service.recordsUpdatedCallback = () {
    ref.invalidate(filteredEntriesProvider);
  };
  return service;
});
final passwordGeneratorProvider = Provider((ref) => PasswordGenerator.instance);

/// Whether the vault is currently unlocked. UI listens to this to decide
/// between showing the unlock screen or the vault itself.
final vaultUnlockedProvider = StateProvider<bool>((ref) => VaultSession.instance.isUnlocked);

/// Live, decrypted vault entries. Only meaningful while unlocked; callers
/// should gate access behind `vaultUnlockedProvider`.
final vaultEntriesProvider = FutureProvider.autoDispose<List<VaultEntry>>((ref) async {
  if (!VaultSession.instance.isUnlocked) return [];
  return VaultRepository.instance.getAllEntries();
});

final searchQueryProvider = StateProvider<String>((ref) => '');

final filteredEntriesProvider = FutureProvider.autoDispose<List<VaultEntry>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  if (!VaultSession.instance.isUnlocked) return [];
  if (query.isEmpty) return VaultRepository.instance.getAllEntries();
  return VaultRepository.instance.searchByWebsite(query);
});
