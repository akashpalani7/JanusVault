import { EncryptedEntryRecord } from "./models.js";

const ENTRIES_KEY = "peervault.entries";
const DEVICE_LOCAL_KEY_RAW = "peervault.device_local_key_raw"; // base64, chrome.storage.local is NOT hardware-backed
const WRAPPED_VEK_KEY = "peervault.wrapped_vek";
const DEVICE_ID_KEY = "peervault.device_id";
const DEVICE_PAIRED_AT_KEY = "peervault.device_paired_at";
const DEVICE_LAST_SYNCED_AT_KEY = "peervault.device_last_synced_at";
const DEVICE_DISPLAY_NAME_KEY = "peervault.device_display_name";
const LAST_HOST_KEY = "peervault.last_sync_host"; // "host:port" — where to reach the phone for both sync AND every auth approval

/**
 * chrome.storage.local is sandboxed per-extension but is NOT hardware
 * security module backed the way flutter_secure_storage is on mobile.
 * That's an accepted tradeoff of the browser platform — same as every
 * other browser-based password manager. Only ciphertext and wrapped keys
 * are ever stored here, never a plaintext VEK.
 */
export class ExtensionStorage {
  static async getAllEntries(): Promise<EncryptedEntryRecord[]> {
    const result = await chrome.storage.local.get(ENTRIES_KEY);
    return (result[ENTRIES_KEY] as EncryptedEntryRecord[]) ?? [];
  }

  static async saveAllEntries(entries: EncryptedEntryRecord[]): Promise<void> {
    await chrome.storage.local.set({ [ENTRIES_KEY]: entries });
  }

  static async upsertEntries(incoming: EncryptedEntryRecord[]): Promise<void> {
    const existing = await this.getAllEntries();
    const byUuid = new Map(existing.map((e) => [e.uuid, e]));
    for (const entry of incoming) {
      const current = byUuid.get(entry.uuid);
      if (!current || new Date(entry.lastUpdated) > new Date(current.lastUpdated)) {
        byUuid.set(entry.uuid, entry);
      }
    }
    await this.saveAllEntries(Array.from(byUuid.values()));
  }

  static async getDeviceLocalKeyRaw(): Promise<string | null> {
    const result = await chrome.storage.local.get(DEVICE_LOCAL_KEY_RAW);
    return (result[DEVICE_LOCAL_KEY_RAW] as string) ?? null;
  }

  static async saveDeviceLocalKeyRaw(base64Key: string): Promise<void> {
    await chrome.storage.local.set({ [DEVICE_LOCAL_KEY_RAW]: base64Key });
  }

  static async getWrappedVek(): Promise<string | null> {
    const result = await chrome.storage.local.get(WRAPPED_VEK_KEY);
    return (result[WRAPPED_VEK_KEY] as string) ?? null;
  }

  static async saveWrappedVek(wrapped: string): Promise<void> {
    await chrome.storage.local.set({ [WRAPPED_VEK_KEY]: wrapped });
  }

  static async getDeviceId(): Promise<string | null> {
    const result = await chrome.storage.local.get(DEVICE_ID_KEY);
    return (result[DEVICE_ID_KEY] as string) ?? null;
  }

  static async saveDeviceId(id: string): Promise<void> {
    await chrome.storage.local.set({ [DEVICE_ID_KEY]: id });
  }

  static async getPairedAt(): Promise<string | null> {
    const result = await chrome.storage.local.get(DEVICE_PAIRED_AT_KEY);
    return (result[DEVICE_PAIRED_AT_KEY] as string) ?? null;
  }

  static async savePairedAt(iso: string): Promise<void> {
    await chrome.storage.local.set({ [DEVICE_PAIRED_AT_KEY]: iso });
  }

  static async getLastSyncedAt(): Promise<string | null> {
    const result = await chrome.storage.local.get(DEVICE_LAST_SYNCED_AT_KEY);
    return (result[DEVICE_LAST_SYNCED_AT_KEY] as string) ?? null;
  }

  static async saveLastSyncedAt(iso: string): Promise<void> {
    await chrome.storage.local.set({ [DEVICE_LAST_SYNCED_AT_KEY]: iso });
  }

  static async getDisplayName(): Promise<string> {
    const result = await chrome.storage.local.get(DEVICE_DISPLAY_NAME_KEY);
    return (result[DEVICE_DISPLAY_NAME_KEY] as string) ?? "Browser extension";
  }

  static async saveDisplayName(name: string): Promise<void> {
    await chrome.storage.local.set({ [DEVICE_DISPLAY_NAME_KEY]: name });
  }

  static async getLastHost(): Promise<string | null> {
    const result = await chrome.storage.local.get(LAST_HOST_KEY);
    return (result[LAST_HOST_KEY] as string) ?? null;
  }

  static async saveLastHost(hostAndPort: string): Promise<void> {
    await chrome.storage.local.set({ [LAST_HOST_KEY]: hostAndPort });
  }

  static async wipeAll(): Promise<void> {
    await chrome.storage.local.clear();
  }
}
