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
