import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app_providers.dart';
import '../../core/devices/device_manager.dart';
import '../../core/models/trusted_device.dart';

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  late List<TrustedDevice> _devices;

  @override
  void initState() {
    super.initState();
    _devices = ref.read(deviceManagerProvider).listDevices();
    _devices.sort((a, b) => a.revoked == b.revoked ? 0 : (a.revoked ? 1 : -1));
  }

  void _refresh() => setState(() {
    _devices = ref.read(deviceManagerProvider).listDevices();
    _devices.sort((a, b) => a.revoked == b.revoked ? 0 : (a.revoked ? 1 : -1));
  });

  IconData _iconFor(DevicePlatform platform) {
    switch (platform) {
      case DevicePlatform.androidApp:
        return Icons.phone_android;
      case DevicePlatform.iosApp:
        return Icons.phone_iphone;
      case DevicePlatform.windowsApp:
      case DevicePlatform.linuxApp:
      case DevicePlatform.macosApp:
        return Icons.laptop;
      case DevicePlatform.browserExtension:
        return Icons.extension;
    }
  }

  @override
  Widget build(BuildContext context) {
    final deviceManager = ref.read(deviceManagerProvider);

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: _devices.isEmpty
              ? ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 80),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.devices_other, size: 80, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)),
                          const SizedBox(height: 24),
                          const Text('No other trusted devices yet', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          const Text('Pull down to refresh, or pair one below.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                        ],
                      ),
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _devices.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final d = _devices[index];
                    // Simple logic for online/offline indicator: if synced in last 1 hour, assume recently online. Just an example.
                    final recentlySynced = DateTime.now().difference(d.lastSyncedAt).inHours < 1;
                    
                    return Card(
                      elevation: 1,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1))),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(_iconFor(d.platform), color: Theme.of(context).colorScheme.onPrimaryContainer, size: 28),
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
                                          d.displayName,
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (!d.revoked)
                                        Container(
                                          width: 8,
                                          height: 8,
                                          margin: const EdgeInsets.only(left: 8),
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: recentlySynced ? Colors.green : Colors.grey,
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text('Last synced: ${d.lastSyncedAt.toIso8601String().split('T')[0]} ${d.lastSyncedAt.toLocal().toString().split(' ')[1].substring(0, 5)}', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (d.revoked)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.red.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text('Revoked', style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold)),
                              )
                            else
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
                                tooltip: 'Revoke device',
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (c) => AlertDialog(
                                      title: const Text('Revoke Device?'),
                                      content: Text('Are you sure you want to revoke "${d.displayName}"? It will no longer be able to sync or access new data.'),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
                                        FilledButton(
                                          style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                          onPressed: () => Navigator.of(c).pop(true), 
                                          child: const Text('Revoke')
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    await deviceManager.revokeDevice(d.deviceId);
                                    if (mounted) {
                                      final rotate = await showDialog<bool>(
                                        context: context,
                                        barrierDismissible: false,
                                        builder: (c) => AlertDialog(
                                          title: const Text('Rotate vault key?'),
                                          content: Text(
                                              'If you suspect "${d.displayName}" was stolen or compromised, you must rotate your encryption key to prevent it from decrypting new data.\n\n'
                                              'This requires re-encrypting your entire vault. Do not close the app.'),
                                          actions: [
                                            TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Skip')),
                                            FilledButton(
                                              style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                              onPressed: () => Navigator.of(c).pop(true), 
                                              child: const Text('Rotate Key'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (rotate == true) {
                                        showDialog(
                                          context: context,
                                          barrierDismissible: false,
                                          builder: (c) => const AlertDialog(
                                            content: Row(
                                              children: [
                                                CircularProgressIndicator(),
                                                SizedBox(width: 16),
                                                Expanded(child: Text('Rotating key and re-encrypting vault (do not close)...')),
                                              ],
                                            ),
                                          ),
                                        );
                                        try {
                                          final selfId = ref.read(deviceManagerProvider).selfDeviceInfo()!.deviceId;
                                          final newVek = await ref.read(deviceManagerProvider).rotateVek(selfDeviceId: selfId);
                                          await ref.read(vaultRepositoryProvider).reencryptAllWithNewVek(newVek);
                                        } finally {
                                          if (mounted) Navigator.of(context).pop(); // dismiss progress
                                        }
                                      }
                                    }
                                    _refresh();
                                  }
                                },
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Positioned(
          bottom: 16,
          right: 16,
          child: FloatingActionButton.extended(
            heroTag: null,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Pair Device'),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _PairingFlowScreen()));
              _refresh();
            },
          ),
        ),
      ],
    );
  }
}

class _PairingFlowScreen extends ConsumerStatefulWidget {
  const _PairingFlowScreen();

  @override
  ConsumerState<_PairingFlowScreen> createState() => _PairingFlowScreenState();
}

class _PairingFlowScreenState extends ConsumerState<_PairingFlowScreen> {
  String? _qrPayload;
  bool _scanMode = false;
  String? _error;
  final _nameController = TextEditingController();
  final _pasteController = TextEditingController();

  Future<void> _generatePackage() async {
    try {
      final package = await ref.read(deviceManagerProvider).createPairingPackage();
      if (mounted) {
        setState(() => _qrPayload = package.encode());
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Cannot generate pairing code: ${e.toString()}');
      }
    }
  }

  Future<void> _handleScannedCode(String raw) async {
    try {
      final package = PairingPackage.decode(raw);
      final name = _nameController.text.trim();
      await ref.read(deviceManagerProvider).completeNewDevicePairing(
            package: package,
            displayName: name.isEmpty ? 'Paired device' : name,
            platform: DevicePlatform.androidApp,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'Pairing failed: could not read a valid JanusVault pairing code.');
    }
  }

  @override
  void initState() {
    super.initState();
    _generatePackage();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pasteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair Device'),
        actions: [
          IconButton(
            icon: Icon(_scanMode ? Icons.qr_code : Icons.qr_code_scanner),
            tooltip: _scanMode ? 'Show QR Code' : 'Scan QR Code',
            onPressed: () => setState(() {
              _scanMode = !_scanMode;
              _error = null;
            }),
          ),
        ],
      ),
      body: _scanMode
          ? Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: 'Name this device',
                      hintText: 'e.g. "Rahul\'s laptop"',
                      prefixIcon: const Icon(Icons.devices),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      filled: true,
                    ),
                    textCapitalization: TextCapitalization.words,
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                    child: MobileScanner(
                      onDetect: (capture) {
                        final code = capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
                        if (code != null) _handleScannedCode(code);
                      },
                    ),
                  ),
                ),
              ],
            )
          : Center(
              child: _qrPayload == null
                  ? const CircularProgressIndicator()
                  : SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.1),
                                  blurRadius: 20,
                                  offset: const Offset(0, 10),
                                )
                              ]
                            ),
                            child: QrImageView(data: _qrPayload!, size: 260, backgroundColor: Colors.white),
                          ),
                          const SizedBox(height: 32),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              'Scan this QR code with your new device to pair completely offline.',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 16),
                            ),
                          ),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 24),
                              child: Text(_error!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                            ),
                        ],
                      ),
                    ),
            ),
    );
  }
}
