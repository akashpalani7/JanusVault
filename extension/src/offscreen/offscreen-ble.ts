// @ts-nocheck
const PEERVAULT_SERVICE_UUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
const SYNC_CHARACTERISTIC_UUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567891';
const EOM_MARKER = '\x04';
const MAX_CHUNK_SIZE = 480;

let bleDevice: BluetoothDevice | null = null;
let syncCharacteristic: BluetoothRemoteGATTCharacteristic | null = null;
let incomingBuffer = '';

async function hmacSha256(key: CryptoKey, nonceBase64: string): Promise<string> {
  const nonceBytes = Uint8Array.from(atob(nonceBase64), (c) => c.charCodeAt(0));
  const signature = await crypto.subtle.sign("HMAC", key, nonceBytes);
  return btoa(String.fromCharCode(...new Uint8Array(signature)));
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'BLE_EXECUTE_AUTH') {
    executeBleAuth(message.actionLabel, message.requestId, Uint8Array.from(message.syncAuthKeyRaw))
      .then((approved) => sendResponse({ outcome: approved ? "approved" : "denied" }))
      .catch((err) => sendResponse({ outcome: "unreachable", error: err.message }));
    return true; // Keep message channel open
  }
});

async function sendJsonMessage(jsonString: string): Promise<void> {
  if (!syncCharacteristic) throw new Error('Not connected to BLE device.');
  const payload = jsonString + EOM_MARKER;
  const encoder = new TextEncoder();
  const bytes = encoder.encode(payload);
  for (let offset = 0; offset < bytes.length; offset += MAX_CHUNK_SIZE) {
    const end = Math.min(offset + MAX_CHUNK_SIZE, bytes.length);
    const chunk = bytes.slice(offset, end);
    if ('writeValueWithoutResponse' in syncCharacteristic) {
       await syncCharacteristic.writeValueWithoutResponse(chunk);
    } else {
       await syncCharacteristic.writeValue(chunk);
    }
  }
}

async function executeBleAuth(actionLabel: string, requestId: string, authKeyRaw: Uint8Array): Promise<boolean> {
  if (!navigator.bluetooth) throw new Error('Web Bluetooth API is not supported in this browser.');
  
  // Stealth pairing via cached authorizations
  const devices = await navigator.bluetooth.getDevices();
  const paired = devices.find(d => !!d.id);
  if (!paired) throw new Error("No previously authorized WebBluetooth PeerVault device found.");
  
  bleDevice = paired;
  
  const finishEarly = () => {
    try { bleDevice?.gatt?.disconnect(); } catch (e) {}
    syncCharacteristic = null;
  };

  // Removed watchAdvertisements logic because Windows Chrome regularly swallows
  // advertisement events, causing a 5-second timeout even when the device is nearby
  // and fully connectable via GATT.

  let server: any;
  for (let i = 0; i < 4; i++) {
     try {
       server = await bleDevice.gatt.connect();
       break;
     } catch(e) {
       if (i === 3) throw e;
       await new Promise(r => setTimeout(r, 1000));
     }
  }

  const service = await server.getPrimaryService(PEERVAULT_SERVICE_UUID);
  syncCharacteristic = await service.getCharacteristic(SYNC_CHARACTERISTIC_UUID);
  
  const authKey = await crypto.subtle.importKey("raw", authKeyRaw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);

  return new Promise(async (resolve, reject) => {
    let authRequestSent = false;

    // Timeout fallback matching lan sync
    const timer = setTimeout(() => {
      finishEarly();
      reject(new Error("Timeout waiting for phone BLE auth approval."));
    }, 60000);

    const finish = (approved: boolean) => {
      clearTimeout(timer);
      finishEarly();
      resolve(approved);
    };

    syncCharacteristic!.addEventListener('characteristicvaluechanged', async (event: any) => {
      const dataView = event.target.value;
      const text = new TextDecoder().decode(dataView);
      incomingBuffer += text;

      while (incomingBuffer.includes(EOM_MARKER)) {
        const eomIdx = incomingBuffer.indexOf(EOM_MARKER);
        const fullMessage = incomingBuffer.substring(0, eomIdx);
        incomingBuffer = incomingBuffer.substring(eomIdx + 1);

        try {
          const msg = JSON.parse(fullMessage);
          if (msg.type === "hello") {
            const mac = await hmacSha256(authKey, msg.payload.nonce);
            await sendJsonMessage(JSON.stringify({ type: "helloResponse", payload: { mac } }));
          } else if (msg.type === "deviceInfo" && !authRequestSent) {
            authRequestSent = true;
            await sendJsonMessage(JSON.stringify({ type: "authRequest", payload: { requestId, actionLabel } }));
          } else if (msg.type === "authResponse" && msg.payload.requestId === requestId) {
            finish(!!msg.payload.approved);
          }
        } catch (e) {
          console.error("BLE auth JSON parsing error", e);
        }
      }
    });

    try {
      await syncCharacteristic!.startNotifications();
      const nonce = crypto.getRandomValues(new Uint8Array(16));
      const sentNonceBase64 = btoa(String.fromCharCode(...nonce));
      await sendJsonMessage(JSON.stringify({ type: "hello", payload: { nonce: sentNonceBase64 } }));
    } catch (e) {
      clearTimeout(timer);
      reject(e);
    }
  });
}
