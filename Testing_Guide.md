# 🧪 JanusVault Testing Guide

Welcome to the JanusVault beta! JanusVault is an offline-first password manager that stores your passwords **strictly on your phone**, and uses a local connection (Wi-Fi/Bluetooth) to securely autofill your desktop browser. Your PC *never* stores your passwords directly.

Follow these steps to fully test all features of the latest build.

---

## 1️⃣ Installation & Setup

**Step A: Install the Android App**
1. Extract the testing ZIP file.
2. Transfer `JanusVault_Android.apk` to your Android device and install it.
3. Open JanusVault, complete the initial setup, and create your vault.
4. **Recovery Kit Test**: During setup, you will be prompted to create a Recovery Kit. Save the printable secret and encrypted recovery package. *This is critical zero-knowledge infrastructure—test that the PDF is generated and securely exported.*

**Step B: Enable Android Autofill**
If you want to use JanusVault inside mobile apps:
1. Go to your Android **Settings** -> **Passwords & Accounts** -> **Autofill Service**.
2. Select **JanusVault**. *(If you use Brave browser on Android, ensure Brave's internal autofill settings are also set to use the Android OS Autofill).*

**Step C: Install Desktop Extension**
1. Open Chromium (Chrome / Brave / Edge) on your PC. 
2. Open a new tab and go to `chrome://flags`. Search for **"Experimental Web Platform features"** and enable it. Make sure to restart the browser. *(This allows the extension to use Web Bluetooth for background mobile pairing).*
3. Go to `chrome://extensions` and turn on **Developer mode** (top right).
4. Click **Load unpacked** and select the `JanusVault_Extension` folder from the extracted ZIP.

---

## 2️⃣ Cryptographic Pairing (Desktop to Phone)

1. Click the JanusVault icon in your desktop browser toolbar to open the extension. It will show a pairing QR code.
2. On your Android phone, open the JanusVault app, navigate to **Devices**, and tap **Add Device**.
3. Scan the QR pattern on your PC screen.
4. The devices will execute a local ECDH key exchange over either Wi-Fi (LAN) or Bluetooth (BLE). Verify that both screens indicate a successful pairing!

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

## 4️⃣ Testing Desktop Connectivity Fail-Safes (Wi-Fi vs BLE)

JanusVault uses dual-transport for reliability. Let's test the fallback system:
1. Temporarily turn **OFF** your PC's Wi-Fi (or disconnect from the LAN). Ensure Bluetooth is left ON.
2. Attempt to autofill another password on the PC browser.
3. Verify that the extension seamlessly falls back to the **Bluetooth Low Energy (BLE)** GATT server, and your phone still lights up asking for a fingerprint.

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
1. Keep the PC paired. In the Chrome extension, click the Network dropdown and switch from **Wi-Fi** to **Mobile Hotspot**. 
2. *Verify that the extension automatically fills the static target IP to `192.0.0.2:51827`.*
3. Turn on your Android phone's Mobile Hotspot and connect your PC to it directly.
4. Try to autofill or sync. Verify that the PC can bypass the blocked local network by tunneling directly into the Android app over the static host IP without requiring `.local` Bonjour resolution.

---

## 8️⃣ UI Refinements 
* **Cancel Generated Passwords**: Open the extension popup, click "Generate Password", and try explicitly clicking the new "Cancel" button or clicking "outside" the modal box to ensure the UI closes smoothly.
* **Autofill Domain Filtering**: When clicking the credential inline-popup on a domain like `example.com`, verify that it strictly lists passwords for `example.com` and does *not* accidentally list credentials for completely unrelated `.com` domains in the dropdown.

---

## 9️⃣ Troubleshooting & Testing Configurations

**Extension Testing (Disabling Built-in Browser Autofill)**
To properly evaluate the JanusVault browser extension without UI glitches, you must disable the browser's native password manager:
* **Chrome / Brave / Edge:** Go to **Settings > Autofill and passwords > Password Manager > Settings**. Toggle OFF **"Offer to save passwords"** and **"Auto Sign-in"**.

**macOS LAN Sync Failing**
If you are testing on macOS and the browser extension fails to connect to the phone over Wi-Fi, macOS is likely blocking local network bridging. You must manually go to **System Settings > Privacy & Security > Local Network** and ensure your browser (Chrome/Brave/Edge) is toggled ON. Without this exception, macOS will silently drop the payload.
