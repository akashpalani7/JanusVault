package com.example.peervault.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * Posts the "Approve access from your browser?" notification when a
 * remote authRequest arrives while there's no app Activity already open
 * to show the normal in-app dialog (see main.dart's rootNavigatorKey
 * handler for that path, and autofill_entrypoint.dart's
 * _startSyncListening for this one). Tapping it launches
 * PeerVaultRemoteApprovalActivity, a transparent trampoline that can run
 * BiometricPrompt (needs a real Activity — this notification-posting code
 * can't do that itself) and reports the result back into the SAME running
 * background engine via AutofillBridge.resolveApproval.
 */
object ApprovalNotifier {
    private const val CHANNEL_ID = "peervault_approval"
    private const val NOTIFICATION_ID = 4242

    fun show(context: Context, actionLabel: String) {
        ensureChannel(context)

        val intent = Intent(context, PeerVaultRemoteApprovalActivity::class.java).apply {
            putExtra(PeerVaultRemoteApprovalActivity.EXTRA_ACTION_LABEL, actionLabel)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle("Approve from your browser?")
            .setContentText("Your PeerVault browser extension wants to $actionLabel.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, notification)
    }

    fun dismiss(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(NOTIFICATION_ID)
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(CHANNEL_ID, "PeerVault approval requests", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Asks you to approve reveal/autofill requests from a paired browser."
        }
        manager.createNotificationChannel(channel)
    }
}
