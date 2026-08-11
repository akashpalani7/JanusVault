import { computeRecordHash, deriveSyncAuthKey, hmacSha256, unwrapVek, wrapVek, decryptString, encryptString } from "./crypto.js";
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

export async function syncWithPhone(host: string, port: number, vek: CryptoKey): Promise<{ pulled: number; pushed: number; rotated?: boolean }> {
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

export async function syncWithBlePhone(vek: CryptoKey, forcePrompt = false): Promise<{ pulled: number; pushed: number; rotated?: boolean }> {
    const vekRaw = Array.from(new Uint8Array(await crypto.subtle.exportKey("raw", vek)));
    const response = await chrome.runtime.sendMessage({
        type: 'TRIGGER_BLE_SYNC',
        vekRaw,
        forcePrompt,
    });
    if (!response?.ok) {
        console.warn(`[Ext/Sync] BLE sync failed (${response?.error}) - silently falling back to Wi-Fi`);
        const lastHost = await ExtensionStorage.getLastHost();
        if (lastHost) {
            const [host, port] = lastHost.split(":");
            try {
                return await syncWithPhone(host, parseInt(port, 10), vek);
            } catch (wifiErr) {
                throw new Error(`${response?.error || 'BLE sync failed'} | Wi-Fi fallback failed: ${(wifiErr as Error).message}`);
            }
        }
        throw new Error(response?.error || 'BLE sync failed');
    }
    return { pulled: response.pulled, pushed: response.pushed, rotated: response.rotated };
}

export async function runSyncProtocol(
  transport: SyncTransport,
  vek: CryptoKey,
  resolve: (res: { pulled: number; pushed: number; rotated?: boolean }) => void,
  reject: (reason?: any) => void
) {
  const syncAuthKey = await deriveSyncAuthKey(vek);
  let pulled = 0;
  let pushed = 0;
  let sentRealData = false;
  let handshakeConfirmed = false;
  let sentNonceBase64 = "";
  let hasRotated = false;

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
          if (devices && devices.length > 0) {
            const existing = await ExtensionStorage.getDeviceList();
            
            const peerId = devices[0].deviceId;
            const existingPeer = existing.find(d => d.deviceId === peerId);
            if (existingPeer && existingPeer.revoked) {
               await transport.send(JSON.stringify({ type: "error", payload: { message: "Device connection rejected (revoked)." } } satisfies SyncMessage));
               transport.close();
               reject(new Error("The host phone has been revoked."));
               return;
            }
            
            const selfDeviceId = await ExtensionStorage.getDeviceId();
            const selfRevoked = devices.find(d => d.deviceId === selfDeviceId && d.revoked);
            if (selfRevoked) {
              await ExtensionStorage.wipeAll();
              await transport.send(JSON.stringify({ type: "error", payload: { message: "This device has been revoked and wiped itself." } } satisfies SyncMessage));
              transport.close();
              reject(new Error("This browser extension was revoked from the vault."));
              return;
            }
            
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
                if (phoneDevice.displayName && phoneDevice.displayName !== current.displayName) {
                  current.displayName = phoneDevice.displayName;
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
          resolve({ pulled, pushed, rotated: hasRotated });
          return;
        }
        case "error": {
          transport.close();
          reject(new Error((message.payload.message as string) ?? "Unknown sync error"));
          break;
        }
        case "vekRotation": {
          const wrappedNewVekBase64 = message.payload.wrappedNewVek as string | undefined;
          if (!wrappedNewVekBase64) break;
          const currentAuthKey = await deriveSyncAuthKey(vek);
          try {
            const newVek = await unwrapVek(wrappedNewVekBase64, currentAuthKey);
            
            const rawLocalKey = await ExtensionStorage.getDeviceLocalKeyRaw();
            if (!rawLocalKey) throw new Error("No device local key");
            const rawLocalKeyBytes = Uint8Array.from(atob(rawLocalKey), (c) => c.charCodeAt(0));
            const deviceLocalKey = await crypto.subtle.importKey("raw", rawLocalKeyBytes, "AES-GCM", false, ["encrypt", "decrypt"]);
            
            const allEntries = await ExtensionStorage.getAllEntries();
            const reencrypted: EncryptedEntryRecord[] = [];
            for (const entry of allEntries) {
              const websiteName = await decryptString(entry.encryptedWebsiteName, vek);
              const websiteUrl = await decryptString(entry.encryptedWebsiteUrl, vek);
              const username = await decryptString(entry.encryptedUsername, vek);
              const password = await decryptString(entry.encryptedPassword, vek);
              
              reencrypted.push({
                ...entry,
                encryptedWebsiteName: await encryptString(websiteName, newVek),
                encryptedWebsiteUrl: await encryptString(websiteUrl, newVek),
                encryptedUsername: await encryptString(username, newVek),
                encryptedPassword: await encryptString(password, newVek),
              });
            }
            await ExtensionStorage.saveAllEntries(reencrypted);
            
            const newWrapped = await wrapVek(newVek, deviceLocalKey);
            await ExtensionStorage.saveWrappedVek(newWrapped);
            
            vek = newVek;
            hasRotated = true;
            await transport.send(JSON.stringify({ type: "vekRotationAck", payload: {} } satisfies SyncMessage));
          } catch (e) {
             console.error("VEK rotation apply failed", e);
             await transport.send(JSON.stringify({ type: "error", payload: { message: "Rotation failed" } } satisfies SyncMessage));
          }
          break;
        }
        case "vekRotationAck":
          break;
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
          "Connected, but your phone never completed the handshake. Check that JanusVault is open, " +
          "the vault is unlocked there, and \"Make this device visible for sync\" is on."
        ));
      } else {
        resolve({ pulled, pushed, rotated: hasRotated });
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
    try { 
      const promise = transport.send(JSON.stringify({ type: "hello", payload: { nonce: sentNonceBase64 } } satisfies SyncMessage)); 
      if (promise && promise.catch) promise.catch(() => {});
    } catch {}
  };
  
  ping();
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
