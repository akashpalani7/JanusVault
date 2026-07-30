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

export type SyncMsgType = "hello" | "helloResponse" | "deviceInfo" | "metadata" | "request" | "records" | "done" | "error" | "authRequest" | "authResponse" | "pairingRequest" | "pairingChallenge" | "pairingSuccess";

export type SyncMessage =
  | { type: "hello"; payload: { nonce: string } }
  | { type: "helloResponse"; payload: { mac: string } }
  | { type: "deviceInfo"; payload: { devices: DeviceInfo[] } }
  | { type: "metadata"; payload: { entries: RecordMeta[] } }
  | { type: "request"; payload: { uuids: string[] } }
  | { type: "records"; payload: { entries: EncryptedEntryRecord[] } }
  | { type: "done"; payload: Record<string, never> }
  | { type: "error"; payload: { message: string } }
  | { type: "authRequest"; payload: { requestId: string; actionLabel: string } }
  | { type: "authResponse"; payload: { requestId: string; approved: boolean } }
  | { type: "pairingRequest"; payload: { deviceName: string; pubKey: string; clientName?: string; platform?: string; deviceId?: string; } }
  | { type: "pairingChallenge"; payload: { pubKey: string } }
  | { type: "pairingSuccess"; payload: { wrappedVek: string; device: DeviceInfo } };

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
