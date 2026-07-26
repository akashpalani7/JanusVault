import 'dart:math';

class PasswordGeneratorOptions {
  final int length;
  final bool includeUppercase;
  final bool includeLowercase;
  final bool includeDigits;
  final bool includeSymbols;
  final bool excludeAmbiguous; // excludes l, I, 1, O, 0, etc.

  const PasswordGeneratorOptions({
    this.length = 20,
    this.includeUppercase = true,
    this.includeLowercase = true,
    this.includeDigits = true,
    this.includeSymbols = true,
    this.excludeAmbiguous = true,
  });
}

class PasswordGenerator {
  PasswordGenerator._();
  static final PasswordGenerator instance = PasswordGenerator._();

  static const _lower = 'abcdefghijklmnopqrstuvwxyz';
  static const _upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const _digits = '0123456789';
  static const _symbols = '!@#\$%^&*()-_=+[]{};:,.<>?';
  static const _ambiguous = 'lI1O0|';

  final Random _secureRandom = Random.secure();

  String generate(PasswordGeneratorOptions options) {
    var pool = '';
    final requiredChars = <String>[];

    if (options.includeLowercase) {
      final set = _strip(options, _lower);
      pool += set;
      requiredChars.add(_pick(set));
    }
    if (options.includeUppercase) {
      final set = _strip(options, _upper);
      pool += set;
      requiredChars.add(_pick(set));
    }
    if (options.includeDigits) {
      final set = _strip(options, _digits);
      pool += set;
      requiredChars.add(_pick(set));
    }
    if (options.includeSymbols) {
      final set = _strip(options, _symbols);
      pool += set;
      requiredChars.add(_pick(set));
    }

    if (pool.isEmpty) {
      throw ArgumentError('At least one character set must be enabled');
    }

    final length = max(options.length, requiredChars.length);
    final chars = <String>[...requiredChars];
    while (chars.length < length) {
      chars.add(_pick(pool));
    }
    chars.shuffle(_secureRandom);
    return chars.join();
  }

  String _strip(PasswordGeneratorOptions options, String set) {
    if (!options.excludeAmbiguous) return set;
    return set.split('').where((c) => !_ambiguous.contains(c)).join();
  }

  String _pick(String set) => set[_secureRandom.nextInt(set.length)];

  /// Rough strength estimate in bits of entropy, useful for a UI strength
  /// meter. Not a substitute for zxcvbn-style analysis, but honest about
  /// what it measures.
  double estimateEntropyBits(String password, PasswordGeneratorOptions options) {
    var poolSize = 0;
    if (options.includeLowercase) poolSize += 26;
    if (options.includeUppercase) poolSize += 26;
    if (options.includeDigits) poolSize += 10;
    if (options.includeSymbols) poolSize += _symbols.length;
    if (poolSize == 0) return 0;
    return password.length * (log(poolSize) / log(2));
  }
}
