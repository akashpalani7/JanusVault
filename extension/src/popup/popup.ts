import { ExtensionStorage } from "../lib/storage.js";
import { qrcodegen } from "../lib/qrcodegen.js";
import { requestLanPairing, requestBlePairing } from "../lib/pairing-client.js";
import { unwrapVek } from "../lib/crypto.js";
import { syncWithBlePhone } from "../lib/sync-client.js";

interface EntryMeta {
  uuid: string;
  websiteName: string;
  websiteUrl: string;
  username: string;
}

const statusEl = document.getElementById("status") as HTMLSpanElement;
const lockedView = document.getElementById("lockedView") as HTMLElement;
const phoneSection = document.getElementById("phoneSection") as HTMLElement;
const searchView = document.getElementById("searchView") as HTMLElement;
const searchInput = document.getElementById("searchInput") as HTMLInputElement;
const resultsList = document.getElementById("resultsList") as HTMLUListElement;
const emptyHint = document.getElementById("emptyHint") as HTMLParagraphElement;
const hostInput = document.getElementById("hostInput") as HTMLInputElement;
const syncButton = document.getElementById("syncButton") as HTMLButtonElement;
const syncBleButton = document.getElementById("syncBleButton") as HTMLButtonElement;
const authMethodSelect = document.getElementById("authMethodSelect") as HTMLSelectElement;
const syncStatus = document.getElementById("syncStatus") as HTMLParagraphElement;
const deviceNameInput = document.getElementById("deviceNameInput") as HTMLInputElement;
const pairingInput = document.getElementById("pairingInput") as HTMLTextAreaElement;
const pairButton = document.getElementById("pairButton") as HTMLButtonElement;
const lanPairHostInput = document.getElementById("lanPairHostInput") as HTMLInputElement;
const lanPairButton = document.getElementById("lanPairButton") as HTMLButtonElement;
const blePairButton = document.getElementById("blePairButton") as HTMLButtonElement;
const pairStatus = document.getElementById("pairStatus") as HTMLParagraphElement;

const pairNewDeviceSection = document.getElementById("pairNewDeviceSection") as HTMLElement;
const generatePairingButton = document.getElementById("generatePairingButton") as HTMLButtonElement;
const pairingOutput = document.getElementById("pairingOutput") as HTMLElement;
const pairingQrCanvas = document.getElementById("pairingQrCanvas") as HTMLCanvasElement;
const pairingOutputText = document.getElementById("pairingOutputText") as HTMLTextAreaElement;
const copyPairingButton = document.getElementById("copyPairingButton") as HTMLButtonElement;

const mainNav = document.getElementById("mainNav") as HTMLElement;
const navPasswords = document.getElementById("navPasswords") as HTMLButtonElement;
const navDevices = document.getElementById("navDevices") as HTMLButtonElement;
const navImport = document.getElementById("navImport") as HTMLButtonElement;
const navRecycleBin = document.getElementById("navRecycleBin") as HTMLButtonElement;

const devicesSection = document.getElementById("devicesSection") as HTMLElement;
const devicesList = document.getElementById("devicesList") as HTMLUListElement;
const devicesEmptyHint = document.getElementById("devicesEmptyHint") as HTMLParagraphElement;

const importSection = document.getElementById("importSection") as HTMLElement;
const importFileInput = document.getElementById("importFileInput") as HTMLInputElement;
const importStatus = document.getElementById("importStatus") as HTMLParagraphElement;

const recycleBinSection = document.getElementById("recycleBinSection") as HTMLElement;
const recycleBinList = document.getElementById("recycleBinList") as HTMLUListElement;
const recycleBinEmptyHint = document.getElementById("recycleBinEmptyHint") as HTMLParagraphElement;

const showAddEntryButton = document.getElementById("showAddEntryButton") as HTMLButtonElement;
const addEntrySection = document.getElementById("addEntrySection") as HTMLElement;
const newWebsiteInput = document.getElementById("newWebsiteInput") as HTMLInputElement;
const newWebsiteUrlInput = document.getElementById("newWebsiteUrlInput") as HTMLInputElement;
const newUsernameInput = document.getElementById("newUsernameInput") as HTMLInputElement;
const newPasswordInput = document.getElementById("newPasswordInput") as HTMLInputElement;
const newPasswordLengthSlider = document.getElementById("newPasswordLengthSlider") as HTMLInputElement;
const newPasswordLengthLabel = document.getElementById("newPasswordLengthLabel") as HTMLParagraphElement;
const genUppercase = document.getElementById("genUppercase") as HTMLInputElement;
const genLowercase = document.getElementById("genLowercase") as HTMLInputElement;
const genNumbers = document.getElementById("genNumbers") as HTMLInputElement;
const genSymbols = document.getElementById("genSymbols") as HTMLInputElement;
const regeneratePasswordButton = document.getElementById("regeneratePasswordButton") as HTMLButtonElement;
const saveNewEntryButton = document.getElementById("saveNewEntryButton") as HTMLButtonElement;
const cancelAddEntryButton = document.getElementById("cancelAddEntryButton") as HTMLButtonElement;
const addEntryStatus = document.getElementById("addEntryStatus") as HTMLParagraphElement;
const entryEditorTitle = document.getElementById("entryEditorTitle") as HTMLHeadingElement;
let editUuid: string | null = null;

/** Human-readable text for every outcome the background script can report
 * back from a gated action — every single one of these means "the phone
 * did not approve this", never "fell back to something weaker". */
const OUTCOME_MESSAGES: Record<string, string> = {
  denied: "Denied on your phone.",
  no_phone_configured: "Enter your phone's address above first.",
  unreachable: "Couldn't reach your phone. Make sure PeerVault is open and \"Make this device visible for sync\" is on.",
  timeout: "Timed out waiting for approval on your phone.",
  locked: "This browser isn't paired with a vault.",
  not_found: "That entry no longer exists.",
  no_form_on_page: "No login form found on this page.",
  no_content_script: "Can't autofill on this page — try a regular website tab.",
  no_active_tab: "No active tab found.",
};

async function refreshStatus() {
  const response = await chrome.runtime.sendMessage({ type: "IS_UNLOCKED" });
  const paired = Boolean(response?.unlocked);
  statusEl.textContent = paired ? "unlocked" : "not paired";
  lockedView.classList.toggle("hidden", paired);
  mainNav.classList.toggle("hidden", !paired);
  phoneSection.classList.toggle("hidden", !paired);
  pairNewDeviceSection.classList.toggle("hidden", !paired);
}

type ViewName = "passwords" | "devices" | "import" | "recycleBin";

function showView(view: ViewName) {
  searchView.classList.toggle("hidden", view !== "passwords");
  addEntrySection.classList.add("hidden"); // always closed when switching views
  devicesSection.classList.toggle("hidden", view !== "devices");
  importSection.classList.toggle("hidden", view !== "import");
  recycleBinSection.classList.toggle("hidden", view !== "recycleBin");
  for (const [btn, name] of [[navPasswords, "passwords"], [navDevices, "devices"], [navImport, "import"], [navRecycleBin, "recycleBin"]] as const) {
    btn.classList.toggle("active", name === view);
  }
  if (view === "devices") renderDevices();
  if (view === "recycleBin") renderRecycleBin();
  if (view === "passwords" && statusEl.textContent !== "not paired") runSearch(searchInput.value);
}

navPasswords.addEventListener("click", () => showView("passwords"));
navDevices.addEventListener("click", () => showView("devices"));
navImport.addEventListener("click", () => showView("import"));
navRecycleBin.addEventListener("click", () => showView("recycleBin"));

interface KnownDevice {
  deviceId: string;
  displayName: string;
  platform: string;
  pairedAt: string;
  lastSyncedAt: string;
  revoked: boolean;
}

async function renderDevices() {
  const [devices, selfId] = await Promise.all([ExtensionStorage.getDeviceList(), ExtensionStorage.getDeviceId()]);
  const others = (devices as KnownDevice[]).filter((d) => d.deviceId !== selfId);
  devicesList.innerHTML = "";
  devicesEmptyHint.classList.toggle("hidden", others.length > 0);
  for (const d of others) {
    const li = document.createElement("li");
    const name = document.createElement("div");
    name.className = "device-name";
    name.textContent = d.displayName + (d.revoked ? " (revoked)" : "");
    const meta = document.createElement("div");
    meta.className = "device-meta";
    meta.textContent = `${d.platform} • last synced ${new Date(d.lastSyncedAt).toLocaleString()}`;
    li.append(name, meta);
    devicesList.appendChild(li);
  }
}

function renderEntries(entries: EntryMeta[]) {
  resultsList.innerHTML = "";
  emptyHint.classList.toggle("hidden", entries.length > 0);

  for (const entry of entries) {
    const li = document.createElement("li");

    const info = document.createElement("div");
    info.className = "entry-info";
    const title = document.createElement("div");
    title.className = "entry-title";
    title.textContent = entry.websiteName || entry.websiteUrl || "Untitled";
    const subtitle = document.createElement("div");
    subtitle.className = "entry-subtitle";
    subtitle.textContent = entry.username || "(no username)";
    info.append(title, subtitle);

    const actions = document.createElement("div");
    actions.className = "entry-actions";

    const fillButton = document.createElement("button");
    fillButton.textContent = "Autofill";
    fillButton.title = "Ask your phone to approve filling this into the current page";
    fillButton.addEventListener("click", () => handleAutofill(entry, fillButton));

    const copyButton = document.createElement("button");
    copyButton.className = "secondary";
    copyButton.textContent = "Copy";
    copyButton.title = "Ask your phone to approve copying this password";
    copyButton.addEventListener("click", () => handleCopy(entry, copyButton));

    const editButton = document.createElement("button");
    editButton.className = "secondary";
    editButton.textContent = "Edit";
    editButton.title = "Ask your phone to approve editing this entry";
    editButton.addEventListener("click", () => handleEdit(entry, editButton));

    const deleteButton = document.createElement("button");
    deleteButton.className = "secondary";
    deleteButton.textContent = "Delete";
    deleteButton.title = "Move to recycle bin";
    deleteButton.addEventListener("click", async () => {
      deleteButton.disabled = true;
      syncStatus.textContent = `Moved to recycle bin.`;
      await chrome.runtime.sendMessage({ type: "SET_DELETED_STATUS", uuid: entry.uuid, deleted: true });
      await runSearch(searchInput.value);
    });

    actions.append(fillButton, copyButton, editButton, deleteButton);
    li.append(info, actions);
    resultsList.appendChild(li);
  }
}

/** Every click below is a FRESH request to the phone — there is
 * intentionally no "approved this session" state kept anywhere. */
async function handleAutofill(entry: EntryMeta, button: HTMLButtonElement) {
  button.disabled = true;
  syncStatus.textContent = `Waiting for approval on your phone to fill ${entry.websiteName}…`;
  try {
    const response = await chrome.runtime.sendMessage({ type: "AUTOFILL_TAB", uuid: entry.uuid });
    if (response?.filled) {
      syncStatus.textContent = "Filled.";
      window.close();
    } else {
      syncStatus.textContent = OUTCOME_MESSAGES[response?.reason as string] ?? "Autofill failed.";
    }
  } finally {
    button.disabled = false;
  }
}

async function handleCopy(entry: EntryMeta, button: HTMLButtonElement) {
  button.disabled = true;
  syncStatus.textContent = `Waiting for approval on your phone to copy ${entry.websiteName}…`;
  try {
    const response = await chrome.runtime.sendMessage({ type: "REVEAL_PASSWORD", uuid: entry.uuid });
    if (response?.ok) {
      await navigator.clipboard.writeText(response.password as string);
      syncStatus.textContent = `Copied password for ${entry.websiteName || entry.username}.`;
    } else {
      syncStatus.textContent = OUTCOME_MESSAGES[response?.outcome as string] ?? "Copy failed.";
    }
  } finally {
    button.disabled = false;
  }
}

async function handleEdit(entry: EntryMeta, button: HTMLButtonElement) {
  button.disabled = true;
  syncStatus.textContent = `Waiting for approval on your phone to edit ${entry.websiteName}…`;
  try {
    const response = await chrome.runtime.sendMessage({ type: "REVEAL_PASSWORD", uuid: entry.uuid });
    if (response?.ok) {
      syncStatus.textContent = "";
      showView("passwords");
      addEntrySection.classList.remove("hidden");
      
      entryEditorTitle.textContent = "Edit entry";
      editUuid = entry.uuid;
      newWebsiteInput.value = entry.websiteName || "";
      newWebsiteUrlInput.value = entry.websiteUrl || "";
      newUsernameInput.value = entry.username || "";
      newPasswordInput.value = response.password as string;
      addEntryStatus.textContent = "";
    } else {
      syncStatus.textContent = OUTCOME_MESSAGES[response?.outcome as string] ?? "Edit request failed.";
    }
  } finally {
    button.disabled = false;
  }
}

async function runSearch(query: string) {
  const response = await chrome.runtime.sendMessage({ type: "LIST_ALL_ENTRIES", query });
  renderEntries((response?.entries ?? []) as EntryMeta[]);
}

async function renderRecycleBin() {
  const response = await chrome.runtime.sendMessage({ type: "LIST_DELETED_ENTRIES", query: "" });
  const entries = (response?.entries ?? []) as EntryMeta[];
  
  document.querySelectorAll(".kebab-dropdown").forEach(el => el.remove());
  recycleBinList.innerHTML = "";
  recycleBinEmptyHint.classList.toggle("hidden", entries.length > 0);

  for (const entry of entries) {
    const li = document.createElement("li");

    const info = document.createElement("div");
    info.className = "entry-info";
    const title = document.createElement("div");
    title.className = "entry-title";
    title.textContent = entry.websiteName || entry.websiteUrl || "Untitled";
    const subtitle = document.createElement("div");
    subtitle.className = "entry-subtitle";
    subtitle.textContent = entry.username || "(no username)";
    info.append(title, subtitle);

    const actions = document.createElement("div");
    actions.className = "entry-actions kebab-menu";

    const kebabBtn = document.createElement("button");
    kebabBtn.className = "kebab-btn";
    kebabBtn.innerHTML = "&#8942;"; 
    
    const dropdown = document.createElement("div");
    dropdown.className = "kebab-dropdown hidden";
    
    kebabBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const isHidden = dropdown.classList.contains("hidden");
      
      document.querySelectorAll(".kebab-dropdown").forEach((el) => el.classList.add("hidden"));
      
      if (isHidden) {
        const rect = kebabBtn.getBoundingClientRect();
        const popupHeight = window.innerHeight;
        
        dropdown.style.position = "fixed";
        dropdown.style.right = `${document.body.clientWidth - rect.right}px`;
        
        dropdown.classList.remove("drop-up", "drop-down");
        if (rect.bottom > popupHeight - 95) {
          dropdown.classList.add("drop-up");
          dropdown.style.top = "auto";
          dropdown.style.bottom = `${popupHeight - rect.top + 4}px`;
        } else {
          dropdown.classList.add("drop-down");
          dropdown.style.bottom = "auto";
          dropdown.style.top = `${rect.bottom + 4}px`;
        }
        dropdown.classList.remove("hidden");
      }
    });
    
    document.addEventListener("click", () => {
      document.querySelectorAll(".kebab-dropdown").forEach((el) => el.classList.add("hidden"));
    });

    const restoreButton = document.createElement("button");
    restoreButton.className = "kebab-dropdown-item";
    restoreButton.textContent = "Restore";
    restoreButton.addEventListener("click", async () => {
      dropdown.classList.add("hidden");
      const res = await chrome.runtime.sendMessage({ type: "SET_DELETED_STATUS", uuid: entry.uuid, deleted: false });
      if (res.ok) {
        await renderRecycleBin();
      }
    });

    const eraseButton = document.createElement("button");
    eraseButton.className = "kebab-dropdown-item text-red";
    eraseButton.textContent = "Erase permanently";
    eraseButton.addEventListener("click", async () => {
      dropdown.classList.add("hidden");
      if (!confirm("Delete permanently? This cannot be undone.")) return;
      const res = await chrome.runtime.sendMessage({ type: "HARD_DELETE_CREDENTIAL", uuid: entry.uuid });
      if (res.ok) {
        await renderRecycleBin();
      }
    });

    dropdown.append(restoreButton, eraseButton);
    actions.append(kebabBtn);
    document.body.appendChild(dropdown);
    li.append(info, actions);
    recycleBinList.appendChild(li);
  }
}

searchInput.addEventListener("input", () => runSearch(searchInput.value));

syncButton.addEventListener("click", async () => {
  const value = hostInput.value.trim();
  if (!value) return;
  const [host, portStr] = value.split(":");
  const port = Number(portStr) || 51827;
  syncStatus.textContent = "Syncing…";
  const response = await chrome.runtime.sendMessage({ type: "SYNC_WITH_PHONE", host, port });
  if (response?.ok) {
    syncStatus.textContent = `Synced — pulled ${response.pulled}, pushed ${response.pushed}`;
    await runSearch(searchInput.value);
  } else {
    syncStatus.textContent = `Sync failed: ${response?.error ?? "unknown error"}`;
  }
});

syncBleButton.addEventListener("click", async () => {
  const rawKeyBase64 = await ExtensionStorage.getDeviceLocalKeyRaw();
  const wrappedVek = await ExtensionStorage.getWrappedVek();
  if (!rawKeyBase64 || !wrappedVek) {
    syncStatus.textContent = "Error: Not paired.";
    return;
  }
  
  syncBleButton.disabled = true;
  syncStatus.textContent = "Syncing...";
  
  try {
    const rawKeyBytes = Uint8Array.from(atob(rawKeyBase64), (c) => c.charCodeAt(0));
    const deviceLocalKey = await crypto.subtle.importKey("raw", rawKeyBytes, "AES-GCM", false, ["decrypt"]);
    const vek = await unwrapVek(wrappedVek, deviceLocalKey);

    const response = await syncWithBlePhone(vek, false);
    syncStatus.textContent = `Synced — pulled ${response.pulled}, pushed ${response.pushed}`;
    await runSearch(searchInput.value);
  } catch(e) {
    const msg = (e as Error).message;
    if (msg.includes("globally disabled") || msg.includes("Bluetooth API is disabled")) {
      syncStatus.innerHTML = `Bluetooth sync failed: Web Bluetooth API is disabled. Please enable it in <b>chrome://flags/#enable-web-bluetooth</b> or your browser's settings.`;
    } else if (msg.includes("User cancelled")) {
      syncStatus.textContent = `Bluetooth sync cancelled.`;
    } else {
      syncStatus.textContent = `Bluetooth sync failed: ${msg}`;
    }
  } finally {
    syncBleButton.disabled = false;
  }
});

pairButton.addEventListener("click", async () => {
  const value = pairingInput.value.trim();
  if (!value) return;
  pairStatus.textContent = "Pairing…";
  const response = await chrome.runtime.sendMessage({ type: "COMPLETE_PAIRING", payload: value, deviceName: deviceNameInput.value });
  if (response.paired) {
    pairStatus.textContent = "Paired!";
    await refreshStatus();
  } else {
    pairStatus.textContent = `Pairing failed: ${response.error ?? "invalid code"}`;
  }
});

lanPairButton.addEventListener("click", async () => {
  const rawHost = lanPairHostInput.value.trim();
  if (!rawHost) {
    pairStatus.textContent = "Error: Please enter the phone's IP (e.g. 192.168.1.5:51827)";
    return;
  }
  const name = deviceNameInput.value.trim() || "Paired Browser";
  const parts = rawHost.split(":");
  const host = parts[0];
  const port = parseInt(parts[1] || "51827", 10);

  pairStatus.textContent = "Connecting to phone...";
  lanPairButton.textContent = "Connecting...";
  lanPairButton.disabled = true;

  try {
    const outcome = await requestLanPairing(host, port, name, (pin) => {
      pairStatus.innerHTML = `Connected! Verify this PIN on your phone: <br><b style="font-size:24px;">${pin}</b>`;
    });

    if (!outcome.success) {
      pairStatus.textContent = `Pairing failed: ${outcome.reason}`;
      lanPairButton.textContent = "Pair over Wi-Fi";
      lanPairButton.disabled = false;
      return;
    }

    pairStatus.textContent = "Success! Parsing vault key...";
    const res = await chrome.runtime.sendMessage({ 
      type: "COMPLETE_LAN_PAIRING", 
      wrappedVek: outcome.wrappedVek, 
      sharedSecretArray: Array.from(outcome.sharedSecret),
      deviceName: name,
      peerDevice: outcome.device
    });
    
    if (res?.paired) {
      pairStatus.textContent = "Paired successfully! Syncing devices...";
      await chrome.runtime.sendMessage({ type: "SYNC_WITH_PHONE", host, port });
      pairStatus.textContent = "Paired and synced successfully!";
      await refreshStatus();
    } else {
      pairStatus.textContent = `Pairing failed: ${res?.error ?? "unknown error"}`;
      lanPairButton.textContent = "Pair over Wi-Fi";
      lanPairButton.disabled = false;
    }
  } catch (e) {
    pairStatus.textContent = `Error: ${e instanceof Error ? e.message : String(e)}`;
    lanPairButton.textContent = "Pair over Wi-Fi";
    lanPairButton.disabled = false;
  }
});

blePairButton.addEventListener("click", async () => {
  const name = deviceNameInput.value.trim() || "Paired Browser";

  pairStatus.textContent = "Please select your phone in the popup window...";
  blePairButton.disabled = true;
  try {
    const devices = await (navigator as any).bluetooth.getDevices();
    for (const d of devices) {
        try { await d.forget(); } catch(e) {}
    }
  } catch (e) {}

  try {
    await new Promise<void>((resolve, reject) => {
      let isDone = false;
      const listener = (msg: any) => {
         if (msg.type === 'BLE_PAIRED') {
             isDone = true;
             chrome.runtime.onMessage.removeListener(listener);
             resolve();
         }
      };
      chrome.runtime.onMessage.addListener(listener);
      chrome.runtime.sendMessage({ type: "BLE_PAIR_DEVICE" }, (res) => {
          if (!res?.ok && !isDone) {
             chrome.runtime.onMessage.removeListener(listener);
             reject(new Error("Failed to open pairing window"));
          }
      });
      setTimeout(() => {
          if (!isDone) {
              chrome.runtime.onMessage.removeListener(listener);
              reject(new Error("Pairing window closed or timed out."));
          }
      }, 60000);
    });
  } catch(e) {
    pairStatus.textContent = (e as Error).message.includes("timed out") ? "Pairing cancelled." : "Pairing failed.";
    blePairButton.disabled = false;
    return;
  }
  pairStatus.textContent = "Paired and synced successfully!";
  await refreshStatus();
});

generatePairingButton.addEventListener("click", async () => {
  generatePairingButton.disabled = true;
  try {
    const response = await chrome.runtime.sendMessage({ type: "CREATE_PAIRING_PACKAGE" });
    if (response?.ok) {
      pairingOutputText.value = response.encoded;
      
      const qr = qrcodegen.QrCode.encodeText(response.encoded, qrcodegen.QrCode.Ecc.MEDIUM);
      const scale = 3;
      const border = 2;
      pairingQrCanvas.width = (qr.size + border * 2) * scale;
      pairingQrCanvas.height = (qr.size + border * 2) * scale;
      const ctx = pairingQrCanvas.getContext("2d")!;
      ctx.fillStyle = "#FFFFFF";
      ctx.fillRect(0, 0, pairingQrCanvas.width, pairingQrCanvas.height);
      ctx.fillStyle = "#000000";
      for (let y = 0; y < qr.size; y++) {
        for (let x = 0; x < qr.size; x++) {
          if (qr.getModule(x, y)) {
            ctx.fillRect((x + border) * scale, (y + border) * scale, scale, scale);
          }
        }
      }

      pairingOutput.classList.remove("hidden");
    } else {
      pairStatus.textContent = response?.error ?? "Could not generate a pairing code.";
    }
  } finally {
    generatePairingButton.disabled = false;
  }
});

copyPairingButton.addEventListener("click", async () => {
  await navigator.clipboard.writeText(pairingOutputText.value);
  copyPairingButton.textContent = "Copied!";
  setTimeout(() => (copyPairingButton.textContent = "Copy"), 1500);
});

refreshStatus();
ExtensionStorage.getLastHost().then((host) => {
  if (host) hostInput.value = host;
});

// ---------------------------------------------------------------------
// Add new entry + password generator
// ---------------------------------------------------------------------

function generateStrongPassword(length: number): string {
  const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  const lower = "abcdefghijklmnopqrstuvwxyz";
  const numbers = "0123456789";
  const symbols = "!@#$%^&*-_=+";
  
  let charset = "";
  if (genUppercase.checked) charset += upper;
  if (genLowercase.checked) charset += lower;
  if (genNumbers.checked) charset += numbers;
  if (genSymbols.checked) charset += symbols;
  
  if (!charset) {
    charset = lower; // fallback if user unchecked all
    genLowercase.checked = true;
  }

  const cutoff = 256 - (256 % charset.length);
  const buf = new Uint8Array(1);
  let result = "";
  while (result.length < length) {
    crypto.getRandomValues(buf);
    if (buf[0] < cutoff) result += charset[buf[0] % charset.length];
  }
  return result;
}

function refreshGeneratedPassword() {
  const length = Number(newPasswordLengthSlider.value);
  newPasswordLengthLabel.textContent = `${length} characters`;
  newPasswordInput.value = generateStrongPassword(length);
}

showAddEntryButton.addEventListener("click", () => {
  showView("passwords"); // closes devices/import if open, keeps searchView visible behind the form
  addEntrySection.classList.remove("hidden");
  entryEditorTitle.textContent = "New entry";
  editUuid = null;
  newWebsiteInput.value = "";
  newWebsiteUrlInput.value = "";
  newUsernameInput.value = "";
  addEntryStatus.textContent = "";
  refreshGeneratedPassword();
});

newPasswordLengthSlider.addEventListener("input", refreshGeneratedPassword);
genUppercase.addEventListener("change", refreshGeneratedPassword);
genLowercase.addEventListener("change", refreshGeneratedPassword);
genNumbers.addEventListener("change", refreshGeneratedPassword);
genSymbols.addEventListener("change", refreshGeneratedPassword);
regeneratePasswordButton.addEventListener("click", refreshGeneratedPassword);

cancelAddEntryButton.addEventListener("click", () => {
  addEntrySection.classList.add("hidden");
});

saveNewEntryButton.addEventListener("click", async () => {
  const websiteName = newWebsiteInput.value.trim();
  const websiteUrl = newWebsiteUrlInput.value.trim();
  const username = newUsernameInput.value.trim();
  const password = newPasswordInput.value;
  if (!websiteUrl || !password) {
    addEntryStatus.textContent = "Website URL and password are required.";
    return;
  }
  saveNewEntryButton.disabled = true;
  try {
    const targetType = editUuid ? "UPDATE_CREDENTIAL" : "CAPTURE_CREDENTIAL";
    const payload = editUuid ? { type: targetType, uuid: editUuid, websiteName, websiteUrl, username, password } : { type: targetType, websiteName, websiteUrl, username, password };
    
    const response = await chrome.runtime.sendMessage(payload);
    if (response?.saved) {
      addEntryStatus.textContent = "Saved.";
      addEntrySection.classList.add("hidden");
      await runSearch(searchInput.value);
    } else {
      addEntryStatus.textContent = OUTCOME_MESSAGES[response?.reason as string] ?? "Could not save.";
    }
  } finally {
    saveNewEntryButton.disabled = false;
  }
});

// ---------------------------------------------------------------------
// Import from Chrome/Brave CSV export
// ---------------------------------------------------------------------

/** Minimal CSV parser handling quoted fields and escaped quotes (`""`),
 * which is exactly what Chrome/Brave/Edge's password-export CSV uses.
 * Not a general CSV library — deliberately just enough for this format:
 * header row `name,url,username,password[,note]`. */
function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let inQuotes = false;

  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"' && text[i + 1] === '"') {
        field += '"';
        i++;
      } else if (c === '"') {
        inQuotes = false;
      } else {
        field += c;
      }
    } else if (c === '"') {
      inQuotes = true;
    } else if (c === ",") {
      row.push(field);
      field = "";
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
    } else {
      field += c;
    }
  }
  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows.filter((r) => r.some((cell) => cell.trim().length > 0));
}

importFileInput.addEventListener("change", async () => {
  const file = importFileInput.files?.[0];
  if (!file) return;

  importStatus.textContent = "Reading file…";
  const text = await file.text();
  const rows = parseCsv(text);
  if (rows.length < 2) {
    importStatus.textContent = "That file doesn't look like a password export (no data rows found).";
    importFileInput.value = "";
    return;
  }

  const header = rows[0].map((h) => h.trim().toLowerCase());
  const urlIdx = header.indexOf("url");
  const userIdx = header.indexOf("username");
  const passIdx = header.indexOf("password");
  const nameIdx = header.indexOf("name");
  if (urlIdx === -1 || userIdx === -1 || passIdx === -1) {
    importStatus.textContent = 'Unrecognized CSV format — expected columns "url", "username", "password".';
    importFileInput.value = "";
    return;
  }

  const listResponse = await chrome.runtime.sendMessage({ type: "LIST_ALL_ENTRIES", query: "" });
  const existingEntries = (listResponse?.entries ?? []) as EntryMeta[];

  let saved = 0;
  let skipped = 0;
  const dataRows = rows.slice(1);
  for (let i = 0; i < dataRows.length; i++) {
    const cols = dataRows[i];
    const url = cols[urlIdx]?.trim();
    const username = cols[userIdx]?.trim() ?? "";
    const password = cols[passIdx]?.trim();
    if (!url || !password) {
      skipped++;
      continue;
    }
    let domain = url;
    try {
      domain = new URL(url).hostname || url;
    } catch {
      // Not a full URL (some exports just have a bare domain) — use as-is.
    }
    const websiteName = nameIdx !== -1 && cols[nameIdx]?.trim() ? cols[nameIdx].trim() : domain;
    
    if (existingEntries.some(e => (e.websiteName === websiteName || e.websiteUrl === url || e.websiteUrl === domain) && e.username === username)) {
      skipped++;
      continue;
    }
    
    const response = await chrome.runtime.sendMessage({
      type: "CAPTURE_CREDENTIAL",
      domain: websiteName || domain,
      username,
      password,
    });
    if (response?.saved) saved++; else skipped++;
    importStatus.textContent = `Importing… ${i + 1}/${dataRows.length}`;
  }

  importStatus.textContent = `Imported ${saved} entr${saved === 1 ? "y" : "ies"}${skipped ? `, skipped ${skipped}` : ""}. ` +
    "Consider deleting the exported CSV file now — it was plaintext on disk.";
  importFileInput.value = "";
  await runSearch(searchInput.value);
});

// ---------------------------------------------------------------------
// URL Param overrides (for normal window popout flow)
// ---------------------------------------------------------------------
const urlParamsExt = new URLSearchParams(window.location.search);
if (urlParamsExt.get("mode") === "ble-pair") {
    document.body.innerHTML = `
        <div style="text-align:center; padding:24px; font-family: sans-serif;">
            <h3 style="margin-top:0; font-size:18px;">Pair PeerVault via Bluetooth</h3>
            <p style="font-size:14px; margin-bottom:24px; color:#555;">Click below and select your phone from the list.</p>
            <button id="blePairDialogBtn" style="padding:12px 24px; font-size:16px; background:#4b4bff; color:white; border:none; border-radius:6px; cursor:pointer; width:100%;">
                Select Device
            </button>
            <p id="blePairDialogStatus" style="margin-top: 10px; font-size: 14px; font-weight: bold;"></p>
        </div>
    `;

    document.getElementById("blePairDialogBtn")!.addEventListener("click", async (e) => {
        e.preventDefault();
        const btn = document.getElementById("blePairDialogBtn") as HTMLButtonElement;
        const status = document.getElementById("blePairDialogStatus") as HTMLParagraphElement;
        btn.disabled = true;
        try {
            status.textContent = "Please select your device in the browser prompt...";
            const urlParams = new URLSearchParams(window.location.search);
            const name = urlParams.get("name") || "Paired Browser";
            
            // Strictly calling it inside this window context
            const outcome = await requestBlePairing(name, (pin) => {
                status.innerHTML = `Connected! Verify this PIN on your phone: <br><b style="font-size:32px;">${pin}</b>`;
                btn.textContent = "Awaiting Phone...";
            }, true, (msg) => {
                status.innerText = `[BLE Log]: ${msg}`;
            }); // forcePrompt = true so it strictly runs requestDevice() inside pairing-client

            if (!outcome.success) {
                status.textContent = `Pairing failed: ${outcome.reason}`;
                btn.disabled = false;
                btn.textContent = "Try Again";
                return;
            }
            
            status.textContent = "Success! Parsing vault key...";
            const res = await chrome.runtime.sendMessage({ 
                type: "COMPLETE_LAN_PAIRING", 
                wrappedVek: outcome.wrappedVek, 
                sharedSecretArray: Array.from(outcome.sharedSecret),
                deviceName: name,
                peerDevice: outcome.device
            });
            
            if (res?.paired) {
                status.textContent = "Paired successfully! You can close this.";
                chrome.runtime.sendMessage({ type: "BLE_PAIRED" });
                setTimeout(() => window.close(), 1500);
            } else {
                status.textContent = `Pairing failed: ${res?.error ?? "unknown error"}`;
                btn.disabled = false;
                btn.textContent = "Try Again";
            }
        } catch (err: any) {
            status.textContent = `Error: ${err.message}`;
            btn.disabled = false;
            btn.textContent = "Select Device";
        }
    });
} else if (urlParamsExt.get("popout") === "sync") {
  syncStatus.textContent = "Please click 'Sync via Bluetooth' again to authorize.";
} else if (urlParamsExt.get("popout") === "pair") {
  pairStatus.textContent = "Please click 'Pair via Bluetooth' again to authorize.";
} else if (urlParamsExt.get("popout") === "auth") {
  const rid = urlParamsExt.get("rid");
  const actionLabel = urlParamsExt.get("actionLabel") || "Action";

  document.body.innerHTML = `
    <div style="padding: 20px; text-align: center;">
      <h2 style="font-size: 16px; margin-top: 20px;">Reconnecting to Phone</h2>
      <p style="font-size: 13px; color: #666; margin-bottom: 20px; margin-top: 10px;">PeerVault needs permission to connect to your phone's randomized Bluetooth address to approve:<br><br><b style="font-size: 15px; color: #333;">${actionLabel}</b></p>
      <button id="reauthBtn" style="width: 100%; padding: 10px; background: #4b4bff; color: white; border: none; border-radius: 6px; cursor: pointer;">Select Phone</button>
      <p id="reauthStatus" style="margin-top: 10px; font-size: 12px;"></p>
    </div>
  `;

  document.getElementById("reauthBtn")?.addEventListener("click", async () => {
     const stat = document.getElementById("reauthStatus")!;
     try {
       stat.textContent = "Requesting device picker...";
       const PEERVAULT_SERVICE_UUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
       await (navigator as any).bluetooth.requestDevice({
         filters: [{ services: [PEERVAULT_SERVICE_UUID] }]
       });
       stat.textContent = "Authorized. Processing request...";
       
       chrome.runtime.sendMessage({
         type: "BLE_AUTH_POPUP_RESULT",
         requestId: rid,
         retry: true
       });
       
       setTimeout(() => window.close(), 1000);
     } catch (e: any) {
       stat.textContent = e.message || "Failed to select device.";
       if (e.message?.includes("User cancelled")) {
         chrome.runtime.sendMessage({
           type: "BLE_AUTH_POPUP_RESULT",
           requestId: rid,
           outcome: "denied"
         });
         setTimeout(() => window.close(), 1000);
       }
     }
  });
}

authMethodSelect.addEventListener("change", async () => {
  await ExtensionStorage.saveAuthMethod(authMethodSelect.value as "wifi" | "bluetooth");
});

// Sync initial values from storage
ExtensionStorage.getLastHost().then((v) => { if (v) hostInput.value = v; });
ExtensionStorage.getAuthMethod().then((v) => { if (v) authMethodSelect.value = v; });

refreshStatus();
