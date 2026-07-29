package com.example.peervault.app

import android.app.PendingIntent
import android.app.assist.AssistStructure
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
                        // No matching entries — show "open PeerVault" prompt
                        val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
                            setTextViewText(android.R.id.text1, "No passwords found for $query")
                        }
                        val allIds = listOfNotNull(fields.usernameId, fields.passwordId).toTypedArray()
                        val mainIntent = Intent(applicationContext, MainActivity::class.java)
                        val pendingIntent = PendingIntent.getActivity(
                            applicationContext, 1002, mainIntent,
                            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                        )
                        responseBuilder.setAuthentication(allIds, pendingIntent.intentSender, presentation)
                    }
                } else {
                    // Vault is locked — show unlock prompt.
                    val authIntent = Intent(applicationContext, PeerVaultAutofillAuthActivity::class.java)
                    authIntent.putExtra(PeerVaultAutofillAuthActivity.EXTRA_QUERY, query)
                    val pendingIntent = PendingIntent.getActivity(
                        applicationContext,
                        1001,
                        authIntent,
                        PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                    )

                    val allIds = listOfNotNull(fields.usernameId, fields.passwordId).toTypedArray()

                    if (useInline && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val spec = inlineSpecs!!.first()
                        val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
                            setTextViewText(android.R.id.text1, "Unlock PeerVault")
                        }
                        val inlinePresentation = buildInlinePresentation(
                            spec, "🔒 Unlock PeerVault", "Tap to authenticate", 1001
                        )
                        val datasetBuilder = Dataset.Builder()
                        fields.usernameId?.let { datasetBuilder.setValue(it, AutofillValue.forText(""), presentation, inlinePresentation) }
                        fields.passwordId?.let { datasetBuilder.setValue(it, AutofillValue.forText(""), presentation, inlinePresentation) }
                        datasetBuilder.setAuthentication(pendingIntent.intentSender)
                        responseBuilder.addDataset(datasetBuilder.build())
                    } else {
                        val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
                            setTextViewText(android.R.id.text1, "Unlock PeerVault to autofill")
                        }
                        responseBuilder.setAuthentication(allIds, pendingIntent.intentSender, presentation)
                    }
                }

                // SaveInfo — required for Android to call onSaveRequest after form submit
                buildSaveInfo(fields)?.let { responseBuilder.setSaveInfo(it) }

                callback.onSuccess(responseBuilder.build())
            } catch (e: Exception) {
                callback.onFailure(e.message)
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
        val inlinePresentation = buildInlinePresentation(spec, websiteName, username, 2000 + index)
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
        requestCode: Int,
    ): InlinePresentation {
        // The Inline Suggestions API requires a PendingIntent even if we don't
        // need it — the OS uses it as a click target for the chip. We point it
        // at a no-op activity (main app) since the autofill value is already
        // embedded in the Dataset.
        val pendingIntent = PendingIntent.getActivity(
            applicationContext,
            requestCode,
            Intent(applicationContext, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val slice = InlineSuggestionUi.newContentBuilder(pendingIntent)
            .setTitle(title)
            .setSubtitle(subtitle)
            .setStartIcon(Icon.createWithResource(this, android.R.drawable.ic_lock_lock))
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
        return SaveInfo.Builder(saveDataTypes, requiredIds).build()
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
            if (webDomain == null) {
                val domain = node.webDomain
                if (!domain.isNullOrBlank()) webDomain = domain
            }

            val hints = node.autofillHints
            if (hints != null) {
                if (hints.any { it == View.AUTOFILL_HINT_USERNAME || it == View.AUTOFILL_HINT_EMAIL_ADDRESS }) {
                    usernameId = usernameId ?: node.autofillId
                }
                if (hints.any { it == View.AUTOFILL_HINT_PASSWORD }) {
                    passwordId = passwordId ?: node.autofillId
                }
            } else {
                val isPasswordInputType = (node.inputType and android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD) != 0 ||
                    (node.inputType and android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD) != 0 ||
                    (node.inputType and android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD) != 0
                val idOrHint = ((node.idEntry ?: "") + " " + (node.hint ?: "")).lowercase()
                if (isPasswordInputType && passwordId == null) {
                    passwordId = node.autofillId
                } else if ((idOrHint.contains("user") || idOrHint.contains("email") || idOrHint.contains("login") || idOrHint.contains("identifier")) && usernameId == null) {
                    usernameId = node.autofillId
                }
            }
        }

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
