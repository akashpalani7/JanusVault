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

function queryAllInputs(root: Document | ShadowRoot | Element = document): HTMLInputElement[] {
  const inputs: HTMLInputElement[] = [];
  
  if (root.querySelectorAll) {
    inputs.push(...Array.from(root.querySelectorAll("input")));
  }
  
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
  let node;
  while ((node = walker.nextNode())) {
    if (node instanceof HTMLElement && node.shadowRoot) {
      inputs.push(...queryAllInputs(node.shadowRoot));
    }
  }
  
  return inputs;
}

function isVisible(el: HTMLElement): boolean {
  if (el.offsetWidth === 0 || el.offsetHeight === 0) return false;
  const style = window.getComputedStyle(el);
  if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse" || style.opacity === "0") {
    return false;
  }
  const rect = el.getBoundingClientRect();
  if (rect.width === 0 || rect.height === 0) return false;
  if (rect.left < -9000 || rect.top < -9000) return false;
  return true;
}

function findCandidateFields(root: ParentNode = document): FoundField[] {
  const found: FoundField[] = [];
  const inputs = queryAllInputs(root as Element);
  
  let firstPasswordIndex = -1;
  inputs.forEach((input, index) => {
    if (input.type === "password" && !input.hidden && isVisible(input)) {
      found.push({ input, kind: "password" });
      if (firstPasswordIndex === -1) firstPasswordIndex = index;
    }
  });

  inputs.forEach((input, index) => {
    if (input.type === "password" || input.hidden || !isVisible(input)) {
      return;
    }
    
    if (input.type === "email" || input.type === "text" || input.type === "tel" || !input.hasAttribute("type")) {
      const hints = `${input.autocomplete} ${input.name} ${input.id} ${input.placeholder} ${input.type}`.toLowerCase();
      if (hints.includes("user") || hints.includes("email") || hints.includes("login") || hints.includes("id") || hints.includes("account") || hints.includes("phone")) {
        found.push({ input, kind: "username" });
      } else if (firstPasswordIndex !== -1 && index === firstPasswordIndex - 1) {
        // Fallback: If it's the text input immediately preceding the first password input, it's likely the username.
        found.push({ input, kind: "username" });
      }
    }
  });
  return found;
}

function getDomain(): string {
  return window.location.hostname;
}

function makeFloatingEl(anchorInput: HTMLInputElement | null, offsetTop = -32): HTMLDivElement {
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
  if (anchorInput) {
    const rect = anchorInput.getBoundingClientRect();
    el.style.top = `${window.scrollY + rect.top + offsetTop}px`;
    el.style.left = `${window.scrollX + rect.left}px`;
  } else {
    // No anchor available (e.g. showing a save banner on a page that
    // navigated away from the form that triggered it) — pin to a corner
    // instead of guessing at a position.
    el.style.top = "16px";
    el.style.right = "16px";
  }
  return el;
}

// ---------------------------------------------------------------------
// Existing-credential autofill chip
// ---------------------------------------------------------------------

/**
 * Shows the "Fill from JanusVault" chip. Only carries non-secret metadata
 * (uuid/website/username) — clicking it asks the background script to run
 * the actual autofill, which ALWAYS requires phone approval first. No
 * plaintext password is ever visible to, or handled by, this content
 * script's own JS beyond what fillCredential() writes straight into the
 * page's own input elements.
 */
async function checkAndShowOverlays() {
  const fields = findCandidateFields();
  const passwordFields = fields.filter((f) => f.kind === "password");
  if (!passwordFields.length) return;

  const passwordField = passwordFields[0];
  if (document.getElementById("janusvault-autofill-chip") || document.getElementById("janusvault-suggest-chip")) return;

  let response: any;
  try {
    response = await chrome.runtime.sendMessage({ type: "FIND_MATCHES", domain: getDomain() });
  } catch(e) {
    return; // Usually happens during Extension Development hard-reloads
  }
  const entries = (response?.entries ?? []) as MatchEntry[];
  
  if (!response?.locked && entries.length > 0) {
    offerAutofill(passwordField, entries);
  } else {
    offerNewPasswordSuggestion(passwordFields);
  }
}

/**
 * Shows the "Fill from JanusVault" chip. Only carries non-secret metadata
 * (uuid/website/username) — clicking it asks the background script to run
 * the actual autofill, which ALWAYS requires phone approval first. No
 * plaintext password is ever visible to, or handled by, this content
 * script's own JS beyond what fillCredential() writes straight into the
 * page's own input elements.
 */
function offerAutofill(passwordField: FoundField, entries: MatchEntry[]) {

  const chip = makeFloatingEl(passwordField.input);
  chip.id = "janusvault-autofill-chip";
  chip.style.cursor = "pointer";
  chip.textContent = `Fill from JanusVault (${entries.length})`;

  chip.addEventListener("click", () => {
    const existing = document.getElementById("janusvault-autofill-dropdown");
    if (existing) {
      existing.remove();
      return;
    }

    const dropdown = document.createElement("div");
    dropdown.id = "janusvault-autofill-dropdown";
    dropdown.style.position = "absolute";
    const rect = chip.getBoundingClientRect();
    dropdown.style.top = `${window.scrollY + rect.bottom + 2}px`;
    dropdown.style.left = `${window.scrollX + rect.left}px`;
    dropdown.style.backgroundColor = "#242424";
    dropdown.style.border = "1px solid #4a4a4a";
    dropdown.style.borderRadius = "6px";
    dropdown.style.boxShadow = "0 8px 16px rgba(0,0,0,0.5)";
    dropdown.style.zIndex = "2147483647";
    dropdown.style.display = "flex";
    dropdown.style.flexDirection = "column";
    dropdown.style.padding = "4px 0";
    dropdown.style.minWidth = "150px";

    for (const entry of entries) {
      const item = document.createElement("div");
      item.style.padding = "8px 16px";
      item.style.cursor = "pointer";
      item.style.color = "#ffffff";
      item.style.fontFamily = "system-ui, sans-serif";
      item.style.fontSize = "14px";
      item.textContent = entry.username || entry.websiteName || "(Unknown account)";
      
      item.addEventListener("mouseover", () => { item.style.backgroundColor = "#3d3d3d"; });
      item.addEventListener("mouseout", () => { item.style.backgroundColor = "transparent"; });
      
      item.addEventListener("click", async (ev) => {
        ev.stopPropagation();
        dropdown.remove();
        chip.textContent = "Approving…";
        try {
          const result = await chrome.runtime.sendMessage({ type: "AUTOFILL_TAB", uuid: entry.uuid });
          if (result?.filled) {
            chip.remove();
          } else {
            chip.textContent = "Failed. Locked?";
            setTimeout(() => chip.remove(), 2000);
          }
        } catch (e) {
           chip.remove();
        }
      });
      dropdown.appendChild(item);
    }

    const outsideListener = (ev: MouseEvent) => {
      if (!dropdown.contains(ev.target as Node) && ev.target !== chip) {
        dropdown.remove();
        document.removeEventListener("click", outsideListener);
      }
    };
    setTimeout(() => document.addEventListener("click", outsideListener), 0);
    
    document.body.appendChild(dropdown);
  });

  document.body.appendChild(chip);
  setTimeout(() => chip.remove(), 15000);
}

/** Rejection-sampled so every character in the set is equally likely —
 * plain `randomByte % charset.length` would bias toward earlier
 * characters whenever charset.length doesn't evenly divide 256. */
function generateStrongPassword(length: number): string {
  const charset = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*-_=+";
  const cutoff = 256 - (256 % charset.length);
  const buf = new Uint8Array(1);
  let result = "";
  while (result.length < length) {
    crypto.getRandomValues(buf);
    if (buf[0] < cutoff) result += charset[buf[0] % charset.length];
  }
  return result;
}

function offerNewPasswordSuggestion(passwordFields: FoundField[]) {
  if (!passwordFields.length) return;
  if (document.getElementById("janusvault-suggest-chip")) return;

  const chip = makeFloatingEl(passwordFields[0].input);
  chip.id = "janusvault-suggest-chip";
  chip.style.cursor = "pointer";
  chip.textContent = "Suggest a strong password (JanusVault)";

  let panel: HTMLDivElement | null = null;

  chip.addEventListener("click", () => {
    if (panel) return;
    panel = buildSuggestionPanel(passwordFields, () => {
      panel?.remove();
      panel = null;
      chip.remove();
    });
    chip.after(panel);
  });

  document.body.appendChild(chip);
}

function buildSuggestionPanel(passwordFields: FoundField[], onDone: () => void): HTMLDivElement {
  const panel = document.createElement("div");
  Object.assign(panel.style, {
    position: "absolute",
    zIndex: "2147483647",
    background: "#1a1a2e",
    color: "white",
    padding: "10px 12px",
    borderRadius: "8px",
    fontSize: "12px",
    fontFamily: "system-ui, sans-serif",
    boxShadow: "0 2px 8px rgba(0,0,0,0.3)",
    width: "220px",
  });
  const anchorRect = passwordFields[0].input.getBoundingClientRect();
  panel.style.top = `${window.scrollY + anchorRect.bottom + 6}px`;
  panel.style.left = `${window.scrollX + anchorRect.left}px`;

  const preview = document.createElement("div");
  Object.assign(preview.style, { fontFamily: "monospace", wordBreak: "break-all", marginBottom: "6px", fontSize: "13px" });

  const slider = document.createElement("input");
  slider.type = "range";
  slider.min = "8";
  slider.max = "32";
  slider.value = "16";
  slider.style.width = "100%";

  const lengthLabel = document.createElement("div");
  lengthLabel.style.marginBottom = "6px";

  const useBtn = document.createElement("button");
  useBtn.textContent = "Use this password";
  Object.assign(useBtn.style, { cursor: "pointer", border: "none", borderRadius: "4px", padding: "5px 8px", background: "#4b4bff", color: "white", width: "100%" });

  let current = generateStrongPassword(Number(slider.value));
  const refresh = () => {
    lengthLabel.textContent = `${slider.value} characters`;
    current = generateStrongPassword(Number(slider.value));
    preview.textContent = current;
  };
  refresh();

  slider.addEventListener("input", refresh);
  useBtn.addEventListener("click", () => {
    for (const field of passwordFields) {
      field.input.value = current;
      field.input.dispatchEvent(new Event("input", { bubbles: true }));
      field.input.dispatchEvent(new Event("change", { bubbles: true }));
    }
    onDone();
  });

  panel.append(preview, slider, lengthLabel, useBtn);
  return panel;
}

// ---------------------------------------------------------------------
// Save-on-submit — relayed through the background script because a form
// submit almost always navigates away before the user could ever click a
// banner rendered directly on the submitting page.
// ---------------------------------------------------------------------

function watchForCredentialSubmission() {
  const submitHandler = () => {
    const fields = findCandidateFields(document);
    const passwordField = fields.find((f) => f.kind === "password");
    if (!passwordField || !passwordField.input.value) return;

    const usernameField = fields.find((f) => f.kind === "username");
    
    // Fire-and-forget: intentionally not awaited, since the page may
    // navigate within the same tick and there'd be nothing left to
    // await for anyway. The background script takes it from here.
    chrome.runtime.sendMessage({
      type: "PENDING_SAVE",
      domain: getDomain(),
      username: usernameField?.input.value ?? "",
      password: passwordField.input.value,
    }).catch(() => {});
  };

  // 1. Standard HTML form submit
  document.addEventListener(
    "submit",
    (event) => {
      submitHandler();
    },
    true,
  );

  // 2. Button clicks (likely login/submit buttons in SPAs without <form>)
  document.addEventListener(
    "click",
    (e) => {
      const target = e.target as HTMLElement;
      const button = target.closest("button") || target.closest("input[type='submit']") || target.closest("input[type='button']");
      if (button) {
        const txt = button.textContent?.toLowerCase() || (button as HTMLInputElement).value?.toLowerCase() || "";
        if (txt.includes("log") || txt.includes("sign") || txt.includes("submit") || txt.includes("continue") || txt.includes("next")) {
          submitHandler();
        } else {
          // Even if we don't recognize the text, if there's a filled password field, it might be a login
          const fields = findCandidateFields(document);
          const pw = fields.find(f => f.kind === "password");
          if (pw && pw.input.value) submitHandler();
        }
      }
    },
    true
  );

  // 3. Enter key in an input field (Common for SPAs that capture keydown instead of submit)
  document.addEventListener(
    "keypress",
    (e) => {
      if (e.key === "Enter") {
        submitHandler();
      }
    },
    true
  );
}

function showSaveBanner(domain: string, username: string, password: string) {
  if (document.getElementById("janusvault-save-banner")) return;
  const anchor = findCandidateFields().find((f) => f.kind === "password")?.input ?? null;
  const banner = makeFloatingEl(anchor, 8);
  banner.id = "janusvault-save-banner";
  banner.style.display = "flex";
  banner.style.alignItems = "center";
  banner.style.gap = "10px";

  const label = document.createElement("span");
  label.textContent = `Save password for ${domain}${username ? ` (${username})` : ""} to JanusVault?`;
  banner.appendChild(label);

  const resolveSave = () => {
    chrome.runtime.sendMessage({ type: "SAVE_RESOLVED" }).catch(() => {});
  };

  const saveBtn = document.createElement("button");
  saveBtn.textContent = "Save";
  Object.assign(saveBtn.style, { cursor: "pointer", border: "none", borderRadius: "4px", padding: "4px 8px", background: "#4b4bff", color: "white" });
  saveBtn.addEventListener("click", async () => {
    label.textContent = "Saving…";
    saveBtn.remove();
    dismissBtn.remove();
    let result: any;
    try {
      result = await chrome.runtime.sendMessage({ type: "CAPTURE_CREDENTIAL", domain, username, password });
    } catch(e) {}
    label.textContent = result?.saved ? "Saved to JanusVault." : "Couldn't save — is JanusVault paired?";
    resolveSave();
    setTimeout(() => banner.remove(), 2500);
  });

  const dismissBtn = document.createElement("button");
  dismissBtn.textContent = "Not now";
  Object.assign(dismissBtn.style, { cursor: "pointer", border: "none", borderRadius: "4px", padding: "4px 8px", background: "#444", color: "white" });
  dismissBtn.addEventListener("click", () => {
    banner.remove();
    resolveSave();
  });

  banner.appendChild(saveBtn);
  banner.appendChild(dismissBtn);
  document.body.appendChild(banner);
  
  setTimeout(() => {
    if (banner.parentElement) {
      banner.remove();
      resolveSave();
    }
  }, 20000);
}

// ---------------------------------------------------------------------
// Fill + message plumbing
// ---------------------------------------------------------------------

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
    if (filled) {
      // Only respond if we ACTUALLY filled it. If we didn't, leave the channel open
      // so that another iframe on the page that DOES have the form can respond first!
      sendResponse({ filled: true });
    }
    // Return true to keep the message channel open for potential async responses from other frames
    // or just let it timeout if no frame had the form.
    return true; 
  }
  if (message?.type === "SHOW_SAVE_BANNER") {
    showSaveBanner(message.domain ?? "", message.username ?? "", message.password ?? "");
    return false;
  }
  return false;
});

checkAndShowOverlays();
watchForCredentialSubmission();

// Re-check when the page's DOM changes significantly (SPA login modals
// that appear after initial load). Debounced hard: an un-debounced
// MutationObserver on `document.body` re-running two chip-detection
// passes (each walking every <input> and messaging the background
// script) on EVERY DOM mutation is what was making pages feel laggy —
// sites with any amount of dynamic content (ads, React re-renders, etc.)
// mutate the DOM dozens of times per second.
let debounceTimer: ReturnType<typeof setTimeout> | null = null;
const observer = new MutationObserver(() => {
  if (debounceTimer) clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => {
    checkAndShowOverlays();
  }, 400);
});
observer.observe(document.body, { childList: true, subtree: true });
