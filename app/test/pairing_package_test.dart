import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:janusvault/core/crypto/crypto_engine.dart';
import 'package:janusvault/core/devices/device_manager.dart';

void main() {
  group('PairingPackage Tests', () {
    test('Encodes and decodes 4-part pairing package without deviceId', () {
      const code = 'ABC123';
      const wrappedVek = 'dGVzdC13cmFwcGVkLXZlaw==';
      const pkg = PairingPackage(
        pairingCodePrintable: code,
        wrappedVekForTransitBase64: wrappedVek,
      );

      final encoded = pkg.encode();
      expect(encoded, equals('janusvault-pair:v2:$code:$wrappedVek'));

      final decoded = PairingPackage.decode(encoded);
      expect(decoded.pairingCodePrintable, equals(code));
      expect(decoded.wrappedVekForTransitBase64, equals(wrappedVek));
      expect(decoded.deviceId, isNull);
    });

    test('Encodes and decodes 5-part pairing package with deviceId', () {
      const code = 'XYZ789';
      const wrappedVek = 'YWVzLWdjbS13cmFwcGVk';
      const deviceId = 'ext_4f8a2b1c';
      const pkg = PairingPackage(
        pairingCodePrintable: code,
        wrappedVekForTransitBase64: wrappedVek,
        deviceId: deviceId,
      );

      final encoded = pkg.encode();
      expect(encoded, equals('janusvault-pair:v2:$code:$wrappedVek:$deviceId'));

      final decoded = PairingPackage.decode(encoded);
      expect(decoded.pairingCodePrintable, equals(code));
      expect(decoded.wrappedVekForTransitBase64, equals(wrappedVek));
      expect(decoded.deviceId, equals(deviceId));
    });

    test('Rejects invalid format strings', () {
      expect(() => PairingPackage.decode('invalid-string'), throwsFormatException);
      expect(() => PairingPackage.decode('janusvault-pair:v1:code:vek'), throwsFormatException);
      expect(() => PairingPackage.decode('other-vault:v2:code:vek'), throwsFormatException);
      expect(() => PairingPackage.decode('janusvault-pair:v2:onlythree'), throwsFormatException);
      expect(() => PairingPackage.decode('janusvault-pair:v2:one:two:three:four'), throwsFormatException);
    });
  });

  group('Pairing Code Crockford-32 Tests', () {
    test('Generates 16-byte random pairing code and encodes/decodes correctly', () {
      final engine = CryptoEngine.instance;
      final codeBytes = engine.generatePairingCode();
      expect(codeBytes.length, equals(16));

      final printable = engine.encodePairingCode(codeBytes);
      expect(printable.isNotEmpty, isTrue);

      final decodedBytes = engine.decodePairingCode(printable);
      expect(decodedBytes, equals(codeBytes));
    });

    test('Decodes Crockford-32 with hyphens and lowercase characters', () {
      final engine = CryptoEngine.instance;
      final codeBytes = engine.generatePairingCode();
      final printable = engine.encodePairingCode(codeBytes);

      // Convert to lower case and insert extra hyphens
      final modified = printable.toLowerCase().replaceAll('-', '--');
      final decodedBytes = engine.decodePairingCode(modified);
      expect(decodedBytes, equals(codeBytes));
    });

    test('Throws FormatException on invalid Crockford-32 characters (I, L, O, U)', () {
      final engine = CryptoEngine.instance;
      expect(() => engine.decodePairingCode('1234I-56789'), throwsFormatException);
      expect(() => engine.decodePairingCode('1234L-56789'), throwsFormatException);
      expect(() => engine.decodePairingCode('1234O-56789'), throwsFormatException);
      expect(() => engine.decodePairingCode('1234U-56789'), throwsFormatException);
    });
  });

  group('Cryptographic Key Derivation & AES-GCM Wrapping', () {
    test('Derives key deterministically and wraps/unwraps VEK successfully', () async {
      final engine = CryptoEngine.instance;
      final codeBytes = engine.generatePairingCode();

      // Derive key on "Phone" side
      final phoneKey = await engine.derivePairingKeyFromCode(codeBytes);

      // Simulate 32-byte VEK
      final originalVek = await engine.generateVek();
      final originalVekBytes = await originalVek.extractBytes();

      // Wrap VEK using CryptoEngine
      final wrappedBlob = await engine.wrapKey(
        keyToWrap: originalVek,
        wrappingKey: phoneKey,
      );
      final wrappedBase64 = wrappedBlob.toBase64();

      // Derive key on "Extension" side using the same code bytes
      final extKey = await engine.derivePairingKeyFromCode(codeBytes);

      // Unwrap VEK
      final unwrappedBlob = EncryptedBlob.fromBase64(wrappedBase64);
      final decryptedVek = await engine.unwrapKey(
        wrapped: unwrappedBlob,
        wrappingKey: extKey,
      );
      final decryptedVekBytes = await decryptedVek.extractBytes();

      expect(decryptedVekBytes, equals(originalVekBytes));
    });

    test('Fails to unwrap VEK if incorrect pairing code is used', () async {
      final engine = CryptoEngine.instance;
      final correctCodeBytes = engine.generatePairingCode();
      final wrongCodeBytes = engine.generatePairingCode();

      final correctKey = await engine.derivePairingKeyFromCode(correctCodeBytes);
      final wrongKey = await engine.derivePairingKeyFromCode(wrongCodeBytes);

      final originalVek = await engine.generateVek();
      final wrappedBlob = await engine.wrapKey(
        keyToWrap: originalVek,
        wrappingKey: correctKey,
      );

      expect(
        () async => await engine.unwrapKey(wrapped: wrappedBlob, wrappingKey: wrongKey),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });
}
