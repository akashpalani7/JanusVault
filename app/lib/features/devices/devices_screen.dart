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
  }

  void _refresh() => setState(() => _devices = ref.read(deviceManagerProvider).listDevices());

  @override
  Widget build(BuildContext context) {
    final deviceManager = ref.read(deviceManagerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Trusted devices')),
      body: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: _devices.isEmpty
            ? ListView(
                children: const [
                  Padding(
                    padding: EdgeInsets.only(top: 80),
                    child: Center(child: Text('No other trusted devices yet.\nPull down to refresh, or pair one below.', textAlign: TextAlign.center)),
                  ),
                ],
              )
            : ListView.builder(
                itemCount: _devices.length,
                itemBuilder: (context, index) {
                  final d = _devices[index];
                  return ListTile(
                    leading: Icon(_iconFor(d.platform)),
                    title: Text(d.displayName),
                    subtitle: Text('Paired ${d.pairedAt.toLocal()} • Last synced ${d.lastSyncedAt.toLocal()}'),
                    trailing: d.revoked
                        ? const Chip(label: Text('Revoked'))
                        : IconButton(
                            icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                            onPressed: () async {
                              await deviceManager.revokeDevice(d.deviceId);
                              _refresh();
                            },
                          ),
                  );
                },
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.qr_code),
        label: const Text('Pair new device'),
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _PairingFlowScreen()));
          _refresh();
        },
      ),
    );
  }

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
}

/// Pairing is now a SINGLE offline step: the device that already holds the
/// vault shows a QR code containing a pairing code + the VEK wrapped under
/// a key derived from that code (see CryptoEngine + DeviceManager). The
/// new device scans it and immediately has everything it needs — no
/// network round trip, no asymmetric crypto, no cross-platform mismatch.
class _PairingFlowScreen extends ConsumerStatefulWidget {
  const _PairingFlowScreen();

  @override
  ConsumerState<_PairingFlowScreen> createState() => _PairingFlowScreenState();
}

class _PairingFlowScreenState extends ConsumerState<_PairingFlowScreen> {
  String? _qrPayload;
  bool _scanMode = false;
  String? _error;

  Future<void> _generatePackage() async {
    final package = await ref.read(deviceManagerProvider).createPairingPackage();
    setState(() => _qrPayload = package.encode());
  }

  Future<void> _handleScannedCode(String raw) async {
    try {
      final package = PairingPackage.decode(raw);
      await ref.read(deviceManagerProvider).completeNewDevicePairing(
            package: package,
            displayName: 'Paired device',
            platform: DevicePlatform.androidApp,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'Pairing failed: could not read a valid PeerVault pairing code.');
    }
  }

  @override
  void initState() {
    super.initState();
    _generatePackage();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair device'),
        actions: [
          IconButton(
            icon: Icon(_scanMode ? Icons.qr_code : Icons.qr_code_scanner),
            onPressed: () => setState(() {
              _scanMode = !_scanMode;
              _error = null;
            }),
          ),
        ],
      ),
      body: _scanMode
          ? MobileScanner(
              onDetect: (capture) {
                final code = capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
                if (code != null) _handleScannedCode(code);
              },
            )
          : Center(
              child: _qrPayload == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        QrImageView(data: _qrPayload!, size: 260, backgroundColor: Colors.white,),
                        const SizedBox(height: 16),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            'Scan this with the new device — pairing works completely offline.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(_error!, style: const TextStyle(color: Colors.red)),
                          ),
                      ],
                    ),
            ),
    );
  }
}
