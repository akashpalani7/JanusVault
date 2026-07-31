package com.example.peervault.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.Dataset
import android.service.autofill.FillCallback
import android.service.autofill.FillContext
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.InlinePresentation
import android.service.autofill.SaveCallback
import android.service.autofill.SaveInfo
import android.service.autofill.SaveRequest
import android.view.View
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import android.widget.inline.InlinePresentationSpec
import androidx.annotation.RequiresApi
import androidx.autofill.inline.UiVersions
import androidx.autofill.inline.v1.InlineSuggestionUi
import androidx.core.app.NotificationCompat
import com.example.peervault.MainActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * PeerVault's Android Autofill Framework entry point.
 *
 * Supports two rendering paths:
 *   1. **Inline Suggestions** (Android 11+ / API 30+): renders autofill
 *      suggestions as keyboard-strip chips. This is the path that Chromium-
 *      based browsers (Chrome, Brave, Edge) prefer — the legacy dropdown
 *      approach causes \"contents cannot be autofilled\" errors in browser
 *      renderer sandboxes.
 *   2. **Legacy dropdown** (API 26–29, or when InlineSuggestionsRequest is
 *      absent): the traditional RemoteViews popup.
 *
 * Both paths share the same matching + VEK/Dart bridge logic.
 */
class PeerVaultAutofillService : AutofillService() {

    private val serviceScope = CoroutineScope(Dispatchers.Main)

    override fun onFillRequest(request: FillRequest, cancellationSignal: CancellationSignal, callback: FillCallback) {
        val context: FillContext = request.fillContexts.last()
        val structure = context.structure
        val fields = FieldFinder.find(structure)

        if (fields.usernameId == null && fields.passwordId == null) {
            callback.onSuccess(null)
            return
        }

        serviceScope.launch {
            try {
                kotlinx.coroutines.withTimeout(4500L) {
                    val unlocked = AutofillBridge.isUnlocked(applicationContext)
                    val query = fields.appIdentifier

                    val responseBuilder = FillResponse.Builder()

                    // Determine whether the keyboard supports inline suggestions
                    val inlineSpecs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        request.inlineSuggestionsRequest?.inlinePresentationSpecs
                    } else null
                    val useInline = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !inlineSpecs.isNullOrEmpty()

                    if (unlocked) {
                        val raw = AutofillBridge.searchEntries(applicationContext, query)
                        val json = JSONObject(raw)
                        val entries = json.getJSONArray("entries")

                        for (i in 0 until entries.length()) {
                            val entry = entries.getJSONObject(i)
                            val websiteName = entry.getString("websiteName")
                            val username = entry.getString("username")
                            val password = entry.getString("password")

                            if (useInline && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                val spec = inlineSpecs!![minOf(i, inlineSpecs.size - 1)]
                                responseBuilder.addDataset(
                                    buildInlineDataset(fields, websiteName, username, password, spec, i)
                                )
                            } else {
                                responseBuilder.addDataset(
                                    buildDropdownDataset(fields, websiteName, username, password)
                                )
                            }
                        }

                        if (entries.length() == 0) {
                            val reqCodeOffset = query.hashCode()
                            // 1. Suggest Password Dataset
                            val suggestedPassword = generateStrongPassword(16)
                            val suggestPresentation = RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
                                setTextViewText(android.R.id.text1, "Suggest password: $suggestedPassword")
                            }
                            val suggestDataset = Dataset.Builder()
                            if (useInline && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                val dummyIntent = PendingIntent.getBroadcast(applicationContext, reqCodeOffset + 1003, Intent("com.example.peervault.DUMMY"), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                                val inlineSuggest = buildInlinePresentation(
                                    inlineSpecs!!.first(), "Suggest password", "Strong password", dummyIntent
                                )
                                fields.usernameId?.let { suggestDataset.setValue(it, AutofillValue.forText(suggestedPassword), suggestPresentation, inlineSuggest) }
                                fields.passwordId?.let { suggestDataset.setValue(it, AutofillValue.forText(suggestedPassword), suggestPresentation, inlineSuggest) }
                                responseBuilder.addDataset(suggestDataset.build())
                            }
                            // Do not return a Legacy Dropdown dataset for Suggest Password when useInline is false,
                            // as Chromium explicitly blocks RemoteViews dropdowns for unauthenticated data in modern Android.
                        }
                    } else {
                        // Vault is locked — push notification immediately instead of showing chips.
                        val appIntent = Intent(applicationContext, PeerVaultAutofillAuthActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                            putExtra("notify_only", true)
                        }
                        val pendingIntent = PendingIntent.getActivity(
                            applicationContext, 4001, appIntent,
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                        )

                        val channelId = "autofill_unlock"
                        val notificationManager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val channel = NotificationChannel(
                                channelId,
                                "Autofill Unlock",
                                NotificationManager.IMPORTANCE_HIGH
                            )
                            notificationManager.createNotificationChannel(channel)
                        }

                        val notification = NotificationCompat.Builder(applicationContext, channelId)
                            .setSmallIcon(android.R.drawable.ic_lock_lock)
                            .setContentTitle("PeerVault is Locked")
                            .setContentText("Tap here to unlock your vault and autofill passwords")
                            .setPriority(NotificationCompat.PRIORITY_HIGH)
                            .setContentIntent(pendingIntent)
                            .setAutoCancel(true)
                            .build()

                        notificationManager.notify(4001, notification)
                        
                        callback.onSuccess(null)
                        return@withTimeout
                    }

                    // SaveInfo — required for Android to call onSaveRequest after form submit
                    buildSaveInfo(fields)?.let { responseBuilder.setSaveInfo(it) }

                    android.util.Log.d("PeerVault", "Autofill onSuccess with inline=$useInline")
                    callback.onSuccess(responseBuilder.build())
                }
            } catch (e: Exception) {
                android.util.Log.e("PeerVault", "Autofill OS Timeout/Error: ${e.message}", e)
                callback.onSuccess(null)
            }
        }
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        val context: FillContext = request.fillContexts.last()
        val structure = context.structure
        val fields = FieldFinder.find(structure)

        var username = ""
        var password = ""
        structure.forEachViewNode { node ->
            val value = node.autofillValue
            if (value != null && value.isText) {
                if (node.autofillId == fields.usernameId) username = value.textValue.toString()
                if (node.autofillId == fields.passwordId) password = value.textValue.toString()
            }
        }

        if (password.isEmpty()) {
            callback.onFailure("No password captured")
            return
        }

        serviceScope.launch {
            try {
                if (!AutofillBridge.isUnlocked(applicationContext)) {
                    callback.onFailure("Unlock PeerVault to save this password")
                    return@launch
                }
                AutofillBridge.saveCapturedCredential(applicationContext, fields.appIdentifier, username, password)
                callback.onSuccess()
            } catch (e: Exception) {
                callback.onFailure(e.message)
            }
        }
    }

    private fun generateStrongPassword(length: Int): String {
        val charset = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*-_=+"
        val random = java.security.SecureRandom()
        val buf = CharArray(length)
        for (i in 0 until length) {
            buf[i] = charset[random.nextInt(charset.length)]
        }
        return String(buf)
    }

    // ─────────────────────────────────────────────────────────
    //  Inline Suggestions (API 30+) — keyboard-strip chips
    // ─────────────────────────────────────────────────────────

    @RequiresApi(Build.VERSION_CODES.R)
    private fun buildInlineDataset(
        fields: FieldFinder.Fields,
        websiteName: String,
        username: String,
        password: String,
        spec: InlinePresentationSpec,
        index: Int,
    ): Dataset {
        val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_2).apply {
            setTextViewText(android.R.id.text1, websiteName)
            setTextViewText(android.R.id.text2, username)
        }
        val dummyIntent = PendingIntent.getActivity(
            applicationContext, 
            2000 + index, 
            Intent(), 
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val inlinePresentation = buildInlinePresentation(spec, websiteName, username, dummyIntent)
        val builder = Dataset.Builder()
        fields.usernameId?.let { builder.setValue(it, AutofillValue.forText(username), presentation, inlinePresentation) }
        fields.passwordId?.let { builder.setValue(it, AutofillValue.forText(password), presentation, inlinePresentation) }
        return builder.build()
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun buildInlinePresentation(
        spec: InlinePresentationSpec,
        title: String,
        subtitle: String,
        pendingIntent: PendingIntent,
    ): InlinePresentation {
        // The Inline Suggestions API requires a PendingIntent even if we don't

        val slice = InlineSuggestionUi.newContentBuilder(pendingIntent)
            .setTitle(if (subtitle.isNotEmpty()) "$title | $subtitle" else title)
            .build()
            .slice

        return InlinePresentation(slice, spec, /* pinned= */ false)
    }

    // ─────────────────────────────────────────────────────────
    //  Legacy dropdown (API 26–29 / non-inline-capable IMEs)
    // ─────────────────────────────────────────────────────────

    private fun buildDropdownDataset(fields: FieldFinder.Fields, websiteName: String, username: String, password: String): Dataset {
        val builder = Dataset.Builder()
        val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_2).apply {
            setTextViewText(android.R.id.text1, websiteName)
            setTextViewText(android.R.id.text2, username)
        }
        fields.usernameId?.let { builder.setValue(it, AutofillValue.forText(username), presentation) }
        fields.passwordId?.let { builder.setValue(it, AutofillValue.forText(password), presentation) }
        return builder.build()
    }

    private fun buildSaveInfo(fields: FieldFinder.Fields): SaveInfo? {
        val passwordId = fields.passwordId ?: return null
        val saveDataTypes = SaveInfo.SAVE_DATA_TYPE_PASSWORD or
            (if (fields.usernameId != null) SaveInfo.SAVE_DATA_TYPE_USERNAME else 0)
        val requiredIds = listOfNotNull(fields.usernameId, passwordId).toTypedArray()
        
        val builder = SaveInfo.Builder(saveDataTypes, requiredIds)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setFlags(SaveInfo.FLAG_SAVE_ON_ALL_VIEWS_INVISIBLE)
        }
        return builder.build()
    }

}


/**
 * Walks an AssistStructure once and locates the best-guess username and
 * password AutofillIds using Android's standard autofill hints first, then
 * falling back to InputType/HTML heuristics for apps that don't set hints.
 *
 * Extracts the page's web domain when present (Chrome, Brave, Edge, etc.
 * populate `ViewNode.webDomain` on rendered page nodes). Using `webDomain`
 * instead of `packageName` prevents every website inside a single browser
 * from collapsing into one identifier.
 */
object FieldFinder {
    data class Fields(val usernameId: AutofillId?, val passwordId: AutofillId?, val appIdentifier: String)

    fun find(structure: AssistStructure): Fields {
        var usernameId: AutofillId? = null
        var passwordId: AutofillId? = null
        var webDomain: String? = null
        val packageName = structure.activityComponent?.packageName ?: ""

        structure.forEachViewNode { node ->
            android.util.Log.d("FieldFinder", "Node: idEntry=${node.idEntry}, hint=${node.hint}, hints=${node.autofillHints?.toList()}, inputType=${node.inputType}, text=${node.text}, className=${node.className}")
            
            if (webDomain == null) {
                val domain = node.webDomain
                if (!domain.isNullOrBlank()) webDomain = domain
            }

            val hints = node.autofillHints
            if (hints != null) {
                if (hints.any { it == View.AUTOFILL_HINT_USERNAME || it == View.AUTOFILL_HINT_EMAIL_ADDRESS }) {
                    usernameId = usernameId ?: node.autofillId
                }
                if (hints.any { it == View.AUTOFILL_HINT_PASSWORD || it == "newPassword" || it == "new-password" }) {
                    passwordId = passwordId ?: node.autofillId
                }
            }
            
            // Always fallback to standard heuristics if OS hints didn't catch one or both
            val isPasswordInputType = (node.inputType and android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD) != 0 ||
                (node.inputType and android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD) != 0 ||
                (node.inputType and android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD) != 0 || 
                (node.inputType == 129) || (node.inputType == 225) || (node.inputType == 18) // standard password constants
                
            val idOrHint = ((node.idEntry ?: "") + " " + (node.hint ?: "")).lowercase()
            
            if ((isPasswordInputType || idOrHint.contains("password") || idOrHint.contains("pwd")) && passwordId == null) {
                passwordId = node.autofillId
            }
            if ((idOrHint.contains("user") || idOrHint.contains("email") || idOrHint.contains("login") || idOrHint.contains("identifier")) && usernameId == null) {
                usernameId = node.autofillId
            }
        }

        android.util.Log.d("FieldFinder", "Found: usernameId=$usernameId, passwordId=$passwordId, appIdentifier=$webDomain or $packageName")
        val appIdentifier = webDomain?.removePrefix("www.") ?: packageName
        return Fields(usernameId, passwordId, appIdentifier)
    }
}

/** Recursively visits every node in an AssistStructure. */
fun AssistStructure.forEachViewNode(action: (AssistStructure.ViewNode) -> Unit) {
    for (i in 0 until windowNodeCount) {
        visit(getWindowNodeAt(i).rootViewNode, action)
    }
}

private fun visit(node: AssistStructure.ViewNode, action: (AssistStructure.ViewNode) -> Unit) {
    action(node)
    for (i in 0 until node.childCount) {
        visit(node.getChildAt(i), action)
    }
}
