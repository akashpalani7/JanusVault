// @ts-nocheck
import { runSyncProtocol, SyncTransport } from '../lib/sync-client.js';
import { deriveEcdhSharedSecret, exportJwEcdhKey, generateEcdhKeyPair, computeEcdhPin, hmacSha256 } from '../lib/crypto.js';
import { ExtensionStorage } from '../lib/storage.js';
const JANUSVAULT_SERVICE_UUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
const SYNC_CHARACTERISTIC_UUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567891';
const EOM_MARKER = '\x04';
const MAX_CHUNK_SIZE = 480;

let bleDevice: BluetoothDevice | null = null;
let syncCharacteristic: BluetoothRemoteGATTCharacteristic | null = null;
let incomingBuffer = '';
let isBleBusy = false;



chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === 'BLE_EXECUTE_AUTH') {
        if (isBleBusy) { sendResponse({ outcome: "unreachable", error: "Bluetooth adapter is busy" }); return true; }
        isBleBusy = true;
        incomingBuffer = ''; // Crucial to prevent stale bytes triggering JSON parse errors
        executeBleAuth(message.actionLabel, message.requestId, Uint8Array.from(message.syncAuthKeyRaw))
            .then((approved) => sendResponse({ outcome: approved ? "approved" : "denied" }))
            .catch((err) => sendResponse({ outcome: "unreachable", error: err.message }))
            .finally(() => { isBleBusy = false; });
        return true; // Keep message channel open
    } else if (message.type === 'BLE_EXECUTE_SYNC') {
        if (isBleBusy) { sendResponse({ ok: false, error: "Bluetooth adapter is busy" }); return true; }
        isBleBusy = true;
        incomingBuffer = ''; // Clear stale data
        executeBleSync(message.vekRaw, message.forcePrompt)
            .then((result) => sendResponse(result))
            .catch((err) => sendResponse({ ok: false, error: err.message }))
            .finally(() => { isBleBusy = false; });
        return true;
    } else if (message.type === 'BLE_EXECUTE_PAIRING') {
        incomingBuffer = '';
        executeBlePairing(message.deviceName, message.deviceId)
            .then((result) => sendResponse(result))
            .catch((err) => sendResponse({ success: false, reason: err.message }));
        return true;
    }
});

async function sendJsonMessage(jsonString: string): Promise<void> {
    if (!syncCharacteristic) throw new Error('Not connected to BLE device.');
    const payload = jsonString + EOM_MARKER;
    const encoder = new TextEncoder();
    const bytes = encoder.encode(payload);
    for (let offset = 0; offset < bytes.length; offset += MAX_CHUNK_SIZE) {
        const end = Math.min(offset + MAX_CHUNK_SIZE, bytes.length);
        const chunk = bytes.slice(offset, end);
        await syncCharacteristic.writeValue(chunk);
    }
}

async function executeBleAuth(actionLabel: string, requestId: string, authKeyRaw: Uint8Array): Promise<boolean> {
    if (!navigator.bluetooth) throw new Error('Web Bluetooth API is not supported in this browser.');

    const { device, char } = await connectToAuthorizedDevice();
    bleDevice = device;
    syncCharacteristic = char;

    const finishEarly = () => {
        try { bleDevice?.gatt?.disconnect(); } catch (e) { }
        syncCharacteristic = null;
    };

    const authKey = await crypto.subtle.importKey("raw", authKeyRaw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);

    return new Promise(async (resolve, reject) => {
        let closed = false;
        let authRequestSent = false;

        // Timeout fallback matching lan sync
        const timer = setTimeout(() => {
            finish(false, new Error("Timeout waiting for phone BLE auth approval."));
        }, 60000);

        const finish = (approved: boolean, err?: Error) => {
            if (closed) return;
            closed = true;
            clearTimeout(timer);
            finishEarly();
            if (err) reject(err); else resolve(approved);
        };

        bleDevice!.addEventListener('gattserverdisconnected', () => {
            if (!closed) finish(false, new Error("BLE connection unexpectedly disconnected"));
        });

        syncCharacteristic!.addEventListener('characteristicvaluechanged', (event: any) => {
            const dataView = event.target.value;
            const text = new TextDecoder().decode(dataView);
            incomingBuffer += text;

            while (incomingBuffer.includes(EOM_MARKER)) {
                const eomIdx = incomingBuffer.indexOf(EOM_MARKER);
                const fullMessage = incomingBuffer.substring(0, eomIdx);
                incomingBuffer = incomingBuffer.substring(eomIdx + 1);

                (async () => {
                    try {
                        const msg = JSON.parse(fullMessage);
                        if (msg.type === "hello") {
                            const mac = await hmacSha256(authKey, msg.payload.nonce);
                            await sendJsonMessage(JSON.stringify({ type: "helloResponse", payload: { mac } }));
                        } else if (msg.type === "deviceInfo" && !authRequestSent) {
                            authRequestSent = true;
                            await sendJsonMessage(JSON.stringify({ type: "authRequest", payload: { requestId, actionLabel } }));
                        } else if (msg.type === "authResponse" && msg.payload.requestId === requestId) {
                            finish(!!msg.payload.approved);
                        }
                    } catch (e) {
                        console.error("BLE auth JSON parsing error", e);
                    }
                })();
            }
        });

        try {
            await syncCharacteristic!.startNotifications();
            await new Promise(r => setTimeout(r, 500)); // Give Windows BT stack time
            const nonce = crypto.getRandomValues(new Uint8Array(16));
            const sentNonceBase64 = btoa(String.fromCharCode(...nonce));
            await sendJsonMessage(JSON.stringify({ type: "hello", payload: { nonce: sentNonceBase64 } }));
        } catch (e) {
            clearTimeout(timer);
            reject(e);
        }
    });
}

async function connectToDevice(paired: BluetoothDevice): Promise<{
    device: BluetoothDevice;
    char: BluetoothRemoteGATTCharacteristic;
}> {
    const isMacOS = navigator.userAgent.includes("Mac OS X");

    if (!paired.gatt!.connected) {
        console.log(`[Ext/BLE] Device ${paired.id} not connected, handling potential MAC roll...`);

        // On macOS, watchAdvertisements() is not supported by the Chromium
        // WebBluetooth implementation. Attempting it causes a guaranteed
        // 3-second timeout delay before every reconnect, which degrades UX
        // significantly and can make users think they need to re-pair.
        //
        // The fix: on macOS, skip advertisement watching entirely and go
        // straight to gatt.connect() with retries. The Chromium macOS BLE
        // stack handles address resolution internally during connect(),
        // so watchAdvertisements() was never actually needed there — it was
        // only helpful on Windows where the OS-level BLE cache can go stale
        // after a peripheral's MAC address rotates.
        if (!isMacOS) {
            const abortController = new AbortController();
            try {
                const adPromise = new Promise((resolve) => {
                    paired.addEventListener('advertisementreceived', (event) => {
                        console.log("[Ext/BLE] Sighted advertisement! Internal MAC cache updated.");
                        resolve(true);
                    }, { once: true, signal: abortController.signal });
                });

                try {
                    // @ts-ignore
                    await paired.watchAdvertisements({ signal: abortController.signal });
                } catch(e) {
                    console.warn("[Ext/BLE] watchAdvertisements failed (non-macOS):", e);
                }

                await Promise.race([
                    adPromise,
                    new Promise((_, reject) => setTimeout(() => reject(new Error("Ad timeout")), 2000))
                ]);
            } catch (e) {
                // Timed out or failed — fall through to direct connect
                console.warn("[Ext/BLE] Ad check timed out, proceeding to direct connect:", e);
            } finally {
                abortController.abort();
            }
        } else {
            console.log("[Ext/BLE] macOS detected — skipping watchAdvertisements(), connecting directly.");
        }
    }

    // Connect with retries. On macOS, the first attempt often succeeds
    // immediately since the OS handles BLE address resolution during
    // connect(). On Windows, if watchAdvertisements() timed out above,
    // the retries give the OS BLE cache time to refresh.
    let server: BluetoothRemoteGATTServer;
    const maxRetries = isMacOS ? 5 : 4;
    const retryDelay = isMacOS ? 800 : 1000;
    for (let i = 0; i < maxRetries; i++) {
        try {
            server = await paired.gatt!.connect();
            break;
        } catch (e) {
            if (i === maxRetries - 1) throw e;
            console.warn(`[Ext/BLE] GATT connect attempt ${i + 1}/${maxRetries} failed, retrying in ${retryDelay}ms...`);
            await new Promise(r => setTimeout(r, retryDelay));
        }
    }

    let service;
    try {
        service = await server!.getPrimaryService(JANUSVAULT_SERVICE_UUID);
    } catch (e: any) {
        if (e.message?.includes('reconnect') || e.message?.includes('connect first') || e.message?.includes('disconnected')) {
            console.log("[Ext/BLE] Chrome GATT state desynced! Forcing hard reconnect...");
            await paired.gatt!.connect();
            service = await paired.gatt!.getPrimaryService(JANUSVAULT_SERVICE_UUID);
        } else {
            throw e;
        }
    }

    const char = await service.getCharacteristic(SYNC_CHARACTERISTIC_UUID);
    return { device: paired, char };
}

async function connectToAuthorizedDevice(): Promise<{
    device: BluetoothDevice;
    char: BluetoothRemoteGATTCharacteristic;
}> {
    const devices = await navigator.bluetooth.getDevices();
    if (devices.length === 0) throw new Error('No previously paired JanusVault device found.');
    let lastErr;
    for (const dev of devices) {
        try {
            return await connectToDevice(dev);
        } catch (e) {
            lastErr = e;
        }
    }
    throw lastErr || new Error("Failed to connect to any paired device");
}

async function executeBleSync(vekRaw: number[], forcePrompt: boolean): Promise<{ ok: boolean, pulled: number, pushed: number }> {
    const devices = await navigator.bluetooth.getDevices();
    if (devices.length === 0) throw new Error('No previously paired JanusVault device found.');

    let totalPulled = 0;
    let totalPushed = 0;
    let successCount = 0;
    let lastErr;

    for (const paired of devices) {
        try {
            incomingBuffer = '';
            const { device, char } = await connectToDevice(paired);

            await new Promise<void>(async (resolve, reject) => {
                let inboundBuffer = "";
                let closing = false;
                let writeQueue: (() => Promise<void>)[] = [];
                let isWriting = false;

                const processWriteQueue = async () => {
                    if (isWriting) return;
                    isWriting = true;
                    try {
                        while (writeQueue.length > 0) {
                            const task = writeQueue.shift();
                            if (task) await task();
                        }
                    } finally {
                        isWriting = false;
                    }
                };

                const transport: SyncTransport = {
                    send: (msg) => {
                        return new Promise((res, rej) => {
                            writeQueue.push(async () => {
                                try {
                                    const encoder = new TextEncoder();
                                    const bytes = encoder.encode(msg + EOM_MARKER);
                                    const chunkSize = 480;
                                    for (let i = 0; i < bytes.length; i += chunkSize) {
                                        const end = Math.min(i + chunkSize, bytes.length);
                                        const chunk = bytes.slice(i, end);
                                        await char.writeValue(chunk);
                                    }
                                    res();
                                } catch (e) {
                                    rej(e);
                                }
                            });
                            processWriteQueue();
                        });
                    },
                    close: () => {
                        closing = true;
                        if (device.gatt?.connected) device.gatt.disconnect();
                    },
                    onMessage: null,
                    onError: null,
                };

                const changeListener = (event: any) => {
                    const dataView = event.target.value;
                    const text = new TextDecoder().decode(dataView);
                    inboundBuffer += text;

                    while (inboundBuffer.includes(EOM_MARKER)) {
                        const eomIdx = inboundBuffer.indexOf(EOM_MARKER);
                        const fullMessage = inboundBuffer.substring(0, eomIdx);
                        inboundBuffer = inboundBuffer.substring(eomIdx + 1);
                        transport.onMessage?.(fullMessage);
                    }
                };

                const disconnectListener = () => {
                    if (closing) return;
                    const err = new Error("BLE connection unexpectedly disconnected");
                    if (transport.onError) transport.onError(err);
                    else reject(err);
                };

                char.addEventListener('characteristicvaluechanged', changeListener);
                device.addEventListener('gattserverdisconnected', disconnectListener);

                try {
                    await char.startNotifications();
                    await new Promise(r => setTimeout(r, 500)); // Give Windows BT stack time
                } catch (e) {
                    reject(e);
                    return;
                }

                const vek = await crypto.subtle.importKey("raw", Uint8Array.from(vekRaw), { name: "AES-GCM" }, true, ["encrypt", "decrypt"]);
                runSyncProtocol(transport, vek,
                    (res) => {
                        char.removeEventListener('characteristicvaluechanged', changeListener);
                        device.removeEventListener('gattserverdisconnected', disconnectListener);
                        totalPulled += res.pulled;
                        totalPushed += res.pushed;
                        resolve();
                    },
                    (err) => {
                        char.removeEventListener('characteristicvaluechanged', changeListener);
                        device.removeEventListener('gattserverdisconnected', disconnectListener);
                        reject(err);
                    }
                );
            });
            successCount++;
        } catch (e) {
            lastErr = e;
            console.warn(`[Ext/BLE] Failed to sync with device ${paired.id}:`, e);
        }
    }

    if (successCount === 0) throw lastErr || new Error("Failed to sync with any paired device.");
    return { ok: true, pulled: totalPulled, pushed: totalPushed };
}

async function executeBlePairing(deviceName: string, deviceId: string): Promise<any> {
    incomingBuffer = '';
    const { device, char } = await connectToAuthorizedDevice();
    let myKeyPair: CryptoKeyPair;
    let lastSharedSecret: Uint8Array | null = null;
    let inboundBuffer = "";

    return new Promise(async (resolve, reject) => {
        let closing = false;
        const finish = (res: any) => {
            if (closing) return;
            closing = true;
            if (device.gatt?.connected) device.gatt.disconnect();
            resolve(res);
        };

        const send = async (msg: string) => {
            const encoder = new TextEncoder();
            const bytes = encoder.encode(msg + EOM_MARKER);
            const chunkSize = 480;
            for (let i = 0; i < bytes.length; i += chunkSize) {
                const end = Math.min(i + chunkSize, bytes.length);
                const chunk = bytes.slice(i, end);
                await char.writeValue(chunk);
            }
        };

        char.addEventListener('characteristicvaluechanged', async (event: any) => {
            const dataView = event.target.value;
            const text = new TextDecoder().decode(dataView);
            inboundBuffer += text;

            while (inboundBuffer.includes(EOM_MARKER)) {
                const eomIdx = inboundBuffer.indexOf(EOM_MARKER);
                const fullMessage = inboundBuffer.substring(0, eomIdx);
                inboundBuffer = inboundBuffer.substring(eomIdx + 1);

                try {
                    const message = JSON.parse(fullMessage);
                    if (message.type === "pairingChallenge") {
                        const peerJwk = message.payload.pubKey as string;
                        const sharedSecret = await deriveEcdhSharedSecret(myKeyPair.privateKey, peerJwk);
                        lastSharedSecret = sharedSecret;
                        const pin = await computeEcdhPin(sharedSecret);
                        chrome.runtime.sendMessage({ type: "BLE_PIN_READY", pin });
                    } else if (message.type === "pairingSuccess") {
                        const wrappedVek = message.payload.wrappedVek as string;
                        const peerDevice = message.payload.device;
                        finish({ success: true, wrappedVek, device: peerDevice, sharedSecret: lastSharedSecret! });
                    } else if (message.type === "error") {
                        finish({ success: false, reason: message.payload.message as string });
                    }
                } catch (e) {
                    finish({ success: false, reason: "Malformed response from phone." });
                }
            }
        });

        device.addEventListener('gattserverdisconnected', () => {
            if (closing) return;
            finish({ success: false, reason: "Phone dropped the connection abruptly or rejected." });
        });

        try {
            await char.startNotifications();
            await new Promise(r => setTimeout(r, 500)); // Give Windows BT stack time

            myKeyPair = await generateEcdhKeyPair();
            const jwk = await exportJwEcdhKey(myKeyPair.publicKey);
            await send(JSON.stringify({
                type: "pairingRequest",
                payload: {
                    deviceName,
                    pubKey: jwk,
                    clientName: deviceName,
                    platform: "browserExtension",
                    deviceId
                }
            }));
        } catch (e: any) {
            finish({ success: false, reason: `Bluetooth pairing failed: ${e.message || String(e)}` });
        }

        // 60-second fallback timeout
        setTimeout(() => finish({ success: false, reason: "Timeout waiting for phone BLE pairing approval." }), 60000);
    });
}
