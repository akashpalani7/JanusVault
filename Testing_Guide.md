# 🧪 JanusVault Testing Guide

Welcome to the JanusVault beta! JanusVault is an offline-first password manager that stores your passwords **strictly on your phone**, and uses a local connection (Wi-Fi/Bluetooth) to securely autofill your desktop browser. Your PC *never* stores your passwords directly.

Follow these steps to fully test all features of the latest build.

---

## 🆕 What's New to Test in this Build

1. **Bluetooth (BLE) Over-the-Air Pairing & Discovery**:
   - The extension pairing window features a pre-pairing checklist, dedicated "Select JanusVault Device" scanner, and a **"Phone not showing? Show All Bluetooth Devices"** fallback button (useful if your phone advertises via its OEM model name like *Galaxy*, *Pixel*, or *Redmi*).
   - Android advertisement payload is optimized to broadcast strictly the 128-bit service UUID (21 bytes), preventing Android's silent `ADVERTISE_FAILED_DATA_TOO_LARGE` error.
   - Interactive 6-digit ECDH PIN dialog and real-time status updates on both screens.
2. **Bulk Vault Sync (160+ Credentials over Wi-Fi & Bluetooth)**:
   - High-volume synchronization reliably transfers all 160+ entries without premature disconnection, packet loss, or race conditions.
   - Paced 25-record batching with socket buffer draining, an 8-second finish grace period, and a 15-second client quiet timer.
   - Extension storage quota restriction removed with the `"unlimitedStorage"` manifest permission.
   - Internal early-message buffering in the extension so initial handshake challenges are never dropped.
3. **Device Location Permission for Nearby Share**:
   - The permissions screen includes an optional "Device Location" card. Tapping **Grant Access** prompts the native Android OS dialog: *"Allow JanusVault to access this device's location?"*. This is required by Android for Nearby Connections / Wi-Fi Direct peer discovery without accessing GPS.
4. **Bottom Navigation "More" Modal Overlay**:
   - Tapping "More" in the bottom menu displays the options as a bottom sheet overlay directly over the currently active tab (Vault, Sync, or Devices) rather than switching the background.
5. **Robust Field Detection**:
   - Extension input detection uses strict tokenized keywords (`username`, `email`, `login`, `account`) matching Android's native `FieldFinder`, preventing false positives on generic form elements.

---

## 1️⃣ Installation & Setup

**Step A: Install the Android App**
1. Extract the testing ZIP file.
2. Transfer `JanusVault_Android.apk` to your Android device and install it.
3. Open JanusVault and verify the **Permissions Screen**:
   - **Background Notifications (Required)**: Grant this to allow remote autofill approvals.
   - **Nearby Devices / Bluetooth (Optional)**: Grant for offline PC BLE sync.
   - **Device Location (Optional - Nearby Share)**: Tap **Grant Access** and verify that Android shows the system prompt: *"Allow JanusVault to access this device's location?"*. This is needed for local peer discovery over Nearby Connections / WiFi Direct without tracking your GPS.
4. Complete initial setup, choose your Master Password, and create your vault.
5. **Recovery Kit Test**: During setup, you will be prompted to create a Recovery Kit. Save the printable secret and encrypted recovery package (copyable text / JSON file). *This is critical zero-knowledge infrastructure—test that the recovery secret and package are securely exported.*

**Step B: Enable Android Autofill**
If you want to use JanusVault inside mobile apps:
1. Go to your Android **Settings** -> **Passwords & Accounts** -> **Autofill Service**.
2. Select **JanusVault**. *(If you use Brave browser on Android, ensure Brave's internal autofill settings are also set to use the Android OS Autofill).*

**Step C: Install Desktop Extension**
1. Open Chromium (Chrome / Brave / Edge) on your PC. 
2. Open a new tab and go to `chrome://flags`. Search for **"Experimental Web Platform features"** (`#enable-experimental-web-platform-features`) and **"Web Bluetooth"** (`#enable-web-bluetooth`). Set them to **Enabled** and restart your browser.
3. Go to `chrome://extensions` and turn on **Developer mode** (top right).
4. Click **Load unpacked** and select the `JanusVault_Extension` folder from the extracted ZIP.

---

## 2️⃣ Cryptographic Pairing (Desktop to Phone)

You can pair using either **QR Code** or **Over-The-Air Bluetooth (BLE)**:

### Option A: QR Code Pairing (Instant & Offline)
1. Open the JanusVault extension in your desktop browser, or tap **Add Device** in the JanusVault Android app under **Devices**.
2. A pairing QR code containing a versioned pairing package (`janusvault-pair:v2:<code>:<wrappedVek>:<deviceId>`) is generated, authenticated via HKDF-SHA256 from a 6-character Crockford-32 code.
3. Scan the QR code or enter the 6-character pairing code.
4. The devices unwrap the vault encryption key and exchange device identities over local Wi-Fi (LAN) or Bluetooth (BLE). Verify that both screens indicate a successful pairing and the new device appears in **Trusted Devices**!

### Option B: Bluetooth (BLE) Pairing Test
1. On your phone: Open JanusVault -> Go to **Sync** -> Select the **Bluetooth (BLE)** tab -> Turn ON **"Advertise via Bluetooth"**. Ensure your phone's Bluetooth is ON.
2. On your PC: Open the JanusVault extension popup -> Under "Pair New Device", select the **Bluetooth** tab -> Click **"Start Bluetooth Pairing"**.
3. A pairing window will pop up:
   - Click **"Select JanusVault Device"**. A browser device picker will appear.
   - If your phone is displayed, select it and click **Pair**.
   - *If your phone does not appear under the filtered search* (some Android models advertise under their hardware model name rather than service UUID), click the secondary button: **"Phone not showing? Show All Bluetooth Devices"** and choose your phone's name (e.g. *Pixel 7*, *Galaxy S22*, *Redmi*).
4. **PIN Verification Dialog**: Look at both screens:
   - The desktop browser will show a large green 6-digit PIN (e.g. `123456`).
   - The mobile app will pop up an approval dialog showing the identical 6-digit PIN and the browser device name.
5. Tap **Approve** on your phone.
6. Verify that the desktop browser indicates **"Paired successfully!"** and closes the pairing window, and the extension vault is immediately unlocked.

---

## 3️⃣ Testing Remote PC Autofill (The "Magic" Link)

1. Navigate to any website's login page on your Desktop PC (e.g., GitHub, Netflix, Reddit).
2. Click the username or password input field. The JanusVault extension chip should appear inside or below the input box.
3. Click the credential you wish to autofill.
4. **The Biometric Ping**: The extension will display a "Waiting for phone approval..." message.
5. Look at your phone: It should instantly display a native Biometric Prompt (Fingerprint/Face Unlock) asking you to authorize the PC. 
6. Scan your fingerprint. 
7. Verify that the PC browser receives the decrypted credential and instantly autofills the login form!

---

## 4️⃣ Testing Bulk Vault Sync (160+ Credentials)

Test syncing large vaults to verify packet reliability and absence of timeouts:
1. Ensure your phone vault has multiple passwords (e.g., 50 to 160+ entries loaded via CSV import or created in the app).
2. **Wi-Fi Bulk Sync**:
   - In the extension popup, enter your phone's Wi-Fi IP and port from the phone's Sync tab (e.g., `192.168.1.15:51827`) or click **Auto-Probe Mobile Hotspot** if connected to phone hotspot.
   - Click **Sync with Phone**.
   - Observe the live counter: `Syncing — Pulled: X, Pushed: Y`.
   - Verify that sync finishes with a green checkmark `✅ Synced — pulled [count], pushed 0` without freezing or disconnecting prematurely.
   - Search your passwords in the extension—all 160+ entries should be listed and searchable!
3. **Bluetooth (BLE) Sync**:
   - Ensure "Advertise via Bluetooth" is ON in the phone's Sync tab.
   - Click **Sync with Phone (Bluetooth)** in the extension.
   - Verify that Bluetooth synchronization succeeds and pulls updated records.

*(Bonus Test)*: Force close / swipe away the Android app from your recent apps list. Request a password from the Desktop. Verify the Android Background Sync Service still manages to intercept the network request and display an approval notification!

---

## 5️⃣ Testing Android Native Autofill & The "Save Popup"

**Password Generation and Form Detection:**
1. Open a mobile browser (Chrome/Brave) or a native Android app that requires a login.
2. Tap the username field and type an email (e.g., `test@example.com`).
3. Tap the password field. The "Unlock JanusVault" OS chip should appear on your keyboard. Tap it and scan your fingerprint.
4. Tap the **Generate Password** chip. Verify that it opens the Generator screen and automatically pre-fills `test@example.com` into the username box using intelligent view extraction!
5. Hit "Save & Fill". 

**Missing Credentials & Saving:**
1. Manually type a brand new, random password into the signup form of a mobile website and hit "Submit" or "Log In" on the website.
2. Verify that Android natively pops up a bottom sheet asking: **"Save credentials for [Website]?"** 
3. *The Lock Test*: If JanusVault locked itself in the background while you were typing, clicking "Save" on that bottom sheet should immediately pop up a Biometric Fingerprint prompt. Once unlocked, a small native Toast message should appear at the bottom of your screen saying "Saved to JanusVault!".

---

## 6️⃣ Advanced Security & Revocation (The "Wipe" Test)

1. **Revoke a Device:** On the Android app, go to **Devices** and click the red "Revoke device" icon next to a paired browser. Confirm the revocation.
2. **VEK Rotation:** When prompted during revocation, choose **Rotate Key**. *Verify that Android successfully re-encrypts the vault without crashing.*
3. **The Wipe Protocol:** Open the *revoked* browser extension on the PC and attempt an Autofill on any webpage or sync.
4. Verify that the Android app *instantly physically rejects the connection* behind the scenes, and the Chrome extension *immediately wipes its memory* and locks itself, booting you back to the "Pair New Device" screen!

---

## 7️⃣ Network Transport Testing (Wi-Fi vs Mobile Hotspot)

If standard mDNS `.local` resolution fails on corporate/public Wi-Fi networks (which frequently block local cross-talk):
1. In the Chrome extension, you can use **Auto-Probe Mobile Hotspot**, **Saved / Last Used IP**, or **Manual IP Entry**.
2. When your PC is connected to your Android phone's Mobile Hotspot, click **Auto-Probe Mobile Hotspot** or enter the phone's actual Wi-Fi/Hotspot IP shown in the Android app under the **Sync** tab (e.g. `192.168.43.1:51827`).
3. Try to autofill or sync. Verify that the PC connects directly into the Android app over the host IP without requiring `.local` Bonjour resolution.

---

## 8️⃣ UI Refinements 
* **Bottom Navigation "More" Overlay**: Navigate to the **Sync** or **Devices** screen. Tap **More** in the bottom navigation bar. Verify that the active screen (Sync or Devices) remains open and visible in the background while the "More" bottom sheet opens as an overlay, and the "More" tab is selected. Dismissing the menu returns smoothly to the active tab without resetting back to the Vault list.
* **Cancel Generated Passwords**: Open the extension popup, click "Generate Password", and try explicitly clicking the new "Cancel" button or clicking "outside" the modal box to ensure the UI closes smoothly.
* **Autofill Domain Filtering**: When clicking the credential inline-popup on a domain like `example.com`, verify that it strictly lists passwords for `example.com` and does *not* accidentally list credentials for completely unrelated `.com` domains in the dropdown.

---

## 9️⃣ Troubleshooting & Testing Configurations

**Extension Testing (Disabling Built-in Browser Autofill)**
To properly evaluate the JanusVault browser extension without UI glitches, you must disable the browser's native password manager:
* **Chrome / Brave / Edge:** Go to **Settings > Autofill and passwords > Password Manager > Settings**. Toggle OFF **"Offer to save passwords"** and **"Auto Sign-in"**.

**macOS LAN Sync Failing**
If you are testing on macOS and the browser extension fails to connect to the phone over Wi-Fi, macOS is likely blocking local network bridging. You must manually go to **System Settings > Privacy & Security > Local Network** and ensure your browser (Chrome/Brave/Edge) is toggled ON. Without this exception, macOS will silently drop the payload.
