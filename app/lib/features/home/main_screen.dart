import 'dart:io';

import 'package:file_picker/file_picker.dart';
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
import '../../core/vault/vault_repository.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  bool _isLockedHover = false;
  late final TabController _syncTabController;

  @override
  void initState() {
    super.initState();
    _syncTabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _syncTabController.dispose();
    super.dispose();
  }

  Future<void> _handleImportCsv() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.single.path == null) return;

    final file = File(result.files.single.path!);
    final text = await file.readAsString();
    
    final rows = _parseCsv(text);
    if (rows.length < 2) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No password data found in file.")));
      return;
    }

    final header = rows[0].map((h) => h.trim().toLowerCase()).toList();
    final urlIdx = header.indexOf("url");
    final userIdx = header.indexOf("username");
    final passIdx = header.indexOf("password");
    final nameIdx = header.indexOf("name");

    if (urlIdx == -1 || userIdx == -1 || passIdx == -1) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Invalid CSV format (requires url, username, password columns).")));
      return;
    }

    final existingEntries = await VaultRepository.instance.getAllEntries();

    int saved = 0;
    int skipped = 0;
    
    for (int i = 1; i < rows.length; i++) {
      final cols = rows[i];
      final url = urlIdx < cols.length ? cols[urlIdx].trim() : '';
      final username = userIdx < cols.length ? cols[userIdx].trim() : '';
      final password = passIdx < cols.length ? cols[passIdx].trim() : '';
      
      if (url.isEmpty || password.isEmpty) {
        skipped++;
        continue;
      }
      
      String domain = url;
      try {
        if (!url.startsWith('http')) {
          domain = Uri.parse('https://$url').host;
        } else {
          domain = Uri.parse(url).host;
        }
        if (domain.isEmpty) domain = url;
      } catch (_) { }
      
      final websiteName = (nameIdx != -1 && nameIdx < cols.length && cols[nameIdx].trim().isNotEmpty) 
          ? cols[nameIdx].trim() 
          : domain;

      if (existingEntries.any((e) => (e.websiteName == websiteName || e.websiteUrl == url || e.websiteUrl == domain) && e.username == username)) {
        skipped++;
        continue;
      }

      await VaultRepository.instance.createEntry(
        websiteName: websiteName,
        websiteUrl: domain,
        username: username,
        password: password,
      );
      saved++;
    }

    if (mounted) {
      if (saved > 0) {
        ref.invalidate(filteredEntriesProvider);
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Imported $saved entries, skipped $skipped.")));
    }
  }

  List<List<String>> _parseCsv(String text) {
    // Basic CSV parser...
    final List<List<String>> rows = [];
    List<String> row = [];
    String field = "";
    bool inQuotes = false;

    for (int i = 0; i < text.length; i++) {
        final String c = text[i];
        if (inQuotes) {
            if (c == '"' && i + 1 < text.length && text[i + 1] == '"') {
                field += '"';
                i++;
            } else if (c == '"') {
                inQuotes = false;
            } else {
                field += c;
            }
        } else if (c == '"') {
            inQuotes = true;
        } else if (c == ',') {
            row.add(field);
            field = "";
        } else if (c == '\n' || c == '\r') {
            if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
            row.add(field);
            rows.add(row);
            row = [];
            field = "";
        } else {
            field += c;
        }
    }
    if (field.isNotEmpty || row.isNotEmpty) {
        row.add(field);
        rows.add(row);
    }
    return rows.where((r) => r.any((cell) => cell.trim().isNotEmpty)).toList();
  }

  Future<void> _showMoreMenu() {
    return showModalBottomSheet(
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
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('Import from CSV'),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                onTap: () {
                  Navigator.pop(context);
                  _handleImportCsv();
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
          controller: _syncTabController,
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
    return Scaffold(
      appBar: _buildAppBar(),
      body: IndexedStack(
        index: _currentIndex > 2 ? 0 : _currentIndex,
        children: [
          const VaultListScreen(),
          SyncScreen(controller: _syncTabController),
          const DevicesScreen(),
        ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            if (index == 3) {
              final previousIndex = _currentIndex;
              setState(() => _currentIndex = index);
              _showMoreMenu().whenComplete(() {
                if (mounted) setState(() => _currentIndex = previousIndex);
              });
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
    );
  }
}
