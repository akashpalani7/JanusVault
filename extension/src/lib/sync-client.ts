import { computeRecordHash, deriveSyncAuthKey, hmacSha256 } from "./crypto.js";
import { DeviceInfo, EncryptedEntryRecord, RecordMeta, SyncMessage } from "./models.js";
import { ExtensionStorage } from "./storage.js";

async function buildSelfDeviceInfo(): Promise<DeviceInfo | null> {
  const deviceId = await ExtensionStorage.getDeviceId();
  if (!deviceId) return null; // not paired yet
  const now = new Date().toISOString();
  const pairedAt = (await ExtensionStorage.getPairedAt()) ?? now;
  const displayName = await ExtensionStorage.getDisplayName();
  return { deviceId, displayName, platform: "browserExtension", pairedAt, lastSyncedAt: now, revoked: false };
}

/**
 * Client-only implementation of the same protocol used in
 * app/lib/core/sync/sync_protocol.dart + lan_sync_service.dart. Browser
 * extensions cannot host a TCP/WebSocket SERVER or do mDNS discovery from
 * a service worker, so this only ever connects OUT to the phone app,
 * which must be reachable at a known host:port (typed in once from the
 * address the phone's Sync screen displays — see SyncScreen in the app).
 *
 * `vek` is used to derive the same anti-hijack handshake key the phone
 * expects (see CryptoEngine.deriveSyncAuthKey / crypto.ts's mirror) — the
 * phone won't process our metadata/records/deviceInfo at all until we've
 * answered its nonce challenge correctly. We wait to see the phone's own
 * `deviceInfo` message (sent only once it has verified us) before sending
 * anything real, rather than assuming any particular message ordering.
 */
export interface SyncTransport {
  send(message: string): Promise<void>;
  close(): void;
  onMessage: ((message: string) => void) | null;
  onError: ((err: Error) => void) | null;
}

export async function syncWithPhone(host: string, port: number, vek: CryptoKey): Promise<{ pulled: number; pushed: number }> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(`ws://${host}:${port}`);
    const transport: SyncTransport = {
      send: async (msg) => { socket.send(msg); return Promise.resolve(); },
      close: () => socket.close(),
      onMessage: null,
      onError: null,
    };

    socket.onmessage = (event) => transport.onMessage?.(event.data);
    socket.onerror = () => {
      console.error(`Sync socket error: Could not connect to ${host}:${port}`);
      const err = new Error(`Could not connect to ${host}:${port}`);
      if (transport.onError) transport.onError(err);
      else reject(err);
    };
    socket.addEventListener("open", () => runSyncProtocol(transport, vek, resolve, reject));
  });
}

export async function syncWithBlePhone(vek: CryptoKey, forcePrompt = false): Promise<{ pulled: number; pushed: number }> {
  const PEERVAULT_SERVICE_UUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
  const SYNC_CHARACTERISTIC_UUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567891';
  const EOM_MARKER = '\x04';

  let device: any;
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

  let server: any;
  let char: any;
  let aborted = false;

  await new Promise<void>(async (resolveConnection, rejectConnection) => {
    const connectionTimeout = setTimeout(() => {
      aborted = true;
      if (server?.connected) { try { server.disconnect(); } catch{} }
      rejectConnection(new Error("Connection timed out. The phone is unreachable or not responding."));
    }, 20000);

    // Removed watchAdvertisements logic because Windows Chrome regularly swallows
    // advertisement events, causing a 5-second timeout even when the device is nearby
    // and fully connectable via GATT.

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
        if (i === 3) {
          clearTimeout(connectionTimeout);
          return rejectConnection(e);
        }
        console.warn(`GATT dropped during sync, retrying in 1s... (${i+1}/4)`);
        if (server?.connected) try { server.disconnect(); } catch{}
        await new Promise(r => setTimeout(r, 1000));
        if (aborted) return;
      }
    }
    
    clearTimeout(connectionTimeout);
    resolveConnection();
  });

  if (aborted || !char) throw new Error("GATT connection aborted.");
  
  await char.startNotifications();
  await new Promise(r => setTimeout(r, 500)); // Give Windows BT stack time to prepare for instantaneous responses

  return new Promise((resolve, reject) => {
    let inboundBuffer = "";
    let closing = false;
    
    const transport: SyncTransport = {
      send: async (msg) => {
        const encoder = new TextEncoder();
        const bytes = encoder.encode(msg + EOM_MARKER);
        const chunkSize = 480;
        for (let i = 0; i < bytes.length; i += chunkSize) {
          await char.writeValue(bytes.slice(i, i + chunkSize));
        }
      },
      close: () => {
        if (closing) return;
        closing = true;
        if (server.connected) {
          try { server.disconnect(); } catch {}
        }
      },
      onMessage: null,
      onError: null,
    };

    char.addEventListener('characteristicvaluechanged', (event: any) => {
      const dataView = event.target.value; // DataView
      const text = new TextDecoder().decode(dataView);
      console.log(`[Ext/BLE Sync] Received chunk len=${text.length}`);

      inboundBuffer += text;

      while (inboundBuffer.includes(EOM_MARKER)) {
        const eomIdx = inboundBuffer.indexOf(EOM_MARKER);
        const fullMessage = inboundBuffer.substring(0, eomIdx);
        inboundBuffer = inboundBuffer.substring(eomIdx + 1);
        console.log(`[Ext/BLE Sync] Complete message assembled (type extraction pending)`);

        try {
          const message = JSON.parse(fullMessage) as SyncMessage;
          transport.onMessage?.(fullMessage);
        } catch (e) {
          console.error("Failed to parse BLE message", e);
        }
      }
    });

    device.addEventListener('gattserverdisconnected', () => {
      if (closing) return; // Ignore disconnect events if we intentionally closed
      const err = new Error("BLE connection unexpectedly disconnected");
      if (transport.onError) transport.onError(err);
      else reject(err);
    });

    runSyncProtocol(transport, vek, resolve, reject);
  });
}

async function runSyncProtocol(
  transport: SyncTransport,
  vek: CryptoKey,
  resolve: (res: { pulled: number; pushed: number }) => void,
  reject: (reason?: any) => void
) {
  const syncAuthKey = await deriveSyncAuthKey(vek);
  let pulled = 0;
  let pushed = 0;
  let sentRealData = false;
  let handshakeConfirmed = false;
  let sentNonceBase64 = "";

  const sendRealDataOnceAuthenticated = async () => {
    if (sentRealData) return;
    sentRealData = true;
    handshakeConfirmed = true;

    const selfInfo = await buildSelfDeviceInfo();
    if (selfInfo) {
      await transport.send(JSON.stringify({ type: "deviceInfo", payload: { devices: [selfInfo] } } satisfies SyncMessage));
    }

    const mine = await ExtensionStorage.getAllEntries();
    const metadata: RecordMeta[] = mine.map((e) => ({
      uuid: e.uuid,
      hash: e.hash,
      lastUpdated: e.lastUpdated,
      deleted: e.deleted,
    }));
    await transport.send(JSON.stringify({ type: "metadata", payload: { entries: metadata } } satisfies SyncMessage));
  };

  transport.onMessage = async (rawJson: string) => {
    const message = JSON.parse(rawJson) as SyncMessage;
    console.log(`Sync transport: Received message type '${message.type}'`);
    try {
      switch (message.type) {
        case "hello": {
          console.log(`Sync transport: Answering phone's hello challenge...`);
          const mac = await hmacSha256(syncAuthKey, message.payload.nonce as string);
          await transport.send(JSON.stringify({ type: "helloResponse", payload: { mac } } satisfies SyncMessage));
          break;
        }
        case "helloResponse": {
          const actualMac = message.payload.mac as string;
          const expectedMac = await hmacSha256(syncAuthKey, sentNonceBase64);
          console.log(`Sync transport: Phone answered our hello challenge. Valid: ${actualMac === expectedMac}`);
          if (actualMac !== expectedMac) {
              console.error("Sync transport: Handshake MAC mismatch!");
              transport.close();
              reject(new Error("Handshake failed! Your phone's vault does not match this extension. Please re-pair your browser."));
          }
          break;
        }
        case "records": {
          const entries = message.payload.entries as EncryptedEntryRecord[];
          await ExtensionStorage.upsertEntries(entries);
          pulled += entries.length;
          break;
        }
        case "request": {
          const uuids = message.payload.uuids as string[];
          const mine = await ExtensionStorage.getAllEntries();
          const requested = mine.filter((e) => uuids.includes(e.uuid));
          await transport.send(JSON.stringify({ type: "records", payload: { entries: requested } } satisfies SyncMessage));
          pushed += requested.length;
          break;
        }
        case "deviceInfo": {
          await sendRealDataOnceAuthenticated();
          const devices = message.payload.devices as DeviceInfo[];
          if (devices) {
            const existing = await ExtensionStorage.getDeviceList();
            const byId = new Map(existing.map((d) => [d.deviceId, d]));
            for (const phoneDevice of devices) {
              const current = byId.get(phoneDevice.deviceId);
              if (!current) {
                byId.set(phoneDevice.deviceId, phoneDevice);
              } else {
                if (new Date(phoneDevice.lastSyncedAt) > new Date(current.lastSyncedAt)) {
                  current.lastSyncedAt = phoneDevice.lastSyncedAt;
                }
                if (phoneDevice.revoked) {
                  current.revoked = true;
                }
              }
            }
            await ExtensionStorage.saveDeviceList(Array.from(byId.values()));
          }
          await ExtensionStorage.saveLastSyncedAt(new Date().toISOString());
          break;
        }
        case "done": {
          transport.close();
          resolve({ pulled, pushed });
          return;
        }
        case "error": {
          transport.close();
          reject(new Error((message.payload.message as string) ?? "Unknown sync error"));
          break;
        }
      }
    } catch (e) {
      transport.close();
      reject(e);
    }
  };

  transport.onError = (err) => {
    transport.close();
    reject(err);
  };

  let quietTimer: ReturnType<typeof setTimeout>;
  const resetQuietTimer = () => {
    clearTimeout(quietTimer);
    quietTimer = setTimeout(() => {
      transport.close();
      if (!handshakeConfirmed) {
        reject(new Error(
          "Connected, but your phone never completed the handshake. Check that PeerVault is open, " +
          "the vault is unlocked there, and \"Make this device visible for sync\" is on."
        ));
      } else {
        resolve({ pulled, pushed });
      }
    }, 8000);
  };
  
  // Wrap incoming onMessage to also reset timer
  const originalOnMessage = transport.onMessage;
  transport.onMessage = (msg) => {
    resetQuietTimer();
    return originalOnMessage?.(msg);
  };

  console.log(`Sync transport: Opened connection. Sending hello challenge...`);
  resetQuietTimer();
  const nonce = crypto.getRandomValues(new Uint8Array(16));
  sentNonceBase64 = btoa(String.fromCharCode(...nonce));
  
  const ping = () => {
    if (handshakeConfirmed) return;
    try { transport.send(JSON.stringify({ type: "hello", payload: { nonce: sentNonceBase64 } } satisfies SyncMessage)); } catch {}
  };
  
  ping();
  setTimeout(ping, 300);
  setTimeout(ping, 1000);
  setTimeout(ping, 2500);
  setTimeout(ping, 5000);
}

/** Recomputes a record's sync hash after a local edit/capture, using the
 * exact same formula as CryptoEngine.computeRecordHash on both other
 * platforms. */
export async function recomputeHash(entry: Omit<EncryptedEntryRecord, "hash">): Promise<string> {
  return computeRecordHash({
    uuid: entry.uuid,
    encryptedWebsiteNameBase64: entry.encryptedWebsiteName,
    encryptedUsernameBase64: entry.encryptedUsername,
    encryptedPasswordBase64: entry.encryptedPassword,
    lastUpdatedIso: entry.lastUpdated,
    deleted: entry.deleted,
  });
}
