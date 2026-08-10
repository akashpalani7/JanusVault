import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app_providers.dart';
import '../../core/models/recovery_kit.dart';
import '../../core/models/trusted_device.dart';
import '../../core/recovery/recovery_service.dart';
import '../../core/vault/vault_session.dart';
import '../permissions/permissions_screen.dart';

class RecoveryScreen extends ConsumerStatefulWidget {
  const RecoveryScreen({super.key});

  @override
  ConsumerState<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends ConsumerState<RecoveryScreen> {
  // --- Generate-kit state (vault already unlocked) ---
  GeneratedRecoveryKit? _newKit;

  // --- Recover state (vault locked / brand-new device) ---
  final TextEditingController _secretCtrl = TextEditingController();
  final TextEditingController _deviceNameCtrl = TextEditingController();
  final TextEditingController _packagePasteCtrl = TextEditingController();
  RecoveryKitPackage? _scannedPackage;
  bool _scanning = false;
  String? _recoverError;
  bool _busy = false;

  // --- Post-recovery: the freshly-issued kit that MUST be shown once ---
  GeneratedRecoveryKit? _postRecoveryKit;

  Future<void> _generateNewKit() async {
    setState(() => _busy = true);
    try {
      final kit = await ref.read(recoveryServiceProvider).generateNewRecoveryKit();
      setState(() => _newKit = kit);
    } finally {
      setState(() => _busy = false);
    }
  }

  RecoveryKitPackage? _resolvePastedPackage() {
    final raw = _packagePasteCtrl.text.trim();
    if (raw.isEmpty) return null;
    try {
      return RecoveryKitPackage.decode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _recover() async {
    final package = _scannedPackage ?? _resolvePastedPackage();
    setState(() {
      _busy = true;
      _recoverError = null;
    });
    try {
      final service = ref.read(recoveryServiceProvider);
      await service.recoverWithSecret(_secretCtrl.text.trim(), providedPackage: package);
      final name = _deviceNameCtrl.text.trim();
      final newKit = await service.completeRecoveryOnThisDevice(
        displayName: name.isEmpty ? 'Recovered device' : name,
        platform: DevicePlatform.androidApp,
      );
      ref.read(vaultUnlockedProvider.notifier).state = true;
      // Do NOT navigate away yet — the new kit's secret only ever exists
      // right now. Show it first; "Done" (below) is what actually leaves.
      setState(() => _postRecoveryKit = newKit);
    } catch (e) {
      setState(() => _recoverError = 'Recovery failed: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      setState(() => _busy = false);
    }
  }

  void _finishToVault() {
    PermissionsScreen.checkAndRoute(context);
  }

  @override
  void dispose() {
    _secretCtrl.dispose();
    _deviceNameCtrl.dispose();
    _packagePasteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isUnlocked = VaultSession.instance.isUnlocked;

    return Scaffold(
      appBar: AppBar(title: const Text('Recovery Kit')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_postRecoveryKit != null)
            ..._buildRevealOnceKit(
              title: 'Vault recovered. Save your NEW Recovery Kit now.',
              subtitle:
                  'The kit you just used is now permanently invalid — recovery kits are single-use. '
                  'This is a brand new one; if you don\'t save it, you won\'t be able to recover this '
                  'vault again if you lose every device.',
              kit: _postRecoveryKit!,
              onDone: _finishToVault,
            )
          else if (isUnlocked)
            ..._buildGenerateSection()
          else
            ..._buildRecoverSection(),
        ],
      ),
    );
  }

  List<Widget> _buildGenerateSection() {
    return [
      const Text(
        'Generating a new Recovery Kit invalidates the previous one. You need to save TWO separate '
        'things — either one alone is useless:',
      ),
      const SizedBox(height: 8),
      const _BulletLine('The secret below — write it down or store it somewhere very safe. Never store it next to the QR/package.'),
      const _BulletLine('The Recovery Kit package (QR/text) — safe to email yourself, print, or save to cloud storage; it\'s encrypted and useless without the secret.'),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy ? null : _generateNewKit,
        child: const Text('Generate new Recovery Kit'),
      ),
      if (_newKit != null)
        ..._buildRevealOnceKit(
          title: 'Save both parts now — shown only once.',
          subtitle: null,
          kit: _newKit!,
          onDone: () {
            PermissionsScreen.checkAndRoute(context);
          },
        ),
    ];
  }

  List<Widget> _buildRevealOnceKit({
    required String title,
    required String? subtitle,
    required GeneratedRecoveryKit kit,
    required VoidCallback onDone,
  }) {
    return [
      const SizedBox(height: 8),
      Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      if (subtitle != null) ...[const SizedBox(height: 8), Text(subtitle)],
      const SizedBox(height: 16),
      const Text('1. Recovery secret (write down / memorize):', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            kit.printableSecret,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 18, letterSpacing: 1.2),
          ),
        ),
      ),
      const SizedBox(height: 20),
      const Text('2. Recovery Kit package (safe to export/print/email):', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Center(
        child: Container(
          padding: const EdgeInsets.all(12),
          color: Colors.white,
          child: QrImageView(data: kit.packageEncoded, size: 220),
        ),
      ),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SelectableText(kit.packageEncoded, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        ),
      ),
      const SizedBox(height: 20),
      FilledButton(onPressed: onDone, child: const Text('I\'ve saved both — Done')),
    ];
  }

  List<Widget> _buildRecoverSection() {
    return [
      const Text(
        'Lost access to every trusted device? You need BOTH the Recovery Kit package you saved '
        '(QR or text) AND the recovery secret — the secret alone is not enough.',
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _deviceNameCtrl,
        decoration: const InputDecoration(labelText: 'Name this device', border: OutlineInputBorder()),
        textCapitalization: TextCapitalization.words,
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan Kit QR'),
              onPressed: () => setState(() => _scanning = true),
            ),
          ),
        ],
      ),
      if (_scanning)
        SizedBox(
          height: 260,
          child: MobileScanner(
            onDetect: (capture) {
              final code = capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
              if (code == null) return;
              try {
                setState(() {
                  _scannedPackage = RecoveryKitPackage.decode(code);
                  _scanning = false;
                });
              } catch (_) {
                // Not a recovery-kit QR — keep scanning.
              }
            },
          ),
        ),
      if (_scannedPackage != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('Kit package loaded (${_scannedPackage!.kitId}). ✓', style: const TextStyle(color: Colors.green)),
        ),
      const SizedBox(height: 8),
      const Text('...or paste the Kit package text instead:'),
      const SizedBox(height: 8),
      TextField(
        controller: _packagePasteCtrl,
        maxLines: 2,
        decoration: const InputDecoration(hintText: 'peervault-recovery:v1:...', border: OutlineInputBorder()),
        onChanged: (_) => setState(() {}), // re-enable the button once something's pasted
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _secretCtrl,
        decoration: const InputDecoration(labelText: 'Recovery secret', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      if (_recoverError != null) Text(_recoverError!, style: const TextStyle(color: Colors.red)),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _busy ? null : _recover,
        child: _busy
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Recover vault'),
      ),
    ];
  }
}

class _BulletLine extends StatelessWidget {
  final String text;
  const _BulletLine(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('•  '),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
