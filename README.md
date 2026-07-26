# PeerVault — codebase snapshot

Two projects:

- `app/` — Flutter app (Android primary; Windows/Linux/macOS via Flutter
  Desktop). Contains the full vault engine, crypto, sync, backup/recovery,
  UI, and the native Android Autofill Framework integration.
- `extension/` — Browser extension (MV3: Chrome/Edge/Brave/Firefox).
  Autofill suggestion chip, credential capture on submit, vault search
  popup, and LAN sync client.

## What's implemented and how confident to be in it

**Storage: rewritten, no code generation.** The original version used
Isar + freezed, which conflict on pinned `analyzer` versions — a very
common, well-documented Flutter pain point. That's been removed entirely:
no `build_runner`, no `.g.dart`/`.freezed.dart` files. Models are plain
hand-written Dart classes; storage is a simple JSON-file-backed store
(`core/storage/vault_database.dart`) with write-through persistence and
atomic (write-temp-then-rename) writes. This should eliminate the
dependency-conflict errors from the previous drop. `flutter pub get`
should now resolve cleanly with no codegen step needed at all.

**Device pairing: fixed.** The previous drop used X25519 on the phone and
a P-256 placeholder on the extension — two curves that can't derive a
shared secret with each other. Both sides now use a pairing-code + HKDF
scheme instead (see `extension/PAIRING_NOTE.md` for the full explanation).
Bonus: pairing is now fully offline — the wrapped VEK travels inside the
QR code itself, no network round trip needed to pair.

**Solid, reviewed logic** (crypto, sync protocol, diff algorithm): written
carefully with matching wire formats between Dart and TypeScript. The
TypeScript half **type-checks and compiles cleanly**
(`cd extension && npm install && npm run build` — already done, output is
in `extension/dist/`, loadable as-is via `chrome://extensions` → Load
unpacked).

**Not compiled/run** (`app/`): this sandbox has no Flutter SDK and no
network access to pub.dev, so the Dart code has been written carefully —
and the exact APIs (bonsoir, cryptography, local_auth, etc.) are used
correctly per their published surface — but never actually built end to
end. Run:

```bash
cd app
flutter pub get
flutter run
```

No build_runner step is needed anymore. If `pub get` still reports a
version conflict on some other package, it'll be a normal, easy-to-read
one (a single package needing a version bump) rather than the
analyzer-pinning tangle Isar+freezed caused.

## Known gaps — read before treating this as finished

1. **BLE sync was intentionally dropped** per your request — LAN sync
   (same WiFi, or a phone hotspot with the PC/laptop connected to it) is
   the only sync path now. Both cases work identically since they're both
   just "a local IP network" to mDNS/WebSocket.
2. **Extension can't do mDNS discovery** (browsers don't expose multicast
   to service workers) — sync from the extension is by typing the phone's
   LAN address, which the app's Sync screen displays for exactly this
   reason. Pairing (getting the VEK in the first place) no longer needs
   this at all — see the pairing fix above.
3. **Android Gradle project had several build-breaking bugs, now fixed**:
   `PeerVaultAutofillService`/`PeerVaultAutofillAuthActivity` live in
   package `com.example.peervault.app`, but `AndroidManifest.xml` and
   `autofill_service_config.xml` referenced them with paths that resolved
   to a different, non-existent package — Android could never have found
   these classes at runtime, so the autofill service could never actually
   register with the OS. Separately, `build.gradle.kts` had no
   `dependencies {}` block at all despite the Kotlin code importing
   `androidx.biometric`, `androidx.fragment`, and `kotlinx.coroutines` —
   the native side could not have compiled. Both are fixed now, but
   **none of this has been run through a real Gradle build** (no Android
   SDK in this environment) — build it in Android Studio before trusting
   it fully.
4. **iOS is not addressed** — you scoped this to Android for now; iOS
   would need a separate Credential Provider Extension (Swift), which
   isn't in this drop.
5. Extension icons are placeholder PNGs, not real artwork.
6. **Phone-approval for the extension requires the phone to be reachable
   on the LAN** with "Make this device visible for sync" on — there is no
   fallback of any kind (by design, per your instruction): if the phone
   can't be reached, reveal/autofill/copy are simply refused.

## Where to start reading the code

- `app/lib/core/crypto/crypto_engine.dart` — everything else depends on
  this being correct; read it first.
- `app/lib/core/sync/sync_protocol.dart` — the whole incremental-sync
  design, plus the deviceInfo/authRequest message types, in one small,
  dependency-free file.
- `app/android/app/src/main/kotlin/com/example/peervault/app/PeerVaultAutofillService.kt`
  — the mobile autofill piece you specifically asked about.
- `extension/src/background/service-worker.ts` — the enforcement point
  for "every reveal/autofill/copy asks the phone first, no PIN, no
  fallback" — the popup and content script are UI only, they never see a
  plaintext password without going through this file's approval gate.

