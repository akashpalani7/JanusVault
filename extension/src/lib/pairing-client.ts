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
        socket.send(JSON.stringify({ 
          type: "pairingRequest", 
          payload: { deviceName, pubKey: jwk } 
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
  onPinReady: (pin: string) => void
): Promise<PairingOutcome> {
  return new Promise(async (resolve) => {
    const PEERVAULT_SERVICE_UUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
    const SYNC_CHARACTERISTIC_UUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567891';
    const EOM_MARKER = '\x04';
    
    let device: any;
    let server: any;
    
    const finish = (result: PairingOutcome) => {
      try { if (server?.connected) server.disconnect(); } catch {}
      resolve(result);
    };

    try {
      device = await (navigator as any).bluetooth.requestDevice({
        filters: [{ services: [PEERVAULT_SERVICE_UUID] }]
      });
      let char: any;
      for (let i = 0; i < 4; i++) {
        try {
          server = await device.gatt.connect();
          await new Promise(r => setTimeout(r, 600)); // Crucial delay for Windows GATT cache
          const service = await server.getPrimaryService(PEERVAULT_SERVICE_UUID);
          char = await service.getCharacteristic(SYNC_CHARACTERISTIC_UUID);
          break; // Connected and services found
        } catch (e) {
          if (i === 3) throw e; // Max retries
          console.warn(`GATT dropped, retrying in 1s... (${i+1}/4)`);
          await new Promise(r => setTimeout(r, 1000));
        }
      }
      await char.startNotifications();

      let myKeyPair: CryptoKeyPair;
      let lastSharedSecret: Uint8Array | null = null;
      let inboundBuffer = "";

      const send = async (msg: string) => {
        const encoder = new TextEncoder();
        const bytes = encoder.encode(msg + EOM_MARKER);
        const chunkSize = 500;
        for (let i = 0; i < bytes.length; i += chunkSize) {
          await char.writeValueWithoutResponse(bytes.slice(i, i + chunkSize));
        }
      };

      char.addEventListener('characteristicvaluechanged', async (event: any) => {
        const val = new Uint8Array(event.target.value.buffer);
        const text = new TextDecoder().decode(val);
        const eomIdx = text.indexOf(EOM_MARKER);
        if (eomIdx !== -1) {
          inboundBuffer += text.substring(0, eomIdx);
          const fullMessage = inboundBuffer;
          inboundBuffer = text.substring(eomIdx + 1);

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

        } else {
          inboundBuffer += text;
        }
      });

      device.addEventListener('gattserverdisconnected', () => {
        finish({ success: false, reason: "Phone dropped the connection abruptly or rejected." });
      });

      myKeyPair = await generateEcdhKeyPair();
      const jwk = await exportJwEcdhKey(myKeyPair.publicKey);
      await send(JSON.stringify({ 
        type: "pairingRequest", 
        payload: { deviceName, pubKey: jwk } 
      } as SyncMessage));

    } catch (e) {
      finish({ success: false, reason: `Bluetooth pairing failed: ${e instanceof Error ? e.message : String(e)}` });
    }
  });
}
