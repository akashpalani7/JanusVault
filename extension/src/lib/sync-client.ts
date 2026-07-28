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
export async function syncWithPhone(host: string, port: number, vek: CryptoKey): Promise<{ pulled: number; pushed: number }> {
  const syncAuthKey = await deriveSyncAuthKey(vek);

  return new Promise((resolve, reject) => {
    const socket = new WebSocket(`ws://${host}:${port}`);
    let pulled = 0;
    let pushed = 0;
    let sentRealData = false;
    let handshakeConfirmed = false; // true once the phone proves it accepted our handshake response
    let sentNonceBase64 = "";

    const sendRealDataOnceAuthenticated = async () => {
      if (sentRealData) return;
      sentRealData = true;
      handshakeConfirmed = true;

      const selfInfo = await buildSelfDeviceInfo();
      if (selfInfo) {
        socket.send(JSON.stringify({ type: "deviceInfo", payload: { devices: [selfInfo] } } satisfies SyncMessage));
      }

      const mine = await ExtensionStorage.getAllEntries();
      const metadata: RecordMeta[] = mine.map((e) => ({
        uuid: e.uuid,
        hash: e.hash,
        lastUpdated: e.lastUpdated,
        deleted: e.deleted,
      }));
      socket.send(JSON.stringify({ type: "metadata", payload: { entries: metadata } } satisfies SyncMessage));
    };

    socket.onmessage = async (event) => {
      const message = JSON.parse(event.data) as SyncMessage;
      console.log(`Sync socket: Received message type '${message.type}'`);
      try {
        switch (message.type) {
          case "hello": {
            console.log(`Sync socket: Answering phone's hello challenge...`);
            const mac = await hmacSha256(syncAuthKey, message.payload.nonce as string);
            socket.send(JSON.stringify({ type: "helloResponse", payload: { mac } } satisfies SyncMessage));
            break;
          }
          case "helloResponse": {
            const actualMac = message.payload.mac as string;
            const expectedMac = await hmacSha256(syncAuthKey, sentNonceBase64);
            console.log(`Sync socket: Phone answered our hello challenge. Valid: ${actualMac === expectedMac}`);
            if (actualMac !== expectedMac) {
                console.error("Sync socket: Handshake MAC mismatch! The extension is paired to a DIFFERENT vault than the phone, or the phone was reinstalled.");
                reject(new Error("Handshake failed! Your phone's vault does not match this extension. Please re-pair your browser."));
                socket.close();
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
            const reply: SyncMessage = { type: "records", payload: { entries: requested } };
            socket.send(JSON.stringify(reply));
            pushed += requested.length;
            break;
          }
          case "deviceInfo": {
            // First deviceInfo from the phone proves it accepted our
            // handshake response — safe to send our own real data now.
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
                  // Both sides have it — take the newer lastSyncedAt, OR revoked if either says so
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
            socket.close();
            resolve({ pulled, pushed });
            return;
          }
          case "error": {
            reject(new Error((message.payload.message as string) ?? "Unknown sync error"));
            socket.close();
            break;
          }
          default:
            break;
        }
      } catch (e) {
        reject(e);
      }
    };

    socket.onerror = () => {
      console.error(`Sync socket error: Could not connect to ${host}:${port}`);
      reject(new Error(`Could not connect to ${host}:${port}`));
    };

    // The phone sends an explicit `done` once a round is finished (see
    // lan_sync_service.dart) — handled above. The quiet timer below is a
    // fallback for edge cases (e.g. the phone crashes mid-sync without
    // sending `done`).
    let quietTimer: ReturnType<typeof setTimeout>;
    const resetQuietTimer = () => {
      clearTimeout(quietTimer);
      quietTimer = setTimeout(() => {
        socket.close();
        if (!handshakeConfirmed) {
          console.error("Sync socket: The 8-second quiet timer fired and the handshake NEVER finished. Check if your phone's VEK matches this extension's VEK.");
          reject(new Error(
            "Connected, but your phone never completed the handshake. Check that PeerVault is open, " +
            "the vault is unlocked there, and \"Make this device visible for sync\" is on.",
          ));
        } else {
          resolve({ pulled, pushed });
        }
      }, 8000);
    };
    socket.addEventListener("message", resetQuietTimer);
    socket.addEventListener("open", () => {
      console.log(`Sync socket: Opened connection to ${host}:${port}. Sending hello challenge...`);
      resetQuietTimer();
      const nonce = crypto.getRandomValues(new Uint8Array(16));
      sentNonceBase64 = btoa(String.fromCharCode(...nonce));
      socket.send(JSON.stringify({ type: "hello", payload: { nonce: sentNonceBase64 } } satisfies SyncMessage));
    });
  });
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
