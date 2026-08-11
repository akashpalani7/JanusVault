package com.example.janusvault.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Keeps JanusVault listening for LAN sync + BLE GATT + phone-approval
 * requests even when the app is fully closed — toggled from
 * JanusVaultQuickTileService or the in-app Sync screen.
 *
 * Bluetooth handling:
 *   - If Bluetooth is OFF when the service starts, it is automatically
 *     turned ON (requires BLUETOOTH_CONNECT permission on API 31+).
 *     When the service stops (either manually or via the 120-second
 *     auto-killswitch), Bluetooth is turned back OFF.
 *   - If Bluetooth was ALREADY ON (user was using it), it is left alone
 *     when the service stops — we only turn off what we turned on.
 *
 * A plain background task would get killed by Android fairly quickly;
 * a foreground service with a persistent (but low-priority, silent)
 * notification is the standard, battery-reasonable way to stay alive.
 */
class JanusVaultSyncForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "janusvault_listening"
        private const val NOTIFICATION_ID = 4243
        const val ACTION_STOP = "com.example.janusvault.app.ACTION_STOP_LISTENING"

        private const val PREFS = "janusvault_tile_prefs"
        private const val KEY_BT_WAS_OFF = "bt_turned_on_by_us"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        scope.launch {
            try {
                // Auto-enable Bluetooth if it's currently off
                ensureBluetoothOn()

                // Check final bluetooth state to avoid intrusive OS dialogs from the Flutter plugin
                val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
                val isBluetoothOn = btManager?.adapter?.isEnabled == true

                // Start both LAN and BLE listeners
                AutofillBridge.startSyncListening(applicationContext, deviceName(), isBluetoothOn)
                
                // Auto turn off listening in 120 seconds to prevent battery drain
                kotlinx.coroutines.delay(120_000L)
                stopSelf()
            } catch (e: Exception) {
                android.util.Log.e("JanusVault", "Sync service start failed: ${e.message}", e)
                // Couldn't start (e.g. vault not set up on this device yet) —
                // stop ourselves rather than sit in the foreground doing nothing.
                stopSelf()
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        scope.launch { AutofillBridge.stopSyncListening(applicationContext) }
        // Restore Bluetooth state if we were the ones who turned it on
        restoreBluetoothState()
        JanusVaultQuickTileService.setListening(applicationContext, false)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ─────────────────────────────────────────────────────────
    //  Bluetooth Auto-Toggle
    // ─────────────────────────────────────────────────────────

    /**
     * If Bluetooth is off, turn it on and remember that we did so.
     * On API 31+ (Android 12+), the BLUETOOTH_CONNECT permission is
     * required — if not granted, we skip silently (BLE won't work but
     * LAN sync still will).
     *
     * On API 33+ (Android 13+), apps cannot programmatically enable
     * Bluetooth without user interaction. In that case, we log a
     * warning and proceed without BLE — the user must enable Bluetooth
     * manually from the notification shade.
     */
    @Suppress("DEPRECATION")
    private fun ensureBluetoothOn() {
        try {
            val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager ?: return
            val adapter = btManager.adapter ?: return

            if (!adapter.isEnabled) {
                val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                prefs.edit().putBoolean(KEY_BT_WAS_OFF, true).apply()
                adapter.enable()
                android.util.Log.i("JanusVault", "Bluetooth turned ON by JanusVault (will be turned off when listening stops)")
            } else {
                // Bluetooth was already on — don't touch it on shutdown
                val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                prefs.edit().putBoolean(KEY_BT_WAS_OFF, false).apply()
                android.util.Log.i("JanusVault", "Bluetooth already ON — will not turn off on shutdown")
            }
        } catch (e: SecurityException) {
            android.util.Log.w("JanusVault", "No BLUETOOTH_CONNECT permission — skipping BLE: ${e.message}")
        }
    }

    /**
     * If we turned Bluetooth on, turn it back off. If the user had
     * Bluetooth on before we started, leave it alone.
     */
    @Suppress("DEPRECATION")
    private fun restoreBluetoothState() {
        try {
            val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val weTurnedItOn = prefs.getBoolean(KEY_BT_WAS_OFF, false)
            prefs.edit().remove(KEY_BT_WAS_OFF).apply()

            if (weTurnedItOn) {
                val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager ?: return
                val adapter = btManager.adapter ?: return
                if (adapter.isEnabled) {
                    adapter.disable()
                    android.util.Log.i("JanusVault", "Bluetooth turned OFF by JanusVault (was turned on by us)")
                }
            }
        } catch (e: SecurityException) {
            android.util.Log.w("JanusVault", "Could not restore BT state: ${e.message}")
        }
    }

    // ─────────────────────────────────────────────────────────
    //  Notification
    // ─────────────────────────────────────────────────────────

    private fun deviceName(): String = Build.MODEL ?: "Android device"

    private fun buildNotification(text: String = "Ready for sync and approval requests from your paired devices.") =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle("JanusVault Listener")
            .setContentText(text)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()

    private fun updateNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(CHANNEL_ID, "JanusVault Listener", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shown while JanusVault is listening for sync/approval requests in the background."
        }
        manager.createNotificationChannel(channel)
    }
}
