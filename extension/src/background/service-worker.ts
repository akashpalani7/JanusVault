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
import { requestPhoneApproval, PhoneAuthOutcome } from "../lib/auth-client.js";

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
async function setupOffscreenDocument(): Promise<void> {
  const existingContexts = await (chrome.runtime as any).getContexts({
    contextTypes: ['OFFSCREEN_DOCUMENT'],
    documentUrls: [chrome.runtime.getURL('offscreen/offscreen-ble.html')]
  });

  if (existingContexts && existingContexts.length > 0) {
    return;
  }

  try {
    await (chrome as any).offscreen.createDocument({
      url: 'offscreen/offscreen-ble.html',
      reasons: ['DOM_PARSER'],
      justification: 'Required for background Bluetooth GATT communication'
    });
  } catch (e) {
    // Gracefully ignore offscreen creation issues
  }
}

async function requestPhoneApprovalBle(actionLabel: string, syncAuthKey: CryptoKey): Promise<PhoneAuthOutcome> {
  try {
    await setupOffscreenDocument();
    
    // Export symmetric hmac key into a transferrable format
    const syncAuthKeyRaw = await crypto.subtle.exportKey("raw", syncAuthKey);
    const requestId = crypto.randomUUID();

    const response = await chrome.runtime.sendMessage({
      type: 'BLE_EXECUTE_AUTH',
      actionLabel,
      requestId,
      syncAuthKeyRaw: Array.from(new Uint8Array(syncAuthKeyRaw))
    });

    if (response && response.outcome) {
      if (response.outcome === 'unreachable') {
        console.warn(`[Ext/Auth] BLE unreachable (${response.error}) - silently falling back to Wi-Fi`);
        const lastHost = await ExtensionStorage.getLastHost();
        if (lastHost) {
          const [host, port] = lastHost.split(":");
          const wifiOutcome = await requestPhoneApproval(host, parseInt(port, 10) || 51827, actionLabel, syncAuthKey);
          if (wifiOutcome !== "unreachable") return wifiOutcome;
        }
      }
      return response.outcome as PhoneAuthOutcome;
    }
    return "unreachable";
  } catch (e) {
    return "unreachable";
  }
}

async function requireApprovalOrDeny(actionLabel: string, vek: CryptoKey): Promise<ApprovalOutcome> {
  const syncAuthKey = await deriveSyncAuthKey(vek);
  const authMethod = await ExtensionStorage.getAuthMethod();

  if (authMethod === "bluetooth") {
    let outcome = await requestPhoneApprovalBle(actionLabel, syncAuthKey);
    
    // Retry up to 3 times silently on 'unreachable'
    let retries = 0;
    while (outcome === "unreachable" && retries < 3) {
        console.log(`[Ext/Auth] BLE/Wi-Fi unreachable, retrying silently (${retries + 1}/3)...`);
        await new Promise(r => setTimeout(r, 1000));
        outcome = await requestPhoneApprovalBle(actionLabel, syncAuthKey);
        retries++;
    }

    if (outcome === "unreachable") {
       return new Promise<ApprovalOutcome>((resolve) => {
         const rid = crypto.randomUUID();
         const listener = async (msg: any) => {
           if (msg.type === "BLE_AUTH_POPUP_RESULT" && msg.requestId === rid) {
             chrome.runtime.onMessage.removeListener(listener);
             
             if (msg.retry) {
                const retryOutcome = await requestPhoneApprovalBle(actionLabel, syncAuthKey);
                resolve(retryOutcome);
             } else {
                resolve(msg.outcome ?? "unreachable");
             }
           }
         };
         chrome.runtime.onMessage.addListener(listener);
         
         crypto.subtle.exportKey("raw", syncAuthKey).then((exported) => {
           const b64Key = btoa(String.fromCharCode(...new Uint8Array(exported)));
           const targetUrl = chrome.runtime.getURL(`popup/popup.html?popout=auth&rid=${rid}&actionLabel=${encodeURIComponent(actionLabel)}&authKey=${encodeURIComponent(b64Key)}`);
           
           chrome.windows.create({
             url: targetUrl,
             type: "normal",
             width: 450,
             height: 650,
             focused: true
           }).catch((e) => {
             console.error("Failed to pop out auth window, falling back to tab", e);
             chrome.tabs.create({ url: targetUrl, active: true }).catch((err2) => {
                 chrome.runtime.onMessage.removeListener(listener);
                 resolve("unreachable");
             });
           });
         }).catch((e) => {
             chrome.runtime.onMessage.removeListener(listener);
             resolve("unreachable");
         });
       });
    }
    return outcome;
  } else {
    const lastHost = await ExtensionStorage.getLastHost();
    if (!lastHost) return "no_phone_configured";
    
    const [host, portStr] = lastHost.split(":");
    const port = Number(portStr) || 51827;
    return requestPhoneApproval(host, port, actionLabel, syncAuthKey);
  }
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
  const genericTlds = new Set(["com", "org", "net", "io", "co", "uk", "in", "app", "dev"]);
  const domainTokens = normalizedDomain.split(".").filter(t => t.length > 2 && !genericTlds.has(t));
  
  const matches: unknown[] = [];
  for (const record of all) {
    if (record.deleted) continue;
    const decrypted = await decryptRecord(record);
    if (!decrypted) continue;
    const haystack = `${decrypted.websiteName} ${decrypted.websiteUrl}`.toLowerCase();
    
    if (haystack.includes(normalizedDomain) || 
        domainTokens.some(t => haystack.includes(t))) {
      matches.push({ uuid: decrypted.uuid, websiteName: decrypted.websiteName, username: decrypted.username });
    }
  }
  return { locked: false, entries: matches };
}

async function listDeletedEntryMeta(query?: string) {
  const vek = await getVek();
  if (!vek) return { locked: true, entries: [] as unknown[] };

  const all = await ExtensionStorage.getAllEntries();
  const needle = query?.trim().toLowerCase();
  const results: unknown[] = [];
  for (const record of all) {
    if (!record.deleted) continue;
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

async function setCredentialDeletedStatus(uuid: string, deleted: boolean) {
  const vek = await getVek();
  if (!vek) return { ok: false, reason: "locked" };

  const all = await ExtensionStorage.getAllEntries();
  const existing = all.find((e) => e.uuid === uuid);
  if (!existing) return { ok: false, reason: "not_found" };

  const now = new Date().toISOString();
  const partial = {
    uuid: existing.uuid,
    encryptedWebsiteName: existing.encryptedWebsiteName,
    encryptedWebsiteUrl: existing.encryptedWebsiteUrl,
    encryptedUsername: existing.encryptedUsername,
    encryptedPassword: existing.encryptedPassword,
    createdAt: existing.createdAt,
    lastUpdated: now,
    deleted: deleted,
  };
  const hash = await recomputeHash(partial);
  const record: EncryptedEntryRecord = { ...partial, hash };

  await ExtensionStorage.upsertEntries([record]);
  attemptBackgroundSync();
  return { ok: true };
}

async function hardDeleteCredential(uuid: string) {
  const all = await ExtensionStorage.getAllEntries();
  const index = all.findIndex((e) => e.uuid === uuid);
  if (index === -1) return { ok: false, reason: "not_found" };
  
  all.splice(index, 1);
  await ExtensionStorage.saveAllEntries(all);
  return { ok: true };
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
async function captureCredential(websiteName: string, websiteUrl: string, username: string, password: string) {
  const vek = await getVek();
  if (!vek) return { saved: false, reason: "locked" };

  const now = new Date().toISOString();
  const uuid = crypto.randomUUID();
  const encryptedWebsiteName = await encryptString(websiteName, vek);
  const encryptedWebsiteUrl = await encryptString(websiteUrl, vek);
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
async function updateCredential(uuid: string, websiteName: string, websiteUrl: string, username: string, password: string) {
  const vek = await getVek();
  if (!vek) return { saved: false, reason: "locked" };

  const all = await ExtensionStorage.getAllEntries();
  const existing = all.find((e) => e.uuid === uuid);
  if (!existing) return { saved: false, reason: "not_found" };

  const now = new Date().toISOString();
  const encryptedWebsiteName = await encryptString(websiteName, vek);
  const encryptedWebsiteUrl = await encryptString(websiteUrl, vek);
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
  if (!vek) return;

  const authMethod = await ExtensionStorage.getAuthMethod();
  if (authMethod === "bluetooth") {
     try {
       await setupOffscreenDocument();
       const vekRaw = Array.from(new Uint8Array(await crypto.subtle.exportKey("raw", vek)));
       const result = await chrome.runtime.sendMessage({
           type: 'BLE_EXECUTE_SYNC',
           vekRaw,
           forcePrompt: false,
       });
       if (result?.rotated) {
         cachedVek = null;
       }
       return;
     } catch (err) {
       console.log("[Ext/Worker] Background BLE sync failed, silently falling back to WiFi...");
       if (!(await ExtensionStorage.getDeviceId())) cachedVek = null;
     }
  }

  const hosts = await ExtensionStorage.getKnownHosts();
  if (hosts.length === 0) return;
  for (const hostAndPort of hosts) {
    const [host, portStr] = hostAndPort.split(":");
    const port = Number(portStr) || 51827;
    try {
      const result = await syncWithPhone(host, port, vek);
      if (result.rotated) {
        cachedVek = null;
      }
      break; // Success! Stop trying other hosts
    } catch {
      if (!(await ExtensionStorage.getDeviceId())) cachedVek = null;
      // Failed, try the next one
    }
  }
}

chrome.runtime.onStartup.addListener(() => attemptBackgroundSync());
chrome.runtime.onInstalled.addListener(() => attemptBackgroundSync());
chrome.alarms.create("janusvault-periodic-sync", { periodInMinutes: 5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "janusvault-periodic-sync") attemptBackgroundSync();
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
  await ExtensionStorage.savePairedAt(now);
  await ExtensionStorage.saveLastSyncedAt(now);
  if (deviceName?.trim()) await ExtensionStorage.saveDisplayName(deviceName.trim());
  cachedVek = vek; // available immediately, no need to wait for a worker restart

  return { paired: true };
}

async function completeLanPairing(wrappedVekBase64: string, sharedSecretArray: number[], deviceName?: string, peerDevice?: any) {
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
  await ExtensionStorage.savePairedAt(now);
  await ExtensionStorage.saveLastSyncedAt(now);
  if (deviceName?.trim()) await ExtensionStorage.saveDisplayName(deviceName.trim());
  if (peerDevice) await ExtensionStorage.saveDeviceList([peerDevice]);
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
      case "LIST_DELETED_ENTRIES":
        sendResponse(await listDeletedEntryMeta(message.query as string | undefined));
        break;
      case "SET_DELETED_STATUS":
        sendResponse(await setCredentialDeletedStatus(message.uuid as string, message.deleted as boolean));
        break;
      case "HARD_DELETE_CREDENTIAL":
        sendResponse(await hardDeleteCredential(message.uuid as string));
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
        sendResponse(await captureCredential(message.websiteName || message.domain, message.websiteUrl || message.domain, message.username, message.password));
        break;
      case "UPDATE_CREDENTIAL":
        sendResponse(await updateCredential(message.uuid, message.websiteName, message.websiteUrl, message.username, message.password));
        break;
      case "IS_UNLOCKED": {
        const vek = await getVek();
        if (vek) {
          const deviceId = await ExtensionStorage.getDeviceId();
          if (!deviceId) {
            cachedVek = null;
            sendResponse({ unlocked: false });
            return;
          }
        }
        sendResponse({ unlocked: !!vek });
        break;
      }
      case "LOCK_VAULT":
        cachedVek = null;
        sendResponse({ ok: true });
        break;
      case "SYNC_WITH_PHONE": {
        const vek = await getVek();
        if (!vek) {
          sendResponse({ ok: false, error: "Not paired" });
          break;
        }
        const host = message.host as string;
        const port = (message.port as number) || 51827;
        await ExtensionStorage.saveKnownHost(`${host}:${port}`);
        try {
          const result = await syncWithPhone(host, port, vek);
          if (result.rotated) {
            cachedVek = null;
          }
          sendResponse({ ok: true, ...result });
        } catch (e) {
          if (!(await ExtensionStorage.getDeviceId())) cachedVek = null;
          sendResponse({ ok: false, error: (e as Error).message });
        }
        break;
      }
      case "TRIGGER_BLE_SYNC":
        await setupOffscreenDocument();
        try {
            const result = await chrome.runtime.sendMessage({
                type: 'BLE_EXECUTE_SYNC',
                vekRaw: message.vekRaw,
                forcePrompt: message.forcePrompt,
            });
            if (result?.rotated) {
              cachedVek = null;
            }
            sendResponse(result ?? { ok: false, error: "Offscreen document dropped the message" });
        } catch (e) {
            if (!(await ExtensionStorage.getDeviceId())) cachedVek = null;
            sendResponse({ ok: false, error: (e as Error).message });
        }
        break;
      case "BLE_EXECUTE_PAIRING":
        await setupOffscreenDocument();
        try {
            const result = await chrome.runtime.sendMessage({
                type: 'BLE_EXECUTE_PAIRING',
                deviceName: message.deviceName,
                deviceId: message.deviceId
            });
            sendResponse(result ?? { success: false, reason: "Offscreen document dropped the message" });
        } catch (e) {
            sendResponse({ success: false, reason: (e as Error).message });
        }
        break;
      case "BLE_PAIR_DEVICE":
        const nameParam = message.deviceName ? `&name=${encodeURIComponent(message.deviceName)}` : '';
        chrome.windows.create({
            url: chrome.runtime.getURL(`popup/popup.html?mode=ble-pair${nameParam}`),
            type: "normal",
            width: 450,
            height: 450,
            focused: true,
        });
        sendResponse({ ok: true });
        break;
      case "CREATE_PAIRING_PACKAGE": {
        const vek = await getVek();
        if (!vek) {
          sendResponse({ ok: false, error: "This browser isn't paired with a vault yet" });
          break;
        }
        const outcome = await requireApprovalOrDeny("generate a pairing code for a new device", vek);
        if (outcome !== "approved") {
          sendResponse({ ok: false, error: "Phone is unreachable or denied. If you lost your phone, you must use your Recovery Kit on the new device directly." });
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
          sendResponse(await completeLanPairing(message.wrappedVek as string, message.sharedSecretArray as number[], message.deviceName as string | undefined, message.peerDevice));
        } catch (e) {
          sendResponse({ paired: false, error: (e as Error).message });
        }
        break;
      case "STORAGE_GET": {
        const key = String(message.key);
        const res = await chrome.storage.local.get(key);
        sendResponse({ value: res[key] });
        break;
      }
      case "STORAGE_SET": {
        const key = String(message.key);
        await chrome.storage.local.set({ [key]: message.value });
        sendResponse({ ok: true });
        break;
      }
      case "STORAGE_CLEAR":
        await chrome.storage.local.clear();
        sendResponse({ ok: true });
        break;
      default:
        sendResponse({ error: "Unknown message type" });
    }
  })();
  return true; // keep the message channel open for the async response
});
