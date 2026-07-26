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

        val loader = FlutterLoader()
        loader.startInitialization(context.applicationContext)
        loader.ensureInitializationCompleteAsync(
            context.applicationContext,
            null,
            Handler(Looper.getMainLooper()),
        ) {
            try {
                val newEngine = FlutterEngine(context.applicationContext)
                GeneratedPluginRegistrant.registerWith(newEngine)

                val entrypoint = DartExecutor.DartEntrypoint(loader.findAppBundlePath(), DART_ENTRYPOINT)
                newEngine.dartExecutor.executeDartEntrypoint(entrypoint)

                val methodChannel = MethodChannel(newEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
                methodChannel.setMethodCallHandler { call, result ->
                    if (call.method == "ready") {
                        engine = newEngine
                        channel = methodChannel
                        result.success(null)
                        if (!deferred.isCompleted) deferred.complete(Unit)
                    } else {
                        // Requests FROM Dart back to native aren't used today,
                        // but the handler must exist to avoid MissingPluginException.
                        result.notImplemented()
                    }
                }
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

    suspend fun saveCapturedCredential(context: Context, appIdentifier: String, username: String, password: String): Boolean {
        ensureReady(context)
        return invoke(
            "saveCapturedCredential",
            mapOf("appIdentifier" to appIdentifier, "username" to username, "password" to password),
        ) as Boolean
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
