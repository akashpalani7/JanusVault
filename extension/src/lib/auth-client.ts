import { SyncMessage } from "./models.js";
import { hmacSha256 } from "./crypto.js";
import { ExtensionStorage } from "./storage.js";

export type PhoneAuthOutcome = "approved" | "denied" | "unreachable" | "timeout";

/**
 * Asks the phone app to show an approve/deny + biometric prompt for the
 * given action, over the SAME LAN connection used for sync (see
 * lan_sync_service.dart's `authRequest`/`authResponse` handling). This is
 * the actual "ask for authentication on the phone" flow — the browser
 * extension has no fingerprint sensor of its own, so it borrows the
 * phone's, over the LAN, every single time a password is revealed,
 * autofilled, or copied.
 *
 * `syncAuthKey` is derived from the VEK (see crypto.ts's
 * deriveSyncAuthKey) — the phone challenges every new connection with a
 * nonce and won't process anything beyond that handshake until answered
 * correctly, so a stranger on the same WiFi can't reach this endpoint at
 * all, let alone trigger an approval prompt. We wait for the phone's
 * unsolicited `deviceInfo` broadcast (sent only AFTER it accepts our
 * handshake response) as proof we're clear to send the real request,
 * rather than assuming any particular message ordering.
 *
 * Requires the phone to have "Make this device visible for sync" turned
 * on (Sync screen) so it's listening at all. If it can't be reached
 * within `timeoutMs`, resolves "unreachable" — there is deliberately no
 * fallback of any kind; the caller must treat that as a refusal.
 */
export function requestPhoneApproval(
  host: string,
  port: number,
  actionLabel: string,
  syncAuthKey: CryptoKey,
  timeoutMs = 60000,
): Promise<PhoneAuthOutcome> {
  return new Promise((resolve) => {
    let settled = false;
    let authRequestSent = false;
    const requestId = crypto.randomUUID();
    let socket: WebSocket;
    let sentNonceBase64 = "";

    const finish = (outcome: PhoneAuthOutcome) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        socket?.close();
      } catch {
        // socket may already be closed/closing — nothing to do
      }
      resolve(outcome);
    };

    const timer = setTimeout(() => finish("timeout"), timeoutMs);

    try {
      socket = new WebSocket(`ws://${host}:${port}`);
    } catch {
      clearTimeout(timer);
      resolve("unreachable");
      return;
    }

    socket.onmessage = async (event) => {
      try {
        const message = JSON.parse(event.data) as SyncMessage;

        if (message.type === "hello") {
          console.log(`Auth socket: Answering phone's hello challenge...`);
          const nonce = message.payload.nonce as string;
          const mac = await hmacSha256(syncAuthKey, nonce);
          socket.send(JSON.stringify({ type: "helloResponse", payload: { mac } } satisfies SyncMessage));
          return;
        }

        if (message.type === "helloResponse") {
          return;
        }

        if (message.type === "deviceInfo" && !authRequestSent) {
          authRequestSent = true;
          const deviceId = (await ExtensionStorage.getDeviceId()) || "";
          socket.send(JSON.stringify({ type: "authRequest", payload: { requestId, actionLabel, deviceId } } satisfies SyncMessage));
          return;
        }

        if (message.type === "authResponse" && message.payload.requestId === requestId) {
          console.log(`Auth socket: Received response: ${message.payload.approved}`);
          finish(message.payload.approved ? "approved" : "denied");
          return;
        }

        if (message.type === "error") {
          const errMsg = (message.payload.message || "") as string;
          if (errMsg.toLowerCase().includes("revoked")) {
            await ExtensionStorage.wipeAll();
            chrome.runtime.sendMessage({ type: "LOCK_VAULT" }).catch(() => {});
          }
          finish("denied");
          return;
        }
      } catch {
        // Malformed frame — ignore rather than crash the popup.
      }
    };

    socket.onopen = () => {
      console.log(`Auth socket: Opened connection to ${host}:${port}. Sending hello challenge...`);
      const nonce = crypto.getRandomValues(new Uint8Array(16));
      sentNonceBase64 = btoa(String.fromCharCode(...nonce));
      socket.send(JSON.stringify({ type: "hello", payload: { nonce: sentNonceBase64 } } satisfies SyncMessage));
    };

    socket.onerror = () => {
      console.error(`Auth socket error: Could not connect to ${host}:${port}`);
      finish("unreachable");
    }
    socket.onclose = () => finish("unreachable");
  });
}
