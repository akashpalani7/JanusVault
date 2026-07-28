// PeerVault Cryptography Engine
//
// Design summary
// ---------------
// * VEK (Vault Encryption Key)  - 256-bit AES key. Generated ONCE per vault.
//   All vault entries are encrypted with this single key. It never touches
//   disk in plaintext and never leaves memory unencrypted.
// * Every trusted device stores its own copy of the VEK, wrapped (encrypted)
//   under a key that only that device can reconstruct:
//     - Local device key   -> wraps VEK for at-rest storage on that device.
//     - Pairing-code key    -> wraps VEK exactly once, for the one-shot QR
//                              handshake when a new device is added
//                              (derived via HKDF from a random pairing
//                              code — see the "Device pairing" section
//                              below for why this isn't asymmetric ECDH).
//     - Recovery key        -> wraps VEK so the Recovery Kit can restore
//                              access if every trusted device is lost.
// * All wire/storage blobs use the SAME format so the Flutter app and the
//   browser extension (Web Crypto AES-GCM) can decrypt each other's data:
//     base64( nonce[12 bytes] || ciphertext || tag[16 bytes] )
//
// No plaintext secret ever gets written to disk. Only wrapped keys and
// ciphertext blobs are persisted.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// A fully self-contained encrypted payload, portable across platforms.
/// Wire format: base64(nonce(12) || cipherText || mac(16))
class EncryptedBlob {
  final Uint8List nonce; // 12 bytes
  final Uint8List cipherText;
  final Uint8List mac; // 16 bytes (GCM tag)

  EncryptedBlob({required this.nonce, required this.cipherText, required this.mac});

  String toBase64() {
    final combined = Uint8List(nonce.length + cipherText.length + mac.length);
    combined.setRange(0, nonce.length, nonce);
    combined.setRange(nonce.length, nonce.length + cipherText.length, cipherText);
    combined.setRange(nonce.length + cipherText.length, combined.length, mac);
    return base64Encode(combined);
  }

  static EncryptedBlob fromBase64(String value) {
    final combined = base64Decode(value);
    if (combined.length < 12 + 16) {
      throw const FormatException('Encrypted blob too short to be valid');
    }
    final nonce = Uint8List.sublistView(combined, 0, 12);
    final mac = Uint8List.sublistView(combined, combined.length - 16, combined.length);
    final cipherText = Uint8List.sublistView(combined, 12, combined.length - 16);
    return EncryptedBlob(nonce: nonce, cipherText: cipherText, mac: mac);
  }
}

class CryptoEngine {
  CryptoEngine._();
  static final CryptoEngine instance = CryptoEngine._();

  final AesGcm _aesGcm = AesGcm.with256bits();
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final Sha256 _sha256 = Sha256();

  final Random _secureRandom = Random.secure();

  Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _secureRandom.nextInt(256);
    }
    return bytes;
  }

  // ---------------------------------------------------------------------
  // VEK lifecycle
  // ---------------------------------------------------------------------

  /// Generates a brand-new 256-bit Vault Encryption Key.
  /// Called exactly once, at initial vault setup, or during key rotation
  /// after a suspected compromise / recovery event.
  Future<SecretKey> generateVek() async {
    final bytes = _randomBytes(32);
    return SecretKey(bytes);
  }

  /// Wraps (encrypts) a key with another key. Used to:
  ///   - wrap the VEK under a device's local key for storage, or
  ///   - wrap the VEK under a pairing/recovery-derived key for transfer.
  Future<EncryptedBlob> wrapKey({required SecretKey keyToWrap, required SecretKey wrappingKey}) async {
    final plainBytes = await keyToWrap.extractBytes();
    return _encryptRaw(Uint8List.fromList(plainBytes), wrappingKey);
  }

  /// Reverses [wrapKey]. Throws if the wrapping key is wrong (MAC failure).
  Future<SecretKey> unwrapKey({required EncryptedBlob wrapped, required SecretKey wrappingKey}) async {
    final rawBytes = await _decryptRaw(wrapped, wrappingKey);
    return SecretKey(rawBytes);
  }

  // ---------------------------------------------------------------------
  // Vault entry encryption (data protected by the VEK)
  // ---------------------------------------------------------------------

  Future<String> encryptString({required String plainText, required SecretKey vek}) async {
    final blob = await _encryptRaw(Uint8List.fromList(utf8.encode(plainText)), vek);
    return blob.toBase64();
  }

  Future<String> decryptString({required String encoded, required SecretKey vek}) async {
    final blob = EncryptedBlob.fromBase64(encoded);
    final rawBytes = await _decryptRaw(blob, vek);
    return utf8.decode(rawBytes);
  }

  Future<EncryptedBlob> _encryptRaw(Uint8List plainBytes, SecretKey key) async {
    final nonce = _randomBytes(12);
    final secretBox = await _aesGcm.encrypt(plainBytes, secretKey: key, nonce: nonce);
    return EncryptedBlob(
      nonce: Uint8List.fromList(secretBox.nonce),
      cipherText: Uint8List.fromList(secretBox.cipherText),
      mac: Uint8List.fromList(secretBox.mac.bytes),
    );
  }

  Future<Uint8List> _decryptRaw(EncryptedBlob blob, SecretKey key) async {
    final secretBox = SecretBox(blob.cipherText, nonce: blob.nonce, mac: Mac(blob.mac));
    final clear = await _aesGcm.decrypt(secretBox, secretKey: key);
    return Uint8List.fromList(clear);
  }

  // ---------------------------------------------------------------------
  // Sync integrity hash
  // ---------------------------------------------------------------------

  /// Hash used for fast sync comparison. Computed over the *encrypted*
  /// record + mutable metadata, so devices never need to decrypt anything
  /// just to decide whether a record needs to be transferred.
  Future<String> computeRecordHash({
    required String uuid,
    required String encryptedPasswordBase64,
    required String encryptedWebsiteNameBase64,
    required String encryptedUsernameBase64,
    required DateTime lastUpdated,
    required bool deleted,
  }) async {
    final material = utf8.encode(
      '$uuid|$encryptedWebsiteNameBase64|$encryptedUsernameBase64|$encryptedPasswordBase64|'
      '${lastUpdated.toUtc().toIso8601String()}|$deleted',
    );
    final digest = await _sha256.hash(material);
    return base64Encode(digest.bytes);
  }

  // ---------------------------------------------------------------------
  // Device pairing — pairing-code + HKDF (NOT asymmetric ECDH)
  // ---------------------------------------------------------------------
  //
  // Earlier revision used X25519 ECDH here, which does not interoperate
  // with browsers: WebCrypto's X25519 support is inconsistent, and using
  // a DIFFERENT curve on the extension side (e.g. P-256) derives a
  // different shared secret entirely — the two platforms could never
  // agree on a key. Since pairing already requires an out-of-band channel
  // (the QR code itself) to move information safely, there's no need for
  // asymmetric crypto at all: a random pairing code IS the shared secret,
  // and HKDF-SHA256 is implemented identically and universally on both
  // Dart (`package:cryptography`) and every modern browser
  // (`crypto.subtle.deriveKey` with "HKDF"). The wrapped VEK is embedded
  // directly in the QR payload, so pairing works with zero network calls.

  static const List<int> _pairingSalt = [
    0x50, 0x65, 0x65, 0x72, 0x56, 0x61, 0x75, 0x6c, 0x74, 0x2d, 0x70, 0x61, 0x69, 0x72, 0x2d, 0x76, 0x32,
  ]; // ASCII "PeerVault-pair-v2" — a fixed, PUBLIC domain-separation salt.
     // It does not need to be secret; only the pairing code does.

  /// Generates a fresh, high-entropy pairing code. 128 bits is more than
  /// enough since it's single-use and short-lived (shown once in a QR
  /// code, never persisted).
  Uint8List generatePairingCode() => _randomBytes(16);

  /// Human-readable form, in case a QR scan isn't available and the user
  /// needs to type the code in manually (e.g. extension without camera
  /// access to the phone screen).
  String encodePairingCode(Uint8List code) => encodeRecoverySecret(code);

  Uint8List decodePairingCode(String printable) {
    // Reuses the exact same Crockford base32 scheme as recovery secrets,
    // just with a shorter input (16 bytes instead of 32).
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    final cleaned = printable.replaceAll('-', '').toUpperCase();
    var bits = BigInt.zero;
    for (final char in cleaned.split('')) {
      final index = alphabet.indexOf(char);
      if (index == -1) throw FormatException('Invalid character in pairing code: $char');
      bits = (bits << 5) | BigInt.from(index);
    }
    final totalBits = cleaned.length * 5;
    final paddingBits = totalBits - 128;
    bits = bits >> paddingBits;
    final bytes = Uint8List(16);
    for (var i = 15; i >= 0; i--) {
      bytes[i] = (bits & BigInt.from(0xff)).toInt();
      bits = bits >> 8;
    }
    return bytes;
  }

  /// Derives the AES-256 key both devices use to wrap/unwrap the VEK
  /// during pairing, from nothing but the pairing code. Identical output
  /// given the same code bytes, on both Dart and the browser extension.
  Future<SecretKey> derivePairingKeyFromCode(Uint8List code) {
    return _hkdf.deriveKey(secretKey: SecretKey(code), nonce: _pairingSalt, info: utf8.encode('peervault-pairing-v2'));
  }

  // ---------------------------------------------------------------------
  // ECDH LAN Pairing (Numeric PIN Comparison)
  // ---------------------------------------------------------------------

  Future<SimpleKeyPair> generateEcdhKeyPair() async {
    final ecdh = X25519(); 
    return await ecdh.newKeyPair();
  }

  String exportEcdhPublicKey(SimplePublicKey key) {
    if (key.bytes.length != 32) throw Exception("Invalid X25519 public key");
    return base64Encode(key.bytes);
  }

  SimplePublicKey importEcdhPublicKey(String base64Key) {
    return SimplePublicKey(base64Decode(base64Key), type: KeyPairType.x25519);
  }

  Future<List<int>> deriveEcdhSharedSecret(SimpleKeyPair privateKey, SimplePublicKey peerKey) async {
    final ecdh = X25519(); 
    final secret = await ecdh.sharedSecretKey(keyPair: privateKey, remotePublicKey: peerKey);
    return secret.extractBytes();
  }

  Future<String> computeEcdhPin(List<int> sharedSecret) async {
    final digest = await Hmac.sha256().calculateMac(sharedSecret, secretKey: SecretKey(utf8.encode('PeerVault-PIN')));
    final view = ByteData.view(Uint8List.fromList(digest.bytes).buffer);
    final num = view.getUint32(0, Endian.big);
    final pin = (num % 1000000).toString().padLeft(6, '0');
    return '${pin.substring(0, 3)}-${pin.substring(3)}';
  }

  Future<SecretKey> deriveEcdhWrappingKey(List<int> sharedSecret) async {
    return _hkdf.deriveKey(
      secretKey: SecretKey(sharedSecret),
      nonce: utf8.encode('PeerVault-ecdh-pair'),
      info: utf8.encode('vekwrap'),
    );
  }

  // ---------------------------------------------------------------------
  // LAN sync authentication (anti-hijack)
  // ---------------------------------------------------------------------
  //
  // Anyone on the same WiFi can open a raw TCP/WebSocket connection to the
  // phone's sync port — that's unavoidable for a LAN-discovery design.
  // What must NOT be possible is a stranger's connection being treated as
  // a trusted device: getting the device list, pushing fake vault
  // metadata, or — worst case — triggering the "Approve from your
  // browser?" biometric prompt to try to social-engineer the user into
  // approving something they didn't initiate.
  //
  // Fix: derive a symmetric key from the VEK itself (which only trusted
  // devices ever possess) and require a nonce/HMAC handshake — see
  // LanSyncService's `_performHandshake` — before EITHER side processes
  // anything else on a freshly opened connection. A device without the
  // VEK cannot produce a valid HMAC and gets disconnected immediately,
  // before it ever sees a device list, vault metadata, or an auth prompt.

  static const List<int> _syncAuthSalt = [
    0x50, 0x65, 0x65, 0x72, 0x56, 0x61, 0x75, 0x6c, 0x74, 0x2d, 0x73, 0x79, 0x6e, 0x63, 0x2d, 0x76, 0x31,
  ]; // ASCII "PeerVault-sync-v1" — fixed, public domain-separation salt.

  Future<SecretKey> deriveSyncAuthKey(SecretKey vek) {
    return _hkdf.deriveKey(secretKey: vek, nonce: _syncAuthSalt, info: utf8.encode('peervault-sync-auth-v1'));
  }

  /// HMAC-SHA256 over a plain string (deliberately NOT over arbitrary
  /// JSON) — cross-language JSON serialization can silently differ in key
  /// order/number formatting between Dart and JS, which would make an
  /// HMAC over serialized JSON fragile in exactly the wrong way. Every
  /// caller builds an explicit, simple string to MAC instead.
  Future<Uint8List> hmacSha256(SecretKey key, String data) async {
    final mac = await Hmac.sha256().calculateMac(utf8.encode(data), secretKey: key);
    return Uint8List.fromList(mac.bytes);
  }

  // ---------------------------------------------------------------------
  // Local device key (wraps VEK for at-rest storage on THIS device only)
  // ---------------------------------------------------------------------

  Future<SecretKey> generateDeviceLocalKey() async => SecretKey(_randomBytes(32));

  // ---------------------------------------------------------------------
  // Recovery Kit
  // ---------------------------------------------------------------------

  /// Generates a new high-entropy recovery secret (256 bits of raw entropy).
  /// This is what gets rendered to the user as their printable Recovery Kit.
  Uint8List generateRecoverySecret() => _randomBytes(32);

  /// Encodes raw recovery-secret bytes as a human-writable string, grouped
  /// in blocks of 5 base32 characters (Crockford alphabet, no ambiguous
  /// characters) e.g. "K7QF3-2M9XJ-...".
  String encodeRecoverySecret(Uint8List secret) {
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Crockford, no I/L/O/U
    var bits = BigInt.zero;
    for (final b in secret) {
      bits = (bits << 8) | BigInt.from(b);
    }
    final totalBits = secret.length * 8;
    final chars = <String>[];
    var remaining = totalBits;
    while (remaining > 0) {
      final take = remaining >= 5 ? 5 : remaining;
      final shift = remaining - take;
      final chunk = (bits >> shift) & BigInt.from((1 << take) - 1);
      chars.add(alphabet[chunk.toInt() << (5 - take)]);
      remaining -= take;
    }
    final raw = chars.join();
    final grouped = <String>[];
    for (var i = 0; i < raw.length; i += 5) {
      grouped.add(raw.substring(i, i + 5 > raw.length ? raw.length : i + 5));
    }
    return grouped.join('-');
  }

  /// Derives a wrapping key from the recovery secret using Argon2id, so
  /// brute-forcing the wrapped VEK is deliberately expensive even though the
  /// secret already has 256 bits of entropy (defense in depth).
  Future<SecretKey> deriveRecoveryWrappingKey({required Uint8List recoverySecret, required Uint8List salt}) async {
    final argon2 = Argon2id(parallelism: 4, memory: 19456, iterations: 2, hashLength: 32);
    return argon2.deriveKeyFromPassword(password: base64Encode(recoverySecret), nonce: salt);
  }

  Uint8List generateSalt({int length = 16}) => _randomBytes(length);
}
