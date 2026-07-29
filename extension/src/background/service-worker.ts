import {
  decryptString,
  deriveKeyFromPairingCode,
  deriveSyncAuthKey,
  decodePairingCode,
  encryptString,
  parsePairingPackage,
  buildPairingPackage,
  unwrapVek,
  wrapVek,
  deriveEcdhWrappingKey,
} from "../lib/crypto.js";
import { EncryptedEntryRecord } from "../lib/models.js";
import { ExtensionStorage } from "../lib/storage.js";
import { recomputeHash, syncWithPhone } from "../lib/sync-client.js";
import { requestPhoneApproval } from "../lib/auth-client.js";

/**
 * A form submit almost always triggers navigation before the user can
 * react to an on-page banner — the banner (and the whole page it's
 * attached to) gets torn down mid-flight. So the content script doesn't
 * render anything at submit time; it just tells us what was submitted,
 * and we relay a "show the banner" instruction to whatever page ends up
 * loaded in that tab next (or, if nothing navigates — an SPA form — a
 * short fallback timer shows it on the same page instead). Either way,
 * the confirmation UI reliably survives long enough to be clickable.
 */
const pendingSaves = new Map<number, { domain: string; username: string; password: string }>();

function schedulePendingSaveDelivery(tabId: number) {
  // Fires almost immediately for an SPA (no real navigation happens, so
  // the content script is still alive) and gets pre-empted by the
  // onUpdated listener below for a real cross-page navigation, which is
  // usually a bit slower than this timer — either path ends with exactly
  // one delivery attempt, via deliverPendingSave's own cleanup.
  setTimeout(() => deliverPendingSave(tabId), 600);
  // Safety net in case neither the timer nor onUpdated ever manages to
  // reach a live content script (page kept navigating, etc.).
  setTimeout(() => pendingSaves.delete(tabId), 120000);
}

async function deliverPendingSave(tabId: number) {
  const pending = pendingSaves.get(tabId);
  if (!pending) return;
  try {
    await chrome.tabs.sendMessage(tabId, { type: "SHOW_SAVE_BANNER", ...pending });
    // Held dynamically in pendingSaves block until the user manually triggers 'SAVE_RESOLVED' via clicking interaction. 
  } catch {
    // No content script alive there yet (page still loading) — onUpdated
    // below will retry once it finishes loading.
  }
}

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "complete" && pendingSaves.has(tabId)) {
    deliverPendingSave(tabId);
  }
});

/**
 * SECURITY MODEL: there is deliberately no local PIN, password, or any
 * other fallback anywhere in this extension. Every single action that
 * would reveal a plaintext password — copying it, autofilling it into a
 * page — asks the phone to approve it fresh, every time, with the
 * phone's own biometric prompt. If the phone can't be reached, the
 * action is refused outright. This file is the enforcement point: the
 * popup and content script are just UI, they never receive a plaintext
 * password without going through requireApprovalOrDeny() first.
 *
 * IMPORTANT: MV3 service workers are ephemeral — Chrome can and will kill
 * this worker after ~30s of inactivity, which wipes any in-memory
 * variable including our unwrapped VEK. That means "unlocked" state
 * cannot outlive a single burst of activity the way it can in the
 * long-lived Flutter app process. Two consequences, both handled below:
 *   1. The VEK must be re-derivable cheaply (from the wrapped VEK +
 *      device local key, both in chrome.storage.local) rather than
 *      requiring re-pairing every time the worker restarts.
 *   2. Every handler below re-derives the key lazily rather than assuming
 *      a persistent "session".
 */

let cachedVek: CryptoKey | null = null;

async function getVek(): Promise<CryptoKey | null> {
  if (cachedVek) return cachedVek;
  const rawKeyBase64 = await ExtensionStorage.getDeviceLocalKeyRaw();
  const wrappedVek = await ExtensionStorage.getWrappedVek();
  if (!rawKeyBase64 || !wrappedVek) return null;

  const rawKeyBytes = Uint8Array.from(atob(rawKeyBase64), (c) => c.charCodeAt(0));
  const deviceLocalKey = await crypto.subtle.importKey("raw", rawKeyBytes, "AES-GCM", false, ["decrypt"]);
  cachedVek = await unwrapVek(wrappedVek, deviceLocalKey);
  return cachedVek;
}

async function decryptRecord(record: EncryptedEntryRecord) {
  const vek = await getVek();
  if (!vek) return null;
  return {
    uuid: record.uuid,
    websiteName: await decryptString(record.encryptedWebsiteName, vek),
    websiteUrl: await decryptString(record.encryptedWebsiteUrl, vek),
    username: await decryptString(record.encryptedUsername, vek),
    password: await decryptString(record.encryptedPassword, vek),
    createdAt: record.createdAt,
    lastUpdated: record.lastUpdated,
    deleted: record.deleted,
  };
}

type ApprovalOutcome = "approved" | "denied" | "unreachable" | "timeout" | "no_phone_configured";

/**
 * THE gate. Every path that ends in a plaintext password reaching the
 * popup or a web page goes through this first. No PIN, no cache, no
 * "remember for this session" — a fresh request to the phone every time,
 * because that's what was explicitly asked for.
 */
async function requireApprovalOrDeny(actionLabel: string, vek: CryptoKey): Promise<ApprovalOutcome> {
  const lastHost = await ExtensionStorage.getLastHost();
  if (!lastHost) return "no_phone_configured";
  const [host, portStr] = lastHost.split(":");
  const port = Number(portStr) || 51827;
  const syncAuthKey = await deriveSyncAuthKey(vek);
  return requestPhoneApproval(host, port, actionLabel, syncAuthKey);
}

/** Metadata only — used for both the popup's browsable list and the
 * on-page suggestion chip's label/picker. NEVER includes the password;
 * that only ever comes back after a specific, approved reveal/autofill
 * request for one specific entry (see revealPassword / autofillIntoTab). */
async function listEntryMeta(query?: string) {
  const vek = await getVek();
  if (!vek) return { locked: true, entries: [] as unknown[] };

  const all = await ExtensionStorage.getAllEntries();
  const needle = query?.trim().toLowerCase();
  const results: unknown[] = [];
  for (const record of all) {
    if (record.deleted) continue;
    const decrypted = await decryptRecord(record);
    if (!decrypted) continue;
    if (needle) {
      const haystack = `${decrypted.websiteName} ${decrypted.websiteUrl} ${decrypted.username}`.toLowerCase();
      if (!haystack.includes(needle)) continue;
    }
    results.push({
      uuid: decrypted.uuid,
      websiteName: decrypted.websiteName,
      websiteUrl: decrypted.websiteUrl,
      username: decrypted.username,
    });
  }
  results.sort((a, b) => (a as { websiteName: string }).websiteName.localeCompare((b as { websiteName: string }).websiteName));
  return { locked: false, entries: results };
}

/** Metadata-only matches for a page domain, backing the on-page chip. */
async function findMatchesForDomain(domain: string) {
  const vek = await getVek();
  if (!vek) return { locked: true, entries: [] as unknown[] };

  const all = await ExtensionStorage.getAllEntries();
  const normalizedDomain = domain.replace(/^www\./, "").toLowerCase();
  const matches: unknown[] = [];
  for (const record of all) {
    if (record.deleted) continue;
    const decrypted = await decryptRecord(record);
    if (!decrypted) continue;
    const haystack = `${decrypted.websiteName} ${decrypted.websiteUrl}`.toLowerCase();
    if (haystack.includes(normalizedDomain)) {
      matches.push({ uuid: decrypted.uuid, websiteName: decrypted.websiteName, username: decrypted.username });
    }
  }
  return { locked: false, entries: matches };
}

/** Reveals one password (for the popup's Copy button) — ALWAYS asks the
 * phone first. Returns the plaintext only on "approved". */
async function revealPassword(uuid: string) {
  const vek = await getVek();
  if (!vek) return { ok: false, outcome: "locked" as const };

  const outcome = await requireApprovalOrDeny("reveal a saved password", vek);
  if (outcome !== "approved") return { ok: false, outcome };

  const record = (await ExtensionStorage.getAllEntries()).find((e) => e.uuid === uuid);
  if (!record) return { ok: false, outcome: "not_found" as const };
  const decrypted = await decryptRecord(record);
  if (!decrypted) return { ok: false, outcome: "not_found" as const };
  return { ok: true, outcome, username: decrypted.username, password: decrypted.password };
}

/** Fills a saved credential into a tab's login form — ALWAYS asks the
 * phone first. `tabId` is the tab to fill (active tab if omitted). */
async function autofillIntoTab(uuid: string, tabId?: number) {
  const vek = await getVek();
  if (!vek) return { filled: false, reason: "locked" };

  const outcome = await requireApprovalOrDeny("autofill a saved password into this page", vek);
  if (outcome !== "approved") return { filled: false, reason: outcome };

  const record = (await ExtensionStorage.getAllEntries()).find((e) => e.uuid === uuid);
  if (!record) return { filled: false, reason: "not_found" };
  const decrypted = await decryptRecord(record);
  if (!decrypted) return { filled: false, reason: "not_found" };

  let targetTabId = tabId;
  if (targetTabId == null) {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    targetTabId = tab?.id;
  }
  if (targetTabId == null) return { filled: false, reason: "no_active_tab" };

  try {
    const response = await chrome.tabs.sendMessage(targetTabId, {
      type: "FILL_CREDENTIAL",
      username: decrypted.username,
      password: decrypted.password,
    });
    return { filled: Boolean(response?.filled), reason: response?.filled ? undefined : "no_form_on_page" };
  } catch (err) {
    // If we reach here, it either means no content script is loaded 
    // OR no frame actually found the form and replied to us (so the port closed).
    const message = (err as Error).message;
    if (message.includes("Receiving end does not exist") || message.includes("Could not establish connection")) {
      return { filled: false, reason: "no_content_script" };
    }
    return { filled: false, reason: "no_form_on_page" };
  }
}

/** Saves a newly submitted credential. This does NOT ask the phone —
 * saving new data isn't "using" a secret already in the vault — but it
 * only ever runs after the user explicitly clicked "Save" on the on-page
 * confirmation banner (see content/detect.ts); nothing is ever saved
 * silently on form submit. */
async function captureCredential(domain: string, username: string, password: string) {
  const vek = await getVek();
  if (!vek) return { saved: false, reason: "locked" };

  const now = new Date().toISOString();
  const uuid = crypto.randomUUID();
  const encryptedWebsiteName = await encryptString(domain, vek);
  const encryptedWebsiteUrl = await encryptString(domain, vek);
  const encryptedUsername = await encryptString(username, vek);
  const encryptedPassword = await encryptString(password, vek);

  const partial = {
    uuid,
    encryptedWebsiteName,
    encryptedWebsiteUrl,
    encryptedUsername,
    encryptedPassword,
    createdAt: now,
    lastUpdated: now,
    deleted: false,
  };
  const hash = await recomputeHash(partial);
  const record: EncryptedEntryRecord = { ...partial, hash };

  await ExtensionStorage.upsertEntries([record]);
  attemptBackgroundSync(); // push the new entry immediately rather than waiting for the next manual/periodic sync
  return { saved: true };
}

/** Updates a previously saved credential, preserving its UUID and creation timestamp. */
async function updateCredential(uuid: string, domain: string, username: string, password: string) {
  const vek = await getVek();
  if (!vek) return { saved: false, reason: "locked" };

  const all = await ExtensionStorage.getAllEntries();
  const existing = all.find((e) => e.uuid === uuid);
  if (!existing) return { saved: false, reason: "not_found" };

  const now = new Date().toISOString();
  const encryptedWebsiteName = await encryptString(domain, vek);
  const encryptedWebsiteUrl = await encryptString(domain, vek);
  const encryptedUsername = await encryptString(username, vek);
  const encryptedPassword = await encryptString(password, vek);

  const partial = {
    uuid,
    encryptedWebsiteName,
    encryptedWebsiteUrl,
    encryptedUsername,
    encryptedPassword,
    createdAt: existing.createdAt,
    lastUpdated: now,
    deleted: false,
  };
  const hash = await recomputeHash(partial);
  const record: EncryptedEntryRecord = { ...partial, hash };

  await ExtensionStorage.upsertEntries([record]);
  attemptBackgroundSync();
  return { saved: true };
}

/**
 * Best-effort, silent sync attempt — used for the "should just happen"
 * triggers: browser startup, a periodic alarm (approximates "whenever
 * both devices are on the same network" without real presence detection,
 * which a browser extension has no way to do), and right after saving a
 * new credential. Never surfaces an error to the user; the manual "Sync
 * now" button in the popup remains the way to see what happened.
 */
async function attemptBackgroundSync(): Promise<void> {
  const vek = await getVek();
  const lastHost = await ExtensionStorage.getLastHost();
  if (!vek || !lastHost) return;
  const [host, portStr] = lastHost.split(":");
  const port = Number(portStr) || 51827;
  try {
    await syncWithPhone(host, port, vek);
  } catch {
    // Silent — phone likely just isn't reachable right now (off network,
    // app closed, "visible for sync" off). The alarm will try again.
  }
}

chrome.runtime.onStartup.addListener(() => attemptBackgroundSync());
chrome.runtime.onInstalled.addListener(() => attemptBackgroundSync());
chrome.alarms.create("peervault-periodic-sync", { periodInMinutes: 5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "peervault-periodic-sync") attemptBackgroundSync();
});

/**
 * Completes pairing entirely offline, using nothing but the string scanned
 * or typed from the phone's pairing QR code — no network call needed,
 * mirroring DeviceManager.completeNewDevicePairing on the Dart side
 * exactly (same salt/info in deriveKeyFromPairingCode, same wire format).
 */
async function completePairing(rawPairingPackage: string, deviceName?: string) {
  const { pairingCodePrintable, wrappedVekForTransitBase64 } = parsePairingPackage(rawPairingPackage);
  const codeBytes = decodePairingCode(pairingCodePrintable);
  const pairingKey = await deriveKeyFromPairingCode(codeBytes);

  // Wrong code -> AES-GCM tag check fails -> throws. No partial/garbage
  // decrypt is possible.
  const vek = await unwrapVek(wrappedVekForTransitBase64, pairingKey);

  // Generate this browser's own local wrapping key and re-wrap the VEK
  // for storage, exactly like every other platform does.
  const deviceLocalKey = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]);
  const rawLocalKeyBytes = new Uint8Array(await crypto.subtle.exportKey("raw", deviceLocalKey));
  const rawLocalKeyBase64 = btoa(String.fromCharCode(...rawLocalKeyBytes));

  const wrappedForStorage = await wrapVek(vek, deviceLocalKey);

  const now = new Date().toISOString();
  await ExtensionStorage.saveDeviceLocalKeyRaw(rawLocalKeyBase64);
  await ExtensionStorage.saveWrappedVek(wrappedForStorage);
  await ExtensionStorage.saveDeviceId(`ext_${Date.now()}`);
  await ExtensionStorage.savePairedAt(now);
  await ExtensionStorage.saveLastSyncedAt(now);
  if (deviceName?.trim()) await ExtensionStorage.saveDisplayName(deviceName.trim());
  cachedVek = vek; // available immediately, no need to wait for a worker restart

  return { paired: true };
}

async function completeLanPairing(wrappedVekBase64: string, sharedSecretArray: number[], deviceName?: string) {
  const sharedSecret = new Uint8Array(sharedSecretArray);
  const wrappingKey = await deriveEcdhWrappingKey(sharedSecret);
  const vek = await unwrapVek(wrappedVekBase64, wrappingKey);

  const deviceLocalKey = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]);
  const rawLocalKeyBytes = new Uint8Array(await crypto.subtle.exportKey("raw", deviceLocalKey));
  const rawLocalKeyBase64 = btoa(String.fromCharCode(...rawLocalKeyBytes));
  const wrappedForStorage = await wrapVek(vek, deviceLocalKey);

  const now = new Date().toISOString();
  await ExtensionStorage.saveDeviceLocalKeyRaw(rawLocalKeyBase64);
  await ExtensionStorage.saveWrappedVek(wrappedForStorage);
  await ExtensionStorage.saveDeviceId(`ext_${Date.now()}`);
  await ExtensionStorage.savePairedAt(now);
  await ExtensionStorage.saveLastSyncedAt(now);
  if (deviceName?.trim()) await ExtensionStorage.saveDisplayName(deviceName.trim());
  cachedVek = vek;

  return { paired: true };
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    switch (message?.type) {
      case "FIND_MATCHES":
        sendResponse(await findMatchesForDomain(message.domain as string));
        break;
      case "LIST_ALL_ENTRIES":
        sendResponse(await listEntryMeta(message.query as string | undefined));
        break;
      case "REVEAL_PASSWORD":
        sendResponse(await revealPassword(message.uuid as string));
        break;
      case "AUTOFILL_TAB":
        // Content-script-originated calls (the on-page chip) carry the
        // tab they're running in; popup-originated calls don't, so we
        // fall back to whichever tab is active.
        sendResponse(await autofillIntoTab(message.uuid as string, sender.tab?.id));
        break;
      case "PENDING_SAVE": {
        const tabId = sender.tab?.id;
        if (tabId != null) {
          pendingSaves.set(tabId, { domain: message.domain, username: message.username, password: message.password });
          schedulePendingSaveDelivery(tabId);
        }
        sendResponse({ ok: tabId != null });
        break;
      }
      case "SAVE_RESOLVED": {
        if (sender.tab?.id != null) {
          pendingSaves.delete(sender.tab.id);
        }
        sendResponse({ ok: true });
        break;
      }
      case "CAPTURE_CREDENTIAL":
        sendResponse(await captureCredential(message.domain, message.username, message.password));
        break;
      case "UPDATE_CREDENTIAL":
        sendResponse(await updateCredential(message.uuid, message.domain, message.username, message.password));
        break;
      case "IS_UNLOCKED":
        sendResponse({ unlocked: (await getVek()) !== null });
        break;
      case "SYNC_WITH_PHONE": {
        const vek = await getVek();
        if (!vek) {
          sendResponse({ ok: false, error: "Not paired" });
          break;
        }
        const host = message.host as string;
        const port = (message.port as number) || 51827;
        await ExtensionStorage.saveLastHost(`${host}:${port}`);
        try {
          const result = await syncWithPhone(host, port, vek);
          sendResponse({ ok: true, ...result });
        } catch (e) {
          sendResponse({ ok: false, error: (e as Error).message });
        }
        break;

      }
      case "CREATE_PAIRING_PACKAGE": {
        const vek = await getVek();
        if (!vek) {
          sendResponse({ ok: false, error: "This browser isn't paired with a vault yet" });
          break;
        }
        const { printableCode, encoded } = await buildPairingPackage(vek);
        sendResponse({ ok: true, printableCode, encoded });
        break;
      }
      case "COMPLETE_PAIRING":
        try {
          sendResponse(await completePairing(message.payload as string, message.deviceName as string | undefined));
        } catch (e) {
          sendResponse({ paired: false, error: (e as Error).message });
        }
        break;
      case "COMPLETE_LAN_PAIRING":
        try {
          sendResponse(await completeLanPairing(message.wrappedVek as string, message.sharedSecretArray as number[], message.deviceName as string | undefined));
        } catch (e) {
          sendResponse({ paired: false, error: (e as Error).message });
        }
        break;
      default:
        sendResponse({ error: "Unknown message type" });
    }
  })();
  return true; // keep the message channel open for the async response
});
