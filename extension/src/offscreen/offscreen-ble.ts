// @ts-nocheck
const PEERVAULT_SERVICE_UUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
const SYNC_CHARACTERISTIC_UUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567891';
const EOM_MARKER = '\x04';
const MAX_CHUNK_SIZE = 480;

let bleDevice: BluetoothDevice | null = null;
let syncCharacteristic: BluetoothRemoteGATTCharacteristic | null = null;
let incomingBuffer = '';

// Listen for messages from the extension service worker / popup
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'START_BLE_CONNECTION') {
    startBleConnection()
      .then(() => sendResponse({ success: true }))
      .catch((err) => sendResponse({ success: false, error: err.message }));
    return true; // async response
  }
  
  if (message.type === 'BLE_SEND_MESSAGE') {
    sendJsonMessage(message.payload)
      .then(() => sendResponse({ success: true }))
      .catch((err) => sendResponse({ success: false, error: err.message }));
    return true;
  }

  if (message.type === 'DISCONNECT_BLE') {
    if (bleDevice && bleDevice.gatt?.connected) {
      bleDevice.gatt.disconnect();
    }
    sendResponse({ success: true });
    return false;
  }
});

async function startBleConnection(): Promise<void> {
  if (!navigator.bluetooth) {
    throw new Error('Web Bluetooth API is not supported in this browser.');
  }

  // Pop up the system BLE picker to user
  bleDevice = await navigator.bluetooth.requestDevice({
    filters: [{ services: [PEERVAULT_SERVICE_UUID] }],
  });

  if (!bleDevice.gatt) {
    throw new Error('Device does not support GATT.');
  }

  bleDevice.addEventListener('gattserverdisconnected', onDisconnected);

  const server = await bleDevice.gatt.connect();
  const service = await server.getPrimaryService(PEERVAULT_SERVICE_UUID);
  syncCharacteristic = await service.getCharacteristic(SYNC_CHARACTERISTIC_UUID);

  // Subscribe to incoming messages (notifications)
  await syncCharacteristic.startNotifications();
  syncCharacteristic.addEventListener('characteristicvaluechanged', handleCharacteristicValueChanged);

  // Notify background script we are connected
  chrome.runtime.sendMessage({ type: 'BLE_STATUS_UPDATE', status: 'connected' });
}

function onDisconnected() {
  chrome.runtime.sendMessage({ type: 'BLE_STATUS_UPDATE', status: 'disconnected' });
  bleDevice = null;
  syncCharacteristic = null;
}

function handleCharacteristicValueChanged(event: Event) {
  const target = event.target as BluetoothRemoteGATTCharacteristic;
  const value = target.value;
  if (!value) return;

  const decoder = new TextDecoder('utf-8');
  const chunk = decoder.decode(value);
  
  if (chunk.endsWith(EOM_MARKER)) {
    incomingBuffer += chunk.substring(0, chunk.length - EOM_MARKER.length);
    const completeMessage = incomingBuffer;
    incomingBuffer = '';
    
    // Forward parsed message to service worker
    try {
      chrome.runtime.sendMessage({ 
        type: 'BLE_MESSAGE_RECEIVED', 
        payload: completeMessage 
      });
    } catch (e) {
      console.error('Failed to parse incoming BLE JSON:', e);
    }
  } else {
    incomingBuffer += chunk;
  }
}

async function sendJsonMessage(jsonString: string): Promise<void> {
  if (!syncCharacteristic) throw new Error('Not connected to BLE device.');
  
  const payload = jsonString + EOM_MARKER;
  const encoder = new TextEncoder();
  const bytes = encoder.encode(payload);
  
  // Write chunks sequentially
  for (let offset = 0; offset < bytes.length; offset += MAX_CHUNK_SIZE) {
    const end = Math.min(offset + MAX_CHUNK_SIZE, bytes.length);
    const chunk = bytes.slice(offset, end);
    // writeValueWithoutResponse is significantly faster and typically handles larger MTUs
    // automatically in modern Chrome, but some fallback might be needed if it fails.
    if ('writeValueWithoutResponse' in syncCharacteristic) {
       await syncCharacteristic.writeValueWithoutResponse(chunk);
    } else {
       await syncCharacteristic.writeValue(chunk);
    }
  }
}
