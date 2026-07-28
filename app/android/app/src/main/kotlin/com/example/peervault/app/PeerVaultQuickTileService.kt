package com.example.peervault.app

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * The quick-settings-shade toggle you get by long-pressing the shade and
 * dragging "PeerVault listening" in, the same way WiFi/Bluetooth/mobile
 * data tiles work. Starts/stops PeerVaultSyncForegroundService — this
 * class holds no vault logic of its own.
 */
class PeerVaultQuickTileService : TileService() {
    companion object {
        private const val PREFS = "peervault_tile_prefs"
        private const val KEY_LISTENING = "listening"

        fun isListening(context: Context): Boolean = prefs(context).getBoolean(KEY_LISTENING, false)

        fun setListening(context: Context, value: Boolean) {
            prefs(context).edit().putBoolean(KEY_LISTENING, value).apply()
            TileService.requestListeningState(context, android.content.ComponentName(context, PeerVaultQuickTileService::class.java))
        }

        private fun prefs(context: Context): SharedPreferences =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        val turningOn = !isListening(applicationContext)
        setListening(applicationContext, turningOn)
        val intent = Intent(applicationContext, PeerVaultSyncForegroundService::class.java)
        if (turningOn) {
            startForegroundService(intent)
        } else {
            intent.action = PeerVaultSyncForegroundService.ACTION_STOP
            startService(intent)
        }
        updateTile()
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        val listening = isListening(applicationContext)
        tile.state = if (listening) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "PeerVault listening"
        tile.updateTile()
    }
}
