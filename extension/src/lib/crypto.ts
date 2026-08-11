// Mirrors app/lib/core/crypto/crypto_engine.dart exactly so encrypted
// blobs are interchangeable between the phone app and this extension.
// Wire format: base64( nonce(12 bytes) || ciphertext || tag(16 bytes) )

export interface EncryptedBlob {
  toBase64(): string;
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  bytes.forEach((b) => (binary += String.fromCharCode(b)));
  return btoa(binary);
}

function fromBase64(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export async function importVek(rawKeyBytes: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", rawKeyBytes as BufferSource, "AES-GCM", true, ["encrypt", "decrypt"]);
}

/** Encrypts plaintext with the VEK, returning the SAME wire format the Dart side uses. */
export async function encryptString(plainText: string, vek: CryptoKey): Promise<string> {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const plainBytes = new TextEncoder().encode(plainText);
  // WebCrypto's AES-GCM output already appends the 16-byte tag to the
  // ciphertext, which is exactly the format CryptoEngine.wrapKey/encryptRaw
  // produces on the Dart side after concatenation — no extra work needed.
  const cipherBuffer = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, vek, plainBytes);
  const cipherBytes = new Uint8Array(cipherBuffer);
  const combined = new Uint8Array(nonce.length + cipherBytes.length);
  combined.set(nonce, 0);
  combined.set(cipherBytes, nonce.length);
  return toBase64(combined);
}

export async function decryptString(encoded: string, vek: CryptoKey): Promise<string> {
  const combined = fromBase64(encoded);
  if (combined.length < 12 + 16) throw new Error("Encrypted blob too short to be valid");
  const nonce = combined.slice(0, 12);
  const cipherAndTag = combined.slice(12); // WebCrypto wants ciphertext+tag together
  const plainBuffer = await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, vek, cipherAndTag);
  return new TextDecoder().decode(plainBuffer);
}

/** Unwraps a VEK that was wrapped (encrypted) under some wrapping key — used
 * after this device receives its wrapped VEK via the pairing handshake. */
export async function unwrapVek(wrappedBase64: string, wrappingKey: CryptoKey): Promise<CryptoKey> {
  const combined = fromBase64(wrappedBase64);
  const nonce = combined.slice(0, 12);
  const cipherAndTag = combined.slice(12);
  const rawKeyBuffer = await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, wrappingKey, cipherAndTag);
  return importVek(new Uint8Array(rawKeyBuffer));
}

export async function wrapVek(vek: CryptoKey, wrappingKey: CryptoKey): Promise<string> {
  const rawKey = new Uint8Array(await crypto.subtle.exportKey("raw", vek));
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const cipherBuffer = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, wrappingKey, rawKey);
  const cipherBytes = new Uint8Array(cipherBuffer);
  const combined = new Uint8Array(nonce.length + cipherBytes.length);
  combined.set(nonce, 0);
  combined.set(cipherBytes, nonce.length);
  return toBase64(combined);
}

/** Sync-comparison hash — must match CryptoEngine.computeRecordHash on Dart side exactly. */
export async function computeRecordHash(params: {
  uuid: string;
  encryptedWebsiteNameBase64: string;
  encryptedUsernameBase64: string;
  encryptedPasswordBase64: string;
  lastUpdatedIso: string;
  deleted: boolean;
}): Promise<string> {
  const material = `${params.uuid}|${params.encryptedWebsiteNameBase64}|${params.encryptedUsernameBase64}|${params.encryptedPasswordBase64}|${params.lastUpdatedIso}|${params.deleted}`;
  const digestBuffer = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(material));
  return toBase64(new Uint8Array(digestBuffer));
}

/**
 * Device pairing — pairing-code + HKDF (mirrors CryptoEngine's
 * derivePairingKeyFromCode in crypto_engine.dart EXACTLY: same salt, same
 * info string, same algorithm). This replaces the earlier P-256 ECDH
 * stub, which could never interoperate with the phone app's X25519 — see
 * PAIRING_NOTE.md for the full explanation. Pairing needs no network call
 * at all: the phone's QR code already contains the wrapped VEK, and this
 * function lets the extension re-derive the exact same unwrapping key
 * from nothing but the pairing code inside that QR payload.
 */

const PAIRING_SALT = new TextEncoder().encode("JanusVault-pair-v2"); // must match CryptoEngine._pairingSalt exactly
const PAIRING_INFO = new TextEncoder().encode("janusvault-pairing-v2"); // must match CryptoEngine.derivePairingKeyFromCode exactly

// --- LAN sync authentication (anti-hijack) --------------------------------
// Mirrors CryptoEngine.deriveSyncAuthKey/hmacSha256 exactly (same salt,
// info, and hash) — see the long comment there for why this exists. Any
// device that doesn't hold the VEK (i.e. was never actually paired)
// cannot derive this key and cannot pass the handshake in auth-client.ts /
// sync-client.ts, so it never gets to see a device list, vault metadata,
// or trigger an approval prompt on the phone.
const SYNC_AUTH_SALT = new TextEncoder().encode("JanusVault-sync-v1"); // must match CryptoEngine._syncAuthSalt exactly
const SYNC_AUTH_INFO = new TextEncoder().encode("janusvault-sync-auth-v1");

export async function deriveSyncAuthKey(vek: CryptoKey): Promise<CryptoKey> {
  const rawVek = await crypto.subtle.exportKey("raw", vek);
  const keyMaterial = await crypto.subtle.importKey("raw", rawVek, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: SYNC_AUTH_SALT, info: SYNC_AUTH_INFO },
    keyMaterial,
    { name: "HMAC", hash: "SHA-256", length: 256 },
    true,
    ["sign", "verify"],
  );
}

/** HMAC-SHA256 over a plain string — deliberately not over serialized
 * JSON; see the Dart-side comment for why. */
export async function hmacSha256(key: CryptoKey, data: string): Promise<string> {
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return toBase64(new Uint8Array(signature));
}

export async function verifyHmacSha256(key: CryptoKey, data: string, macBase64: string): Promise<boolean> {
  try {
    return await crypto.subtle.verify("HMAC", key, fromBase64(macBase64) as BufferSource, new TextEncoder().encode(data));
  } catch {
    return false;
  }
}

export async function deriveKeyFromPairingCode(codeBytes: Uint8Array): Promise<CryptoKey> {
  const keyMaterial = await crypto.subtle.importKey("raw", codeBytes as BufferSource, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: PAIRING_SALT, info: PAIRING_INFO },
    keyMaterial,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

// Crockford base32 alphabet — must match CryptoEngine.encodeRecoverySecret /
// decodePairingCode exactly (no I/L/O/U, so users can't confuse characters
// when typing a code by hand).
const CROCKFORD_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/** Decodes a printable pairing code (from the QR payload) back into the
 * raw 16 bytes of entropy, using the same bit-packing as the Dart side. */
export function decodePairingCode(printable: string): Uint8Array {
  const cleaned = printable.replace(/-/g, "").toUpperCase();
  let bits = 0n;
  for (const char of cleaned) {
    const index = CROCKFORD_ALPHABET.indexOf(char);
    if (index === -1) throw new Error(`Invalid character in pairing code: ${char}`);
    bits = (bits << 5n) | BigInt(index);
  }
  const totalBits = cleaned.length * 5;
  const paddingBits = totalBits - 128;
  bits = bits >> BigInt(paddingBits);
  const bytes = new Uint8Array(16);
  for (let i = 15; i >= 0; i--) {
    bytes[i] = Number(bits & 0xffn);
    bits = bits >> 8n;
  }
  return bytes;
}

/** Mirrors CryptoEngine.encodeRecoverySecret exactly (same alphabet, same
 * bit-packing, same "-" grouping every 5 chars) — used for BOTH recovery
 * secrets (32 bytes) and pairing codes (16 bytes); the encoding is generic
 * over input length. */
export function encodeCrockfordBase32(bytes: Uint8Array): string {
  let bits = 0n;
  for (const b of bytes) {
    bits = (bits << 8n) | BigInt(b);
  }
  const totalBits = bytes.length * 8;
  const chars: string[] = [];
  let remaining = totalBits;
  while (remaining > 0) {
    const take = remaining >= 5 ? 5 : remaining;
    const shift = BigInt(remaining - take);
    const mask = (1n << BigInt(take)) - 1n;
    const chunk = Number((bits >> shift) & mask);
    chars.push(CROCKFORD_ALPHABET[chunk << (5 - take)]);
    remaining -= take;
  }
  const raw = chars.join("");
  const grouped: string[] = [];
  for (let i = 0; i < raw.length; i += 5) {
    grouped.push(raw.slice(i, Math.min(i + 5, raw.length)));
  }
  return grouped.join("-");
}

/** Generates a brand-new 16-byte pairing code — the extension acting as
 * the SOURCE device for pairing a new one (e.g. a new phone, after the
 * old one was lost), mirroring CryptoEngine.generatePairingCode. */
export function generatePairingCode(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(16));
}

/** Builds a full pairing package string ("janusvault-pair:v2:<code>:<wrappedVek>")
 * from this browser's own unwrapped VEK, exactly like DeviceManager.createPairingPackage
 * on the Dart side — so a phone's camera can scan a QR generated FROM the
 * extension popup, not just the other way around. */
export async function buildPairingPackage(vek: CryptoKey): Promise<{ printableCode: string; encoded: string }> {
  const codeBytes = generatePairingCode();
  const pairingKey = await deriveKeyFromPairingCode(codeBytes);
  const wrappedForTransit = await wrapVek(vek, pairingKey);
  const printableCode = encodeCrockfordBase32(codeBytes);
  return { printableCode, encoded: `janusvault-pair:v2:${printableCode}:${wrappedForTransit}` };
}

/** Parses the full pairing payload from a scanned/typed QR string:
 * "janusvault-pair:v2:<code>:<wrappedVek>" */
export function parsePairingPackage(raw: string): { pairingCodePrintable: string; wrappedVekForTransitBase64: string } {
  const parts = raw.split(":");
  if (parts.length !== 4 || parts[0] !== "janusvault-pair" || parts[1] !== "v2") {
    throw new Error("Not a valid JanusVault pairing code");
  }
  return { pairingCodePrintable: parts[2], wrappedVekForTransitBase64: parts[3] };
}

// ---------------------------------------------------------------------
// ECDH LAN Pairing (Numeric PIN Comparison)
// ---------------------------------------------------------------------

export async function generateEcdhKeyPair(): Promise<CryptoKeyPair> {
  return (await crypto.subtle.generateKey(
    { name: "X25519" },
    true,
    ["deriveKey", "deriveBits"]
  )) as CryptoKeyPair;
}

export async function exportJwEcdhKey(key: CryptoKey): Promise<string> {
  const rawBits = await crypto.subtle.exportKey("raw", key);
  return toBase64(new Uint8Array(rawBits));
}

export async function deriveEcdhSharedSecret(privateKey: CryptoKey, peerPublicKeyBase64: string): Promise<Uint8Array> {
  const peerKey = await crypto.subtle.importKey(
    "raw",
    fromBase64(peerPublicKeyBase64) as any,
    { name: "X25519" },
    false,
    []
  );
  const sharedBits = await crypto.subtle.deriveBits(
    { name: "X25519", public: peerKey },
    privateKey,
    256
  );
  return new Uint8Array(sharedBits);
}

export async function computeEcdhPin(sharedSecret: Uint8Array): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode("JanusVault-PIN") as any, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const hash = await crypto.subtle.sign("HMAC", key, sharedSecret as any);
  const view = new DataView(hash);
  const num = view.getUint32(0, false);
  const pin = (num % 1000000).toString().padStart(6, '0');
  return `${pin.slice(0, 3)}-${pin.slice(3)}`;
}

export async function deriveEcdhWrappingKey(sharedSecret: Uint8Array): Promise<CryptoKey> {
  const keyMaterial = await crypto.subtle.importKey("raw", sharedSecret as any, "HKDF", false, ["deriveKey"]);
  const PAIRING_SALT = new TextEncoder().encode("JanusVault-ecdh-pair");
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: PAIRING_SALT, info: new TextEncoder().encode("vekwrap") },
    keyMaterial,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"]
  );
}
