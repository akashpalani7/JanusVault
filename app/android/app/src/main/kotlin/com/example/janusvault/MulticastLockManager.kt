package com.example.janusvault

import android.content.Context
import android.net.wifi.WifiManager

class MulticastLockManager(private val context: Context) {
    private var lock: WifiManager.MulticastLock? = null

    fun acquire() {
        if (lock?.isHeld == true) return
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        lock = wifi.createMulticastLock("JanusVault_mDNS").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    fun release() {
        lock?.takeIf { it.isHeld }?.release()
        lock = null
    }
}
