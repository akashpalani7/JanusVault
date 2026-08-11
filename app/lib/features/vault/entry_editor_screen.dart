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
  final _formKey = GlobalKey<FormState>();
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

  Future<void> _toggleObscured() async {
    if (!_obscurePassword) {
      setState(() => _obscurePassword = true);
      return;
    }
    if (widget.existing == null) {
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
    if (!_formKey.currentState!.validate()) return;
    
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

  Widget _buildTextField({
    required TextEditingController controller,
    required String labelText,
    required IconData prefixIcon,
    TextInputType? keyboardType,
    bool obscureText = false,
    Widget? suffixIcon,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        obscureText: obscureText,
        keyboardType: keyboardType,
        validator: validator,
        decoration: InputDecoration(
          labelText: labelText,
          prefixIcon: Icon(prefixIcon),
          suffixIcon: suffixIcon,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          filled: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'Add login' : 'Edit login')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Website Info', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    _buildTextField(
                      controller: _websiteNameCtrl,
                      labelText: 'Website name (e.g. Google)',
                      prefixIcon: Icons.language,
                      validator: (val) => val == null || val.trim().isEmpty ? 'Required' : null,
                    ),
                    _buildTextField(
                      controller: _websiteUrlCtrl,
                      labelText: 'Website URL (e.g. https://google.com)',
                      prefixIcon: Icons.link,
                      keyboardType: TextInputType.url,
                    ),
                  ],
                ),
              ),
            ),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Credentials', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    _buildTextField(
                      controller: _usernameCtrl,
                      labelText: 'Username / email',
                      prefixIcon: Icons.person_outline,
                      keyboardType: TextInputType.emailAddress,
                    ),
                    _buildTextField(
                      controller: _passwordCtrl,
                      labelText: 'Password',
                      prefixIcon: Icons.password,
                      obscureText: _obscurePassword,
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                            onPressed: _toggleObscured,
                          ),
                          IconButton(
                            icon: const Icon(Icons.autorenew),
                            tooltip: 'Generate new',
                            onPressed: () {
                              _generatePassword();
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password generated'), duration: Duration(seconds: 1)));
                            },
                          ),
                        ],
                      ),
                      validator: (val) => val == null || val.isEmpty ? 'Required' : null,
                    ),
                  ],
                ),
              ),
            ),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                title: const Text('Password Generator Options', style: TextStyle(fontWeight: FontWeight.bold)),
                leading: const Icon(Icons.settings_suggest),
                childrenPadding: const EdgeInsets.all(16),
                children: [
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
                    runSpacing: 8,
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
                ],
              ),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                ),
                child: _saving 
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) 
                    : const Text('Save Entry', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}
