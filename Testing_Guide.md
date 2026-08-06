# 🧪 PeerVault Testing Guide

Welcome to the PeerVault beta! PeerVault is an offline-first password manager that stores your passwords **strictly on your phone**, and uses a local connection (Wi-Fi/Bluetooth) to securely autofill your desktop browser. Your PC *never* stores your passwords directly.

Follow these steps to fully test all features of the latest build.

---

## 1️⃣ Installation & Setup

**Step A: Install the Android App**
1. Extract the testing ZIP file.
2. Transfer `PeerVault_Android.apk` to your Android device and install it.
3. Open PeerVault, complete the initial setup, and create your vault.
4. **Recovery Kit Test**: During setup, you will be prompted to create a Recovery Kit. Save the printable secret and encrypted recovery package. *This is critical zero-knowledge infrastructure—test that the PDF is generated and securely exported.*

**Step B: Enable Android Autofill**
If you want to use PeerVault inside mobile apps:
1. Go to your Android **Settings** -> **Passwords & Accounts** -> **Autofill Service**.
2. Select **PeerVault**. *(If you use Brave browser on Android, ensure Brave's internal autofill settings are also set to use the Android OS Autofill).*

**Step C: Install Desktop Extension**
1. Open Chromium (Chrome / Brave / Edge) on your PC. 
2. Open a new tab and go to `chrome://flags`. Search for **"Experimental Web Platform features"** and enable it. Make sure to restart the browser. *(This allows the extension to use Web Bluetooth for background mobile pairing).*
3. Go to `chrome://extensions` and turn on **Developer mode** (top right).
4. Click **Load unpacked** and select the `PeerVault_Extension` folder from the extracted ZIP.

---

## 2️⃣ Cryptographic Pairing (Desktop to Phone)

1. Click the PeerVault icon in your desktop browser toolbar to open the extension. It will show a pairing QR code.
2. On your Android phone, open the PeerVault app, navigate to **Devices**, and tap **Add Device**.
3. Scan the QR pattern on your PC screen.
4. The devices will execute a local ECDH key exchange over either Wi-Fi (LAN) or Bluetooth (BLE). Verify that both screens indicate a successful pairing!

---

## 3️⃣ Testing Remote PC Autofill (The "Magic" Link)

1. Navigate to any website's login page on your Desktop PC (e.g., GitHub, Netflix, Reddit).
2. Click the username or password input field. The PeerVault extension chip should appear inside or below the input box.
3. Click the credential you wish to autofill.
4. **The Biometric Ping**: The extension will display a "Waiting for phone approval..." message.
5. Look at your phone: It should instantly display a native Biometric Prompt (Fingerprint/Face Unlock) asking you to authorize the PC. 
6. Scan your fingerprint. 
7. Verify that the PC browser receives the decrypted credential and instantly autofills the login form!

---

## 4️⃣ Testing Desktop Connectivity Fail-Safes (Wi-Fi vs BLE)

PeerVault uses dual-transport for reliability. Let's test the fallback system:
1. Temporarily turn **OFF** your PC's Wi-Fi (or disconnect from the LAN). Ensure Bluetooth is left ON.
2. Attempt to autofill another password on the PC browser.
3. Verify that the extension seamlessly falls back to the **Bluetooth Low Energy (BLE)** GATT server, and your phone still lights up asking for a fingerprint.

*(Bonus Test)*: Force close / swipe away the Android app from your recent apps list. Request a password from the Desktop. Verify the Android Background Sync Service still manages to intercept the network request and display an approval notification!

---

## 5️⃣ Testing Android Native Autofill & The "Save Popup"

**Password Generation and Form Detection:**
1. Open a mobile browser (Chrome/Brave) or a native Android app that requires a login.
2. Tap the username field and type an email (e.g., `test@example.com`).
3. Tap the password field. The "Unlock PeerVault" OS chip should appear on your keyboard. Tap it and scan your fingerprint.
4. Tap the **Generate Password** chip. Verify that it opens the Generator screen and automatically pre-fills `test@example.com` into the username box using intelligent view extraction!
5. Hit "Save & Fill". 

**Missing Credentials & Saving:**
1. Manually type a brand new, random password into the signup form of a mobile website and hit "Submit" or "Log In" on the website.
2. Verify that Android natively pops up a bottom sheet asking: **"Save credentials for [Website]?"** 
3. *The Lock Test*: If PeerVault locked itself in the background while you were typing, clicking "Save" on that bottom sheet should immediately pop up a Biometric Fingerprint prompt. Once unlocked, a small native Toast message should appear at the bottom of your screen saying "Saved to PeerVault!".
