package com.akash.janusvault

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.akash.janusvault.app.ApprovalNotifier

class MainActivity : FlutterFragmentActivity() {
    companion object {
        var mainChannel: MethodChannel? = null
        
        fun resolveApproval(approved: Boolean) {
            mainChannel?.invokeMethod("resolveApproval", mapOf("approved" to approved))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.janusvault.app/main_auth")
        mainChannel = channel
        
        val multicastLockManager = MulticastLockManager(this)
        
        channel.setMethodCallHandler { call, result ->
            if (call.method == "showApprovalNotification") {
                val actionLabel = (call.arguments as? Map<*, *>)?.get("actionLabel") as? String ?: "access a saved password"
                ApprovalNotifier.show(applicationContext, actionLabel)
                result.success(null)
            } else if (call.method == "acquireMulticastLock") {
                multicastLockManager.acquire()
                result.success(null)
            } else if (call.method == "releaseMulticastLock") {
                multicastLockManager.release()
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}
