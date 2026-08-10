package com.example.peervault.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Owns a single, long-lived FlutterEngine dedicated to autofill work,
 * separate from the engine the main Activity uses. This lets autofill
 * suggestions work even when PeerVault's main UI has never been opened in
 * this process (e.g. right after the OS killed the app in the background).
 *
 * All actual vault/crypto logic lives in Dart (see autofill_entrypoint.dart)
 * — this class is purely plumbing: start the engine, run the Dart
 * `autofillMain` entrypoint, and forward MethodChannel calls with
 * coroutine-friendly suspend wrappers so PeerVaultAutofillService reads
 * top-to-bottom instead of nesting callbacks.
 *
 * IMPORTANT: `FlutterLoader.ensureInitializationCompleteAsync` is, despite
 * the name of the class calling it, genuinely asynchronous — it returns
 * immediately and runs its callback later. The previous version of this
 * file called it and then tried to `invoke(...)` right away, before the
 * engine/channel fields were ever assigned, which threw
 * "Autofill engine not started" on essentially every cold request. This
 * version uses a CompletableDeferred so every caller actually *waits* for
 * the engine to finish starting before issuing a method call.
 */
object AutofillBridge {
    private const val CHANNEL_NAME = "com.peervault.app/autofill"
    private const val DART_ENTRYPOINT = "autofillMain"
    private const val STARTUP_TIMEOUT_MS = 10_000L

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var readyDeferred: CompletableDeferred<Unit>? = null

    @Synchronized
    private fun startIfNeeded(context: Context): CompletableDeferred<Unit> {
        readyDeferred?.let { return it }

        val deferred = CompletableDeferred<Unit>()
        readyDeferred = deferred

        val loader = io.flutter.FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context.applicationContext)
        loader.ensureInitializationCompleteAsync(
            context.applicationContext,
            null,
            Handler(Looper.getMainLooper()),
        ) {
            try {
                val newEngine = FlutterEngine(context.applicationContext)
                GeneratedPluginRegistrant.registerWith(newEngine)

                val methodChannel = MethodChannel(newEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
                methodChannel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "ready" -> {
                            engine = newEngine
                            channel = methodChannel
                            result.success(null)
                            if (!deferred.isCompleted) deferred.complete(Unit)
                        }
                        "showApprovalNotification" -> {
                            val actionLabel = (call.arguments as? Map<*, *>)?.get("actionLabel") as? String ?: "access a saved password"
                            ApprovalNotifier.show(context.applicationContext, actionLabel)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }

                val entrypoint = DartExecutor.DartEntrypoint(loader.findAppBundlePath(), DART_ENTRYPOINT)
                android.util.Log.e("PeerVault", "Calling executeDartEntrypoint...")
                newEngine.dartExecutor.executeDartEntrypoint(entrypoint)
                android.util.Log.e("PeerVault", "executeDartEntrypoint completed!")
            } catch (e: Exception) {
                if (!deferred.isCompleted) deferred.completeExceptionally(e)
            }
        }
        return deferred
    }

    private suspend fun ensureReady(context: Context) {
        withTimeout(STARTUP_TIMEOUT_MS) {
            startIfNeeded(context).await()
        }
    }

    suspend fun searchEntries(context: Context, query: String): String {
        ensureReady(context)
        return invoke("searchEntries", mapOf("query" to query)) as String
    }

    suspend fun isUnlocked(context: Context): Boolean {
        ensureReady(context)
        return invoke("isUnlocked", null) as Boolean
    }

    suspend fun unlockVault(context: Context): Boolean {
        ensureReady(context)
        return invoke("unlockVault", null) as Boolean
    }

    suspend fun saveCapturedCredential(context: Context, websiteName: String, websiteUrl: String, username: String, password: String): Boolean {
        ensureReady(context)
        return invoke(
            "saveCapturedCredential",
            mapOf("websiteName" to websiteName, "websiteUrl" to websiteUrl, "username" to username, "password" to password),
        ) as Boolean
    }

    /** Starts the LAN sync listener — see _startSyncListening in
     * autofill_entrypoint.dart. Called by PeerVaultSyncForegroundService. */
    suspend fun startSyncListening(context: Context, displayName: String, bluetoothEnabled: Boolean) {
        ensureReady(context)
        invoke("startSyncListening", mapOf("displayName" to displayName, "bluetoothEnabled" to bluetoothEnabled))
    }

    suspend fun stopSyncListening(context: Context) {
        ensureReady(context)
        invoke("stopSyncListening", null)
    }

    /** Called from PeerVaultRemoteApprovalActivity once the user has
     * responded (and, if approving, passed BiometricPrompt) to the
     * "Approve access from your browser?" notification. Not a suspend
     * function and doesn't call ensureReady: this only ever gets called
     * while the engine is definitely already running, because the
     * notification that led here only exists because the engine posted it. */
    fun resolveApproval(approved: Boolean) {
        channel?.invokeMethod("resolveApproval", mapOf("approved" to approved))
    }

    private suspend fun invoke(method: String, args: Any?): Any? = suspendCancellableCoroutine { cont ->
        val ch = channel
        if (ch == null) {
            cont.resumeWithException(IllegalStateException("Autofill engine not started"))
            return@suspendCancellableCoroutine
        }
        ch.invokeMethod(
            method,
            args,
            object : MethodChannel.Result {
                override fun success(result: Any?) = cont.resume(result)
                override fun error(code: String, message: String?, details: Any?) =
                    cont.resumeWithException(RuntimeException("$code: $message"))
                override fun notImplemented() = cont.resumeWithException(RuntimeException("$method not implemented in Dart"))
            },
        )
    }
}
