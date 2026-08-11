# JanusVault

JanusVault is an offline-first, decentralized password manager that bridges your Android smartphone and desktop browsers through hyper-local LAN sync and BLE GATT and Android's Quick Share(Nearby Share) for Android to Android share.

Instead of relying on remote cloud servers to store your master passwords, JanusVault strictly secures your encrypted vault on your Android device. It uses the phone's native hardware biometrics (Fingerprint/Face Unlock) to authorize everyday password usage via real-time WebSocket/BLE requests to the browser extension, resulting in an unphishable, zero-trust password management architecture.

## 🚀 Key Features

* **Cloud-Free Architecture**: Your vault is purely localized to your hardware. No central servers, no subscriptions, no remote databases. Syncing to desktop happens seamlessly over local Wi-Fi (mDNS) or Bluetooth Low Energy (BLE) or Android's Quick Share(Nearby Share) for Android to Android share.
* **Zero-Knowledge Hardware Gating**: The desktop browser extension never actually holds or caches your passwords in plaintext. Every time you autofill a form, reveal a password, or copy a credential, the extension live-pings your Android phone for cryptographic Biometric authorization.
* **Native Android OS Autofill (Robust Integration)**: Hooks natively into the Android OS Autofill Framework to supply passwords to any installed mobile app. Explicit Compatibility modes are injected to force autofill capability inside custom-rendered browsers like Chrome, Firefox, and Brave natively without extensions. Seamlessly captures form submissions to trigger native "Save Password" dialogs securely.
* **Complex Shadow DOM Piercing**: The Chromium extension is built with advanced UI heuristics designed to intelligently penetrate modern Web Component DOM isolation (Shadow Roots) commonly used in Single-Page Applications, ensuring login fields are reliably detected.
* **Seamless Local Import**: Painlessly import your existing browser passwords securely to your phone or extension. JanusVault natively parses complex CSV exports dynamically from Chrome, Brave, Edge, and Firefox.

## 🛠️ Tech Stack & Architecture

JanusVault consists of two primary components communicating over encrypted WebSockets, BLE and Android's Quick Share:

1. **The Mobile Vault (`/app`)**: Built in **Flutter & Dart**, functioning as the cryptographic center. 
    - Operates a headless Dart Background Isolate (`autofillMain`) to process dynamic Android Autofill OS requests without keeping the UI alive in memory.
    - Uses Kotlin for robust Android OS integration (Autofill tracking, Vault Saving, Bluetooth GATT server, Foreground Background Services).
2. **The Browser Extension (`/extension`)**: A modern **Manifest V3 Chromium Extension** built in **TypeScript**.
    - Integrates heavy cryptography (ECDH pairing, AES-GCM, HMAC-SHA256) seamlessly on the web layer to handshake directly with the phone.
    - Utilizes Web Bluetooth API in offscreen documents to maintain BLE pairing without disrupting the user.

## 📦 Installation & Setup

### Prerequisites
* Flutter SDK (3.4.0+)
* Node.js & npm (for building the extension)
* An Android device and Desktop Computer connected to the same Local Area Network (Wi-Fi) or paired via Bluetooth.

### 1. Building the Android App
The mobile app operates as the host server.
```bash
cd app
flutter pub get
# Connect your physical Android Device
flutter run --release
```
**Enable Native Autofill**: 
  1. After installing, go to Android **Settings -> Passwords & Accounts -> Autofill Service**, and select `JanusVault` to activate seamless OS autofill across your apps and mobile browsers! and if the browser has seperate setting for autofill service(like brave) make sure to change it to Android's AutoFill Service!

  2. Select the android's autofill service as default in your browser(chrome/brave) so that it redirects to the default autofill service(JanusVault).

**Important System Step (macOS LAN Sync):** If using macOS, you must manually go to **System Settings > Privacy & Security > Local Network** and ensure the browser (Chrome/Brave) is toggled ON, otherwise macOS drops the connection payload silently.

### 2. Required Chrome Flags (Experimental Features)
To ensure the Web Bluetooth API can connect flawlessly from an Offscreen DOM to your Android device via BLE GATT, you need to enable experimental platform features.
1. Open up Google Chrome, Brave, or Edge on your Desktop.
2. Navigate to `chrome://flags` in your URL bar.
3. Search for **"Experimental Web Platform features"** (`#enable-experimental-web-platform-features`) and set it to **Enabled**.
4. Relaunch your browser.

### 3. Building and Installing the Browser Extension
```bash
cd extension
npm install
npm run build
```
1. Open your Chromium browser (Chrome/Brave/Edge).
2. Navigate to `chrome://extensions`.
3. Enable **Developer mode** in the top right.
4. Click **Load unpacked** and select the `/extension/dist` folder generated by the build.

### 4. Pairing
Click the JanusVault extension icon in your browser toolbar to get started. Open the JanusVault app on your phone, navigate to Devices, scan the QR code displayed in your browser to perform a cryptographic ECDH key exchange. Your devices are now permanently paired!

# ═══════════════════════════════════════════════════════════════════════
# 7. FILES INVENTORY & THEIR ROLES
# ═══════════════════════════════════════════════════════════════════════

## Android Native (Kotlin)
  d:\Akash\Projects\JanusVault\app\android\app\src\main\kotlin\com\example\janusvault\app\
    ├── JanusVaultAutofillService.kt    (367 lines) — Autofill framework entry point + FieldFinder
    ├── JanusVaultAutofillAuthActivity.kt (164 lines) — Biometric unlock activity for autofill
    ├── JanusVaultAutofillGeneratorActivity.kt       — Activity for auto-generating strong passwords
    ├── AutofillUtils.kt                            — SaveInfo and dataset builder utilities
    ├── AutofillBridge.kt              (163 lines) — Flutter engine bridge for autofill
    ├── ApprovalNotifier.kt            (69 lines)  — Remote approval notification
    ├── JanusVaultRemoteApprovalActivity.kt          — Remote approval biometric activity
    ├── JanusVaultSyncForegroundService.kt (90 lines) — Background sync service
    └── JanusVaultQuickTileService.kt                — Quick settings tile for sync toggle

## Android Resources
    ├── AndroidManifest.xml            (141 lines) — Service/activity declarations
    └── res/xml/autofill_service_config.xml (31 lines) — Autofill service config

## Dart (Flutter)
  d:\Akash\Projects\JanusVault\app\lib\
    ├── autofill_entrypoint.dart       (216 lines) — Background isolate for autofill + sync
    ├── main.dart                                   — Main app entrypoint
    └── core/
        ├── sync/
        │   ├── ble_gatt_service.dart  (296 lines) — BLE GATT server (peripheral)
        │   ├── lan_sync_service.dart  (519 lines) — LAN WebSocket server + mDNS
        │   ├── sync_message_handler.dart (338 lines) — Shared sync protocol handler
        │   └── sync_protocol.dart                  — SyncMessage types + encoding
        ├── vault/
        │   ├── vault_session.dart                  — VEK session management
        │   └── vault_repository.dart               — Vault CRUD
        ├── storage/
        │   ├── vault_database.dart                 — Encrypted entry storage
        │   └── secure_key_store.dart               — Flutter secure storage wrapper
        └── crypto/
            └── crypto_engine.dart                  — All cryptographic operations

## Browser Extension (TypeScript)
  d:\Akash\Projects\JanusVault\extension\src\
    ├── content/
    │   └── detect.ts                  (503 lines) — Content script: field detection, chip UI
    ├── background/
    │   └── service-worker.ts          (579 lines) — MV3 service worker: message routing
    ├── offscreen/
    │   ├── offscreen-ble.html                      — Offscreen document for BLE
    │   └── offscreen-ble.ts           (130 lines) — BLE auth execution via Web Bluetooth
    ├── lib/
    │   ├── sync-client.ts             (349 lines) — Sync protocol client (WebSocket + BLE)
    │   ├── auth-client.ts                          — LAN phone auth request
    │   ├── crypto.ts                               — Cryptographic operations mirror
    │   ├── models.ts                               — TypeScript type definitions
    │   ├── storage.ts                              — chrome.storage.local wrapper
    │   └── pairing-client.ts                       — Pairing flow client
    └── popup/
        ├── popup.html                              — Extension popup UI
        ├── popup.css                               — Popup styles
        └── popup.ts                                — Popup logic

## Configuration
  d:\Akash\Projects\JanusVault\extension\
    ├── public/manifest.json           (37 lines) — Extension manifest (MV3)
    └── tsconfig.json                              — TypeScript config
