package com.example.peervault.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Keeps PeerVault listening for LAN sync + phone-approval requests even
 * when the app is fully closed — toggled from PeerVaultQuickTileService
 * or the in-app Sync screen. A plain background task would get killed by
 * Android fairly quickly; a foreground service with a persistent (but
 * low-priority, silent) notification is the standard, battery-reasonable
 * way to legitimately stay alive for this.
 *
 * All it does is start/stop the SAME background FlutterEngine used for
 * autofill (see AutofillBridge.kt) with the sync listener running inside
 * it — no vault logic lives here.
 */
class PeerVaultSyncForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "peervault_listening"
        private const val NOTIFICATION_ID = 4243
        const val ACTION_STOP = "com.example.peervault.app.ACTION_STOP_LISTENING"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        scope.launch {
            try {
                AutofillBridge.startSyncListening(applicationContext, deviceName())
                
                // Auto turn off listening in 120 seconds to prevent battery drain
                kotlinx.coroutines.delay(120_000L)
                stopSelf()
            } catch (_: Exception) {
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
        PeerVaultQuickTileService.setListening(applicationContext, false)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun deviceName(): String = Build.MODEL ?: "Android device"

    private fun buildNotification() = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(android.R.drawable.ic_lock_lock)
        .setContentTitle("PeerVault is listening")
        .setContentText("Ready for sync and approval requests from your paired devices.")
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setOngoing(true)
        .build()

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(CHANNEL_ID, "PeerVault background listening", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shown while PeerVault is listening for sync/approval requests in the background."
        }
        manager.createNotificationChannel(channel)
    }
}
