# Pairing crypto — fixed

Earlier revision: the Flutter app used X25519 ECDH and this extension had a
placeholder using P-256 ECDH — two different curves that can never derive
the same shared secret. Pairing between phone and browser would have
silently failed.

**Fix implemented on both sides:** pairing no longer uses asymmetric ECDH
at all. Since pairing already happens over an out-of-band channel (a QR
code / typed string), a random pairing code IS the shared secret — both
sides derive an identical AES-256 key from it via HKDF-SHA256, using the
same fixed public salt and info string on both platforms:

- Dart: `CryptoEngine.derivePairingKeyFromCode` in `crypto_engine.dart`
- TS: `deriveKeyFromPairingCode` in `extension/src/lib/crypto.ts`

The wrapped VEK travels *inside* the QR payload itself
(`janusvault-pair:v2:<code>:<wrappedVek>`), so pairing needs zero network
calls — scan or paste the string and you're done. See
`DeviceManager.createPairingPackage` / `completeNewDevicePairing` (Dart)
and `completePairing` in `service-worker.ts` (extension) for the full flow.

**Status: implemented and type-checked** (`extension`: `npm run typecheck`
passes). Not yet exercised end-to-end against a real running phone app —
verify with an actual generated QR code once the Flutter app builds.
