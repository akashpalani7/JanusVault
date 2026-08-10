import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/generator/password_generator.dart';
import '../../core/models/vault_entry.dart';
import '../../core/storage/vault_database.dart';

class EntryEditorScreen extends ConsumerStatefulWidget {
  final VaultEntry? existing;
  const EntryEditorScreen({super.key, this.existing});

  @override
  ConsumerState<EntryEditorScreen> createState() => _EntryEditorScreenState();
}

class _EntryEditorScreenState extends ConsumerState<EntryEditorScreen> {
  late final TextEditingController _websiteNameCtrl;
  late final TextEditingController _websiteUrlCtrl;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _passwordCtrl;
  bool _obscurePassword = true;
  bool _saving = false;

  bool _useUpper = true;
  bool _useLower = true;
  bool _useDigits = true;
  bool _useSymbols = true;
  double _passwordLength = 20.0;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _websiteNameCtrl = TextEditingController(text: e?.websiteName ?? '');
    _websiteUrlCtrl = TextEditingController(text: e?.websiteUrl ?? '');
    _usernameCtrl = TextEditingController(text: e?.username ?? '');
    _passwordCtrl = TextEditingController(text: e?.password ?? '');
  }

  @override
  void dispose() {
    _websiteNameCtrl.dispose();
    _websiteUrlCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _generatePassword() {
    final opts = PasswordGeneratorOptions(
      length: _passwordLength.toInt(),
      includeUppercase: _useUpper,
      includeLowercase: _useLower,
      includeDigits: _useDigits,
      includeSymbols: _useSymbols,
    );
    final generated = ref.read(passwordGeneratorProvider).generate(opts);
    setState(() => _passwordCtrl.text = generated);
  }

  /// Reveal is free to hide (going obscured is never a security risk), but
  /// going from obscured -> visible requires a biometric check first if
  /// the vault's `requireBiometricForReveal` setting is on — this is the
  /// setting that used to be stored and shown in Settings but never
  /// actually enforced anywhere.
  Future<void> _toggleObscured() async {
    if (!_obscurePassword) {
      setState(() => _obscurePassword = true);
      return;
    }
    if (widget.existing == null) {
      // Nothing secret to "reveal" yet — this is a password the user just
      // typed or generated in this same session.
      setState(() => _obscurePassword = false);
      return;
    }
    final requireBiometric = VaultDatabase.instance.settings?.requireBiometricForReveal ?? true;
    if (!requireBiometric) {
      setState(() => _obscurePassword = false);
      return;
    }
    final result = await ref.read(biometricAuthProvider).authenticate(reason: 'Reveal this password');
    if (result.success && mounted) {
      setState(() => _obscurePassword = false);
    } else if (!result.success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.errorMessage ?? 'Authentication required to reveal this password.')),
      );
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final repo = ref.read(vaultRepositoryProvider);
      if (widget.existing == null) {
        await repo.createEntry(
          websiteName: _websiteNameCtrl.text.trim(),
          websiteUrl: _websiteUrlCtrl.text.trim(),
          username: _usernameCtrl.text.trim(),
          password: _passwordCtrl.text,
        );
      } else {
        await repo.updateEntry(
          widget.existing!,
          websiteName: _websiteNameCtrl.text.trim(),
          websiteUrl: _websiteUrlCtrl.text.trim(),
          username: _usernameCtrl.text.trim(),
          password: _passwordCtrl.text,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'Add password' : 'Edit password')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _websiteNameCtrl, decoration: const InputDecoration(labelText: 'Website name')),
          const SizedBox(height: 12),
          TextField(controller: _websiteUrlCtrl, decoration: const InputDecoration(labelText: 'Website URL')),
          const SizedBox(height: 12),
          TextField(controller: _usernameCtrl, decoration: const InputDecoration(labelText: 'Username / email')),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordCtrl,
            obscureText: _obscurePassword,
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                    onPressed: _toggleObscured,
                  ),
                  IconButton(icon: const Icon(Icons.autorenew), onPressed: _generatePassword),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('Length: ${_passwordLength.toInt()}', style: const TextStyle(fontWeight: FontWeight.w600)),
              Expanded(
                child: Slider(
                  value: _passwordLength,
                  min: 4,
                  max: 64,
                  divisions: 60,
                  label: _passwordLength.toInt().toString(),
                  onChanged: (val) {
                    setState(() => _passwordLength = val);
                    _generatePassword();
                  },
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              FilterChip(
                label: const Text('A-Z'),
                selected: _useUpper,
                onSelected: (val) {
                  if (!val && !_useLower && !_useDigits && !_useSymbols) return;
                  setState(() => _useUpper = val);
                  _generatePassword();
                },
              ),
              FilterChip(
                label: const Text('a-z'),
                selected: _useLower,
                onSelected: (val) {
                  if (!val && !_useUpper && !_useDigits && !_useSymbols) return;
                  setState(() => _useLower = val);
                  _generatePassword();
                },
              ),
              FilterChip(
                label: const Text('0-9'),
                selected: _useDigits,
                onSelected: (val) {
                  if (!val && !_useUpper && !_useLower && !_useSymbols) return;
                  setState(() => _useDigits = val);
                  _generatePassword();
                },
              ),
              FilterChip(
                label: const Text('!@#'),
                selected: _useSymbols,
                onSelected: (val) {
                  if (!val && !_useUpper && !_useLower && !_useDigits) return;
                  setState(() => _useSymbols = val);
                  _generatePassword();
                },
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving ? const CircularProgressIndicator() : const Text('Save'),
          ),
        ],
      ),
    );
  }
}
