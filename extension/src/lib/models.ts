export interface DecryptedEntry {
  uuid: string;
  websiteName: string;
  websiteUrl: string;
  username: string;
  password: string;
  createdAt: string;
  lastUpdated: string;
  deleted: boolean;
}

/** On-disk / synced shape — every sensitive field is ciphertext. Mirrors
 * VaultEntryRecord in isar_collections.dart exactly. */
export interface EncryptedEntryRecord {
  uuid: string;
  encryptedWebsiteName: string;
  encryptedWebsiteUrl: string;
  encryptedUsername: string;
  encryptedPassword: string;
  createdAt: string;
  lastUpdated: string;
  hash: string;
  deleted: boolean;
}

export interface RecordMeta {
  uuid: string;
  hash: string;
  lastUpdated: string;
  deleted: boolean;
}

export type SyncMsgType = "hello" | "deviceInfo" | "metadata" | "request" | "records" | "done" | "error" | "authRequest" | "authResponse";

export interface SyncMessage {
  type: SyncMsgType;
  payload: Record<string, unknown>;
}

/** Mirrors DeviceInfo in sync_protocol.dart exactly — non-secret trusted
 * device metadata exchanged so the phone's "Trusted devices" list learns
 * about this browser (and vice versa) after the first real sync, since
 * pairing itself is fully offline and never tells the phone anything. */
export interface DeviceInfo {
  deviceId: string;
  displayName: string;
  platform: string;
  pairedAt: string;
  lastSyncedAt: string;
  revoked: boolean;
}
