import { SyncMessage } from "./models.js";

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
 * Requires the phone to have "Make this device visible for sync" turned
 * on (Sync screen) so it's listening at all. If it can't be reached
 * within `timeoutMs`, resolves "unreachable" rather than throwing, so
 * callers can fall back to the local quick-PIN gate instead of hanging.
 */
export function requestPhoneApproval(
  host: string,
  port: number,
  actionLabel: string,
  timeoutMs = 20000,
): Promise<PhoneAuthOutcome> {
  return new Promise((resolve) => {
    let settled = false;
    const requestId = crypto.randomUUID();
    let socket: WebSocket;

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

    socket.onopen = () => {
      const message: SyncMessage = { type: "authRequest", payload: { requestId, actionLabel } };
      socket.send(JSON.stringify(message));
    };

    socket.onmessage = (event) => {
      try {
        const message = JSON.parse(event.data) as SyncMessage;
        if (message.type === "authResponse" && message.payload.requestId === requestId) {
          finish(message.payload.approved ? "approved" : "denied");
        }
        // Ignore anything else (e.g. an unsolicited deviceInfo broadcast
        // the phone sends to every new connection) — we only care about
        // the matching authResponse here.
      } catch {
        // Malformed frame — ignore rather than crash the popup.
      }
    };

    socket.onerror = () => finish("unreachable");
    socket.onclose = () => finish("unreachable");
  });
}
