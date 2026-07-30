import { deriveEcdhSharedSecret, deriveEcdhWrappingKey, exportJwEcdhKey, generateEcdhKeyPair, computeEcdhPin } from "./crypto.js";
import { DeviceInfo, SyncMessage } from "./models.js";
import { ExtensionStorage } from "./storage.js";

export type PairingOutcome = 
  | { success: true; wrappedVek: string; device: DeviceInfo; sharedSecret: Uint8Array } 
  | { success: false; reason: string };

export function requestLanPairing(
  host: string,
  port: number,
  deviceName: string,
  onPinReady: (pin: string) => void
): Promise<PairingOutcome> {
  return new Promise((resolve) => {
    let socket: WebSocket;
    const finish = (result: PairingOutcome) => {
      try { socket?.close(); } catch {}
      resolve(result);
    };

    try {
      socket = new WebSocket(`ws://${host}:${port}`);
    } catch {
      return finish({ success: false, reason: "Invalid IP address or unreachable network." });
    }

    let myKeyPair: CryptoKeyPair;
    let lastSharedSecret: Uint8Array | null = null;

    socket.onopen = async () => {
      try {
        myKeyPair = await generateEcdhKeyPair();
        const jwk = await exportJwEcdhKey(myKeyPair.publicKey);
        let devId = await ExtensionStorage.getDeviceId();
        if (!devId) {
          devId = `ext_${Date.now()}`;
          await ExtensionStorage.saveDeviceId(devId);
        }
        socket.send(JSON.stringify({ 
          type: "pairingRequest", 
          payload: { 
            deviceName, 
            pubKey: jwk,
            clientName: deviceName,
            platform: "browserExtension",
            deviceId: devId
          } 
        } satisfies SyncMessage));
      } catch (e) {
        finish({ success: false, reason: "Crypto exception generating ECDH." });
      }
    };

    socket.onmessage = async (event) => {
      try {
        const message = JSON.parse(event.data) as SyncMessage;

        if (message.type === "pairingChallenge") {
          const peerJwk = message.payload.pubKey as string;
          const sharedSecret = await deriveEcdhSharedSecret(myKeyPair.privateKey, peerJwk);
          lastSharedSecret = sharedSecret;
          const pin = await computeEcdhPin(sharedSecret);
          onPinReady(pin);
        } else if (message.type === "pairingSuccess") {
          const wrappedVek = message.payload.wrappedVek as string;
          const device = message.payload.device as DeviceInfo;
          // Verify that we can decrypt the VEK using the shared secret
          finish({ success: true, wrappedVek, device, sharedSecret: lastSharedSecret! });
        } else if (message.type === "error") {
          finish({ success: false, reason: message.payload.message as string });
        }
      } catch (e) {
        finish({ success: false, reason: "Malformed response from phone." });
      }
    };

    socket.onerror = () => finish({ success: false, reason: `Could not connect to ${host}:${port}. Make sure PeerVault is open on your phone.` });
    socket.onclose = () => finish({ success: false, reason: "Phone dropped the connection abruptly or rejected." });
  });
}

export function requestBlePairing(
  deviceName: string,
  onPinReady: (pin: string) => void,
  forcePrompt: boolean = false
): Promise<PairingOutcome> {
  return new Promise(async (resolve) => {
    const PEERVAULT_SERVICE_UUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
    const SYNC_CHARACTERISTIC_UUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567891';
    const EOM_MARKER = '\x04';
    
    let device: any;
    let server: any;
    
    let connectionTimeout: ReturnType<typeof setTimeout>;
    let aborted = false;
    
    const finish = (result: PairingOutcome) => {
      if (aborted) return;
      aborted = true;
      clearTimeout(connectionTimeout);
      try { if (server?.connected) server.disconnect(); } catch {}
      resolve(result);
    };

    try {
      if (!forcePrompt) {
        try {
          const devices = await (navigator as any).bluetooth.getDevices();
          device = devices.find((d: any) => !!d.id);
        } catch (e) {}
      }

      if (!device) {
        device = await (navigator as any).bluetooth.requestDevice({
          filters: [{ services: [PEERVAULT_SERVICE_UUID] }]
        });
      }
      connectionTimeout = setTimeout(() => {
        finish({ success: false, reason: "Connection timed out. The phone is unreachable or not responding." });
      }, 20000);
      
      try {
        if (device.watchingAdvertisements !== undefined) {
           await new Promise<void>((resolveAdv, rejectAdv) => {
              const advTimeout = setTimeout(() => rejectAdv(new Error("Advertisement timeout: device is no longer in range")), 5000);
              device.addEventListener("advertisementreceived", () => {
                 clearTimeout(advTimeout);
                 resolveAdv();
              }, { once: true });
              device.watchAdvertisements().catch(rejectAdv);
           });
        }
      } catch(e) {
        throw e;
      }

      let char: any;
      for (let i = 0; i < 4; i++) {
        try {
          server = await device.gatt.connect();
          if (aborted) return;
          await new Promise(r => setTimeout(r, 600)); // Crucial delay for Windows GATT cache
          if (aborted) return;
          const service = await server.getPrimaryService(PEERVAULT_SERVICE_UUID);
          if (aborted) return;
          char = await service.getCharacteristic(SYNC_CHARACTERISTIC_UUID);
          if (aborted) return;
          break; // Connected and services found
        } catch (e) {
          if (aborted) return;
          if (i === 3) throw e; // Max retries
          console.warn(`GATT dropped, retrying in 1s... (${i+1}/4)`);
          await new Promise(r => setTimeout(r, 1000));
          if (aborted) return;
        }
      }
      if (!char || aborted) return;
      await char.startNotifications();

      let myKeyPair: CryptoKeyPair;
      let lastSharedSecret: Uint8Array | null = null;
      let inboundBuffer = "";

      const send = async (msg: string) => {
        const encoder = new TextEncoder();
        const bytes = encoder.encode(msg + EOM_MARKER);
        const chunkSize = 480;
        for (let i = 0; i < bytes.length; i += chunkSize) {
          await char.writeValue(bytes.slice(i, i + chunkSize));
        }
      };

      char.addEventListener('characteristicvaluechanged', async (event: any) => {
        const dataView = event.target.value; // DataView
        const text = new TextDecoder().decode(dataView);
        console.log(`[Ext/BLE Pairing] Received chunk len=${text.length}, text: ${text}`);
        
        inboundBuffer += text;

        while (inboundBuffer.includes(EOM_MARKER)) {
          const eomIdx = inboundBuffer.indexOf(EOM_MARKER);
          const fullMessage = inboundBuffer.substring(0, eomIdx);
          inboundBuffer = inboundBuffer.substring(eomIdx + 1);
          console.log(`[Ext/BLE Pairing] Complete message assembled: ${fullMessage}`);

          try {
            const message = JSON.parse(fullMessage) as SyncMessage;

            if (message.type === "pairingChallenge") {
              const peerJwk = message.payload.pubKey as string;
              const sharedSecret = await deriveEcdhSharedSecret(myKeyPair.privateKey, peerJwk);
              lastSharedSecret = sharedSecret;
              const pin = await computeEcdhPin(sharedSecret);
              onPinReady(pin);
            } else if (message.type === "pairingSuccess") {
              const wrappedVek = message.payload.wrappedVek as string;
              const peerDevice = message.payload.device as DeviceInfo;
              finish({ success: true, wrappedVek, device: peerDevice, sharedSecret: lastSharedSecret! });
            } else if (message.type === "error") {
              finish({ success: false, reason: message.payload.message as string });
            }
          } catch (e) {
            finish({ success: false, reason: "Malformed response from phone." });
          }
        }
      });

      device.addEventListener('gattserverdisconnected', () => {
        finish({ success: false, reason: "Phone dropped the connection abruptly or rejected." });
      });

      myKeyPair = await generateEcdhKeyPair();
      const jwk = await exportJwEcdhKey(myKeyPair.publicKey);
      let devId = await ExtensionStorage.getDeviceId();
      if (!devId) {
        devId = `ext_${Date.now()}`;
        await ExtensionStorage.saveDeviceId(devId);
      }
      await send(JSON.stringify({ 
        type: "pairingRequest", 
        payload: { 
          deviceName, 
          pubKey: jwk,
          clientName: deviceName,
          platform: "browserExtension",
          deviceId: devId
        } 
      } as SyncMessage));

    } catch (e) {
      finish({ success: false, reason: `Bluetooth pairing failed: ${e instanceof Error ? e.message : String(e)}` });
    }
  });
}
