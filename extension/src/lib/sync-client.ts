import { computeRecordHash } from "./crypto.js";
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
 */
export async function syncWithPhone(host: string, port: number): Promise<{ pulled: number; pushed: number }> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(`ws://${host}:${port}`);
    let pulled = 0;
    let pushed = 0;

    socket.onopen = async () => {
      const selfInfo = await buildSelfDeviceInfo();
      if (selfInfo) {
        const deviceMessage: SyncMessage = { type: "deviceInfo", payload: { devices: [selfInfo] } };
        socket.send(JSON.stringify(deviceMessage));
      }

      const mine = await ExtensionStorage.getAllEntries();
      const metadata: RecordMeta[] = mine.map((e) => ({
        uuid: e.uuid,
        hash: e.hash,
        lastUpdated: e.lastUpdated,
        deleted: e.deleted,
      }));
      const message: SyncMessage = { type: "metadata", payload: { entries: metadata } };
      socket.send(JSON.stringify(message));
    };

    socket.onmessage = async (event) => {
      const message = JSON.parse(event.data) as SyncMessage;
      try {
        switch (message.type) {
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
            // The phone's trusted-device list is authoritative; this
            // browser doesn't show its own device list UI today, but we
            // still record that a real sync round happened.
            await ExtensionStorage.saveLastSyncedAt(new Date().toISOString());
            break;
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

    socket.onerror = () => reject(new Error(`Could not connect to ${host}:${port}`));

    // The phone side doesn't send an explicit "done" today (see
    // lan_sync_service.dart) — it just stops sending once it's replied to
    // everything, so we close after a short quiet period.
    let quietTimer: ReturnType<typeof setTimeout>;
    const resetQuietTimer = () => {
      clearTimeout(quietTimer);
      quietTimer = setTimeout(() => {
        socket.close();
        resolve({ pulled, pushed });
      }, 1500);
    };
    socket.addEventListener("message", resetQuietTimer);
    socket.addEventListener("open", resetQuietTimer);
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
