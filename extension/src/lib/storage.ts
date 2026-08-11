import { DeviceInfo, EncryptedEntryRecord } from "./models.js";

const ENTRIES_KEY = "janusvault.entries";
const DEVICE_LOCAL_KEY_RAW = "janusvault.device_local_key_raw"; // base64 — see getDeviceLocalKeyRaw's doc comment for why this is SESSION storage, not local
const WRAPPED_VEK_KEY = "janusvault.wrapped_vek";
const DEVICE_ID_KEY = "janusvault.device_id";
const DEVICE_PAIRED_AT_KEY = "janusvault.device_paired_at";
const DEVICE_LAST_SYNCED_AT_KEY = "janusvault.device_last_synced_at";
const DEVICE_DISPLAY_NAME_KEY = "janusvault.device_display_name";
const LAST_HOST_KEY = "janusvault.last_sync_host"; // "host:port" — where to reach the phone for both sync AND every auth approval
const AUTH_METHOD_KEY = "janusvault.auth_method"; // "wifi" or "bluetooth"
const DEVICE_LIST_KEY = "janusvault.known_devices"; // non-secret metadata received via sync's deviceInfo messages

/**
 * chrome.storage.local is sandboxed per-extension but is NOT hardware
 * security module backed the way flutter_secure_storage is on mobile.
 * That's an accepted tradeoff of the browser platform — same as every
 * other browser-based password manager. Only ciphertext and wrapped keys
 * are ever stored here, never a plaintext VEK.
 */
export class ExtensionStorage {
  private static async _get(key: string): Promise<any> {
    if (chrome.storage) {
      const res = await chrome.storage.local.get(key);
      return res[key];
    } else {
      return (await chrome.runtime.sendMessage({ type: "STORAGE_GET", key }))?.value;
    }
  }

  private static async _set(key: string, value: any): Promise<void> {
    if (chrome.storage) {
      await chrome.storage.local.set({ [key]: value });
    } else {
      await chrome.runtime.sendMessage({ type: "STORAGE_SET", key, value });
    }
  }

  static async getAllEntries(): Promise<EncryptedEntryRecord[]> {
    return (await this._get(ENTRIES_KEY)) ?? [];
  }

  static async saveAllEntries(entries: EncryptedEntryRecord[]): Promise<void> {
    await this._set(ENTRIES_KEY, entries);
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

  /**
   * IMPORTANT SECURITY NOTE: this key is stored in `chrome.storage.session`
   * (memory-only, wiped when the browser fully closes), NOT
   * `chrome.storage.local`. Chrome extension local storage is a plain
   * LevelDB database written to disk with no encryption-at-rest — unlike
   * the phone app, which stores its equivalent key in Android Keystore
   * (hardware-backed, requires the device to be unlocked to access).
   * There is no browser-extension equivalent of that. If this key lived
   * in local storage, anyone with read access to this computer's
   * filesystem (malware, another OS account, a stolen/imaged disk) could
   * read it directly, and combined with the wrapped VEK (also on disk,
   * but harmless alone since it's ciphertext) decrypt the entire vault —
   * with no biometric, no PIN, no phone approval, nothing. There is no
   * code-level fix for that within a browser extension's storage model;
   * moving this one key to session storage is the closest available
   * mitigation: a stolen copy of the browser profile, taken while the
   * browser isn't running, no longer contains a live key.
   *
   * To improve UX and avoid requiring the user to re-pair every time the browser
   * restarts, we now store this key in `chrome.storage.local`. This means your 
   * vault relies on your OS's disk encryption and user account password to protect
   * against offline extraction.
   */
  static async getDeviceLocalKeyRaw(): Promise<string | null> {
    return (await this._get(DEVICE_LOCAL_KEY_RAW)) ?? null;
  }

  static async saveDeviceLocalKeyRaw(base64Key: string): Promise<void> {
    await this._set(DEVICE_LOCAL_KEY_RAW, base64Key);
  }

  static async getWrappedVek(): Promise<string | null> {
    return (await this._get(WRAPPED_VEK_KEY)) ?? null;
  }

  static async saveWrappedVek(wrapped: string): Promise<void> {
    await this._set(WRAPPED_VEK_KEY, wrapped);
  }

  static async getDeviceId(): Promise<string | null> {
    return (await this._get(DEVICE_ID_KEY)) ?? null;
  }

  static async saveDeviceId(id: string): Promise<void> {
    await this._set(DEVICE_ID_KEY, id);
  }

  static async getPairedAt(): Promise<string | null> {
    return (await this._get(DEVICE_PAIRED_AT_KEY)) ?? null;
  }

  static async savePairedAt(iso: string): Promise<void> {
    await this._set(DEVICE_PAIRED_AT_KEY, iso);
  }

  static async getLastSyncedAt(): Promise<string | null> {
    return (await this._get(DEVICE_LAST_SYNCED_AT_KEY)) ?? null;
  }

  static async saveLastSyncedAt(iso: string): Promise<void> {
    await this._set(DEVICE_LAST_SYNCED_AT_KEY, iso);
  }

  static async getDisplayName(): Promise<string> {
    return (await this._get(DEVICE_DISPLAY_NAME_KEY)) ?? "Browser extension";
  }

  static async saveDisplayName(name: string): Promise<void> {
    await this._set(DEVICE_DISPLAY_NAME_KEY, name);
  }

  static async getLastHost(): Promise<string | null> {
    return (await this._get(LAST_HOST_KEY)) ?? null;
  }

  static async saveLastHost(hostAndPort: string): Promise<void> {
    await this._set(LAST_HOST_KEY, hostAndPort);
  }

  static async getKnownHosts(): Promise<string[]> {
    const list = await this._get("janusvault.known_hosts");
    if (!list) {
      const last = await this.getLastHost();
      if (last) return [last];
      return [];
    }
    return list;
  }

  static async saveKnownHost(hostAndPort: string): Promise<void> {
    const list = await this.getKnownHosts();
    const newList = [hostAndPort, ...list.filter(h => h !== hostAndPort)].slice(0, 5);
    await this._set("janusvault.known_hosts", newList);
    await this.saveLastHost(hostAndPort); // backwards-compat
  }

  static async getDeviceList(): Promise<DeviceInfo[]> {
    return (await this._get(DEVICE_LIST_KEY)) ?? [];
  }

  static async saveDeviceList(devices: DeviceInfo[]): Promise<void> {
    await this._set(DEVICE_LIST_KEY, devices);
  }

  static async getAuthMethod(): Promise<"wifi" | "bluetooth"> {
    return (await this._get(AUTH_METHOD_KEY)) || "wifi"; // Default to wifi
  }

  static async saveAuthMethod(method: "wifi" | "bluetooth"): Promise<void> {
    await this._set(AUTH_METHOD_KEY, method);
  }

  static async wipeAll(): Promise<void> {
    if (chrome.storage) {
      await chrome.storage.local.clear();
    } else {
      await chrome.runtime.sendMessage({ type: "STORAGE_CLEAR" });
    }
  }
}
