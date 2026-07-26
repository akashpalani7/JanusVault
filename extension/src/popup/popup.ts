import { syncWithPhone } from "../lib/sync-client.js";
import { ExtensionStorage } from "../lib/storage.js";

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
const syncStatus = document.getElementById("syncStatus") as HTMLParagraphElement;
const pairingInput = document.getElementById("pairingInput") as HTMLTextAreaElement;
const pairButton = document.getElementById("pairButton") as HTMLButtonElement;
const pairStatus = document.getElementById("pairStatus") as HTMLParagraphElement;

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
  phoneSection.classList.toggle("hidden", !paired);
  searchView.classList.toggle("hidden", !paired);
  if (paired) await runSearch("");
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

    actions.append(fillButton, copyButton);
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

async function runSearch(query: string) {
  const response = await chrome.runtime.sendMessage({ type: "LIST_ALL_ENTRIES", query });
  renderEntries((response?.entries ?? []) as EntryMeta[]);
}

searchInput.addEventListener("input", () => runSearch(searchInput.value));

syncButton.addEventListener("click", async () => {
  const value = hostInput.value.trim();
  if (!value) return;
  const [host, portStr] = value.split(":");
  const port = Number(portStr) || 51827;
  await ExtensionStorage.saveLastHost(`${host}:${port}`);
  syncStatus.textContent = "Syncing…";
  try {
    const result = await syncWithPhone(host, port);
    syncStatus.textContent = `Synced — pulled ${result.pulled}, pushed ${result.pushed}`;
    await runSearch(searchInput.value);
  } catch (e) {
    syncStatus.textContent = `Sync failed: ${(e as Error).message}`;
  }
});

pairButton.addEventListener("click", async () => {
  const value = pairingInput.value.trim();
  if (!value) return;
  pairStatus.textContent = "Pairing…";
  const response = await chrome.runtime.sendMessage({ type: "COMPLETE_PAIRING", payload: value });
  if (response.paired) {
    pairStatus.textContent = "Paired!";
    await refreshStatus();
  } else {
    pairStatus.textContent = `Pairing failed: ${response.error ?? "invalid code"}`;
  }
});

refreshStatus();
ExtensionStorage.getLastHost().then((host) => {
  if (host) hostInput.value = host;
});
