import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/vault/vault_session.dart';
import '../backup/backup_screen.dart';
import '../devices/devices_screen.dart';
import '../recovery/recovery_screen.dart';
import '../settings/settings_screen.dart';
import '../sync/sync_screen.dart';
import '../vault/recycle_bin_screen.dart';
import '../vault/vault_list_screen.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  int _currentIndex = 0;
  bool _isLockedHover = false;

  void _showMoreMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: const Text('Recovery Kit'),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RecoveryScreen()));
                },
              ),
              ListTile(
                leading: const Icon(Icons.import_export),
                title: const Text('Backup / Restore'),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BackupScreen()));
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Recycle Bin'),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RecycleBinScreen()));
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Settings'),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar() {
    if (_currentIndex == 0) {
      return AppBar(
        title: const Text('JanusVault', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          MouseRegion(
            onEnter: (_) => setState(() => _isLockedHover = true),
            onExit: (_) => setState(() => _isLockedHover = false),
            child: IconButton(
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Icon(
                  _isLockedHover ? Icons.lock : Icons.lock_outline,
                  key: ValueKey<bool>(_isLockedHover),
                ),
              ),
              tooltip: 'Lock vault',
              onPressed: () {
                VaultSession.instance.lock();
                ref.read(vaultUnlockedProvider.notifier).state = false;
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
            ),
          ),
        ],
      );
    } else if (_currentIndex == 1) {
      return AppBar(
        title: const Text('Sync Vault', style: TextStyle(fontWeight: FontWeight.bold)),
        bottom: TabBar(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          indicator: BoxDecoration(
            borderRadius: BorderRadius.circular(50),
            color: Theme.of(context).colorScheme.primaryContainer,
          ),
          indicatorSize: TabBarIndicatorSize.tab,
          dividerColor: Colors.transparent,
          labelColor: Theme.of(context).colorScheme.onPrimaryContainer,
          unselectedLabelColor: Theme.of(context).colorScheme.onSurfaceVariant,
          labelStyle: const TextStyle(fontWeight: FontWeight.w800),
          unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
          tabs: const [
            Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.wifi, size: 18), SizedBox(width: 8), Text('WiFi')])),
            Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.bluetooth, size: 18), SizedBox(width: 8), Text('BLE')])),
            Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.sensors, size: 18), SizedBox(width: 8), Text('Nearby')])),
          ],
        ),
      );
    } else {
      return AppBar(
        title: const Text('Trusted Devices', style: TextStyle(fontWeight: FontWeight.bold)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: _buildAppBar(),
        body: IndexedStack(
          index: _currentIndex,
          children: const [
            VaultListScreen(),
            SyncScreen(),
            DevicesScreen(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            if (index == 3) {
              _showMoreMenu();
            } else {
              setState(() => _currentIndex = index);
            }
          },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.lock_outline), selectedIcon: Icon(Icons.lock), label: 'Vault'),
            NavigationDestination(icon: Icon(Icons.sync), selectedIcon: Icon(Icons.sync), label: 'Sync'),
            NavigationDestination(icon: Icon(Icons.devices), selectedIcon: Icon(Icons.devices), label: 'Devices'),
            NavigationDestination(icon: Icon(Icons.menu), selectedIcon: Icon(Icons.menu), label: 'More'),
          ],
        ),
      ),
    );
  }
}
