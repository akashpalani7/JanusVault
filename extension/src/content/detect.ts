// Runs on every page (all_frames, so it also catches login forms inside
// iframes, e.g. SSO/OAuth widgets). Pure DOM heuristics — no dependency on
// site cooperation, same approach every password manager extension uses.

interface FoundField {
  input: HTMLInputElement;
  kind: "username" | "password";
}

interface MatchEntry {
  uuid: string;
  websiteName: string;
  username: string;
}

function findCandidateFields(root: ParentNode = document): FoundField[] {
  const found: FoundField[] = [];
  const inputs = root.querySelectorAll("input");
  inputs.forEach((input) => {
    if (input.type === "password") {
      found.push({ input, kind: "password" });
      return;
    }
    if (input.type === "email" || input.type === "text") {
      const hints = `${input.autocomplete} ${input.name} ${input.id} ${input.placeholder}`.toLowerCase();
      if (hints.includes("user") || hints.includes("email") || hints.includes("login")) {
        found.push({ input, kind: "username" });
      }
    }
  });
  return found;
}

function getDomain(): string {
  return window.location.hostname;
}

function makeFloatingEl(anchorInput: HTMLInputElement, offsetTop = -32): HTMLDivElement {
  const el = document.createElement("div");
  Object.assign(el.style, {
    position: "absolute",
    zIndex: "2147483647",
    background: "#1a1a2e",
    color: "white",
    padding: "6px 10px",
    borderRadius: "6px",
    fontSize: "12px",
    fontFamily: "system-ui, sans-serif",
    boxShadow: "0 2px 8px rgba(0,0,0,0.3)",
  });
  const rect = anchorInput.getBoundingClientRect();
  el.style.top = `${window.scrollY + rect.top + offsetTop}px`;
  el.style.left = `${window.scrollX + rect.left}px`;
  return el;
}

/**
 * Shows the "Fill from PeerVault" chip. Only carries non-secret metadata
 * (uuid/website/username) — clicking it asks the background script to run
 * the actual autofill, which ALWAYS requires phone approval first. No
 * plaintext password is ever visible to, or handled by, this content
 * script's own JS beyond what fillCredential() writes straight into the
 * page's own input elements.
 */
async function offerAutofill() {
  const fields = findCandidateFields();
  const passwordField = fields.find((f) => f.kind === "password");
  if (!passwordField) return;

  const response = await chrome.runtime.sendMessage({ type: "FIND_MATCHES", domain: getDomain() });
  const entries = (response?.entries ?? []) as MatchEntry[];
  if (response?.locked || !entries.length) return;

  const chip = makeFloatingEl(passwordField.input);
  chip.style.cursor = "pointer";
  chip.textContent = `Fill from PeerVault (${entries.length})`;

  chip.addEventListener("click", async () => {
    chip.textContent = "Waiting for approval on your phone…";
    chip.style.cursor = "default";
    const result = await chrome.runtime.sendMessage({ type: "AUTOFILL_TAB", uuid: entries[0].uuid });
    if (result?.filled) {
      chip.remove();
      return;
    }
    const messages: Record<string, string> = {
      denied: "Denied on phone.",
      no_phone_configured: "Open the PeerVault popup and set your phone's address first.",
      unreachable: "Couldn't reach your phone — is PeerVault open and sync visible?",
      timeout: "Timed out waiting for your phone.",
      no_form_on_page: "Couldn't find a form to fill.",
    };
    chip.textContent = messages[result?.reason as string] ?? "Autofill failed.";
    setTimeout(() => chip.remove(), 4000);
  });

  document.body.appendChild(chip);
  setTimeout(() => chip.remove(), 15000);
}

/**
 * Shows a Save/Not now banner after a login form is submitted with a
 * password in it — nothing is EVER saved silently. This is the actual
 * "ask before saving" behavior: previously this fired straight into
 * storage with no confirmation UI of any kind.
 */
function watchForCredentialSubmission() {
  document.addEventListener(
    "submit",
    (event) => {
      const form = event.target;
      if (!(form instanceof HTMLFormElement)) return;
      const fields = findCandidateFields(form);
      const passwordField = fields.find((f) => f.kind === "password");
      const usernameField = fields.find((f) => f.kind === "username");
      if (!passwordField || !passwordField.input.value) return;

      showSaveBanner(passwordField.input, getDomain(), usernameField?.input.value ?? "", passwordField.input.value);
    },
    true,
  );
}

function showSaveBanner(anchorInput: HTMLInputElement, domain: string, username: string, password: string) {
  const banner = makeFloatingEl(anchorInput, 8);
  banner.style.display = "flex";
  banner.style.alignItems = "center";
  banner.style.gap = "10px";

  const label = document.createElement("span");
  label.textContent = `Save password for ${domain}${username ? ` (${username})` : ""} to PeerVault?`;
  banner.appendChild(label);

  const saveBtn = document.createElement("button");
  saveBtn.textContent = "Save";
  Object.assign(saveBtn.style, { cursor: "pointer", border: "none", borderRadius: "4px", padding: "4px 8px", background: "#4b4bff", color: "white" });
  saveBtn.addEventListener("click", async () => {
    label.textContent = "Saving…";
    saveBtn.remove();
    dismissBtn.remove();
    const result = await chrome.runtime.sendMessage({ type: "CAPTURE_CREDENTIAL", domain, username, password });
    label.textContent = result?.saved ? "Saved to PeerVault." : "Couldn't save — is PeerVault paired?";
    setTimeout(() => banner.remove(), 2500);
  });

  const dismissBtn = document.createElement("button");
  dismissBtn.textContent = "Not now";
  Object.assign(dismissBtn.style, { cursor: "pointer", border: "none", borderRadius: "4px", padding: "4px 8px", background: "#444", color: "white" });
  dismissBtn.addEventListener("click", () => banner.remove());

  banner.appendChild(saveBtn);
  banner.appendChild(dismissBtn);
  document.body.appendChild(banner);
  setTimeout(() => banner.remove(), 20000);
}

/** Fills the best-guess username/password fields on this page. Only ever
 * called with plaintext already approved by the phone (see
 * background/service-worker.ts's autofillIntoTab). */
function fillCredential(username: string, password: string): boolean {
  const fields = findCandidateFields();
  const passwordField = fields.find((f) => f.kind === "password");
  if (!passwordField) return false;

  const usernameField = fields.find((f) => f.kind === "username");
  if (usernameField && username) {
    usernameField.input.value = username;
    usernameField.input.dispatchEvent(new Event("input", { bubbles: true }));
    usernameField.input.dispatchEvent(new Event("change", { bubbles: true }));
  }
  passwordField.input.value = password;
  passwordField.input.dispatchEvent(new Event("input", { bubbles: true }));
  passwordField.input.dispatchEvent(new Event("change", { bubbles: true }));
  return true;
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "FILL_CREDENTIAL") {
    const filled = fillCredential(message.username ?? "", message.password ?? "");
    sendResponse({ filled });
  }
  return false;
});

offerAutofill();
watchForCredentialSubmission();

// Re-check when the page's DOM changes significantly (SPA login modals
// that appear after initial load).
const observer = new MutationObserver(() => offerAutofill());
observer.observe(document.body, { childList: true, subtree: true });
