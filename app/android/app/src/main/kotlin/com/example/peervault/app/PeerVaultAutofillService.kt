package com.example.peervault.app

import android.app.assist.AssistStructure
import android.content.Intent
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.Dataset
import android.service.autofill.FillCallback
import android.service.autofill.FillContext
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveInfo
import android.service.autofill.SaveRequest
import android.view.View
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * PeerVault's Android Autofill Framework entry point. This is the "mandatory
 * OS shim" mentioned in the README — it contains NO vault logic itself. It:
 *   1. Walks the AssistStructure to find username/password fields, using
 *      the page's web domain (not the browser's own package name) as the
 *      identifier whenever the structure came from a browser tab.
 *   2. Asks AutofillBridge (-> Dart) for matching vault entries.
 *   3. If the vault is unlocked in-process, returns real Datasets.
 *      If locked, returns a Dataset gated behind biometric auth
 *      (PeerVaultAutofillAuthActivity), which is the standard, OS-blessed
 *      pattern for "unlock to reveal autofill value".
 *   4. Declares SaveInfo on every response so Android actually calls
 *      onSaveRequest after a form submission — without this, "Save to
 *      PeerVault?" can never appear, on any app or in any browser,
 *      regardless of anything else being correct.
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

                if (unlocked) {
                    val raw = AutofillBridge.searchEntries(applicationContext, query)
                    val json = JSONObject(raw)
                    val entries = json.getJSONArray("entries")
                    for (i in 0 until entries.length()) {
                        val entry = entries.getJSONObject(i)
                        responseBuilder.addDataset(buildDataset(fields, entry.getString("websiteName"), entry.getString("username"), entry.getString("password")))
                    }
                } else {
                    // Locked: single "Unlock PeerVault" suggestion. Tapping it
                    // launches PeerVaultAutofillAuthActivity, which performs
                    // biometric auth and returns the real Dataset via
                    // setAuthentication's activity-result contract.
                    val authIntent = Intent(applicationContext, PeerVaultAutofillAuthActivity::class.java)
                    authIntent.putExtra(PeerVaultAutofillAuthActivity.EXTRA_QUERY, query)
                    val pendingIntent = android.app.PendingIntent.getActivity(
                        applicationContext,
                        1001,
                        authIntent,
                        android.app.PendingIntent.FLAG_MUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT,
                    )
                    val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
                        setTextViewText(android.R.id.text1, "Unlock PeerVault to autofill")
                    }
                    val allIds = listOfNotNull(fields.usernameId, fields.passwordId).toTypedArray()
                    responseBuilder.setAuthentication(allIds, pendingIntent.intentSender, presentation)
                }

                // Without this, Android has no idea this response corresponds
                // to a saveable login form, and onSaveRequest below is simply
                // never invoked — regardless of whether the user actually
                // typed a new/changed password. This was previously missing
                // entirely, on both the unlocked AND locked branches.
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
                    // Vault is locked — we cannot safely encrypt without the
                    // VEK. Real UX: prompt via a small unlock activity before
                    // saving; omitted here for brevity but follows the exact
                    // same pattern as PeerVaultAutofillAuthActivity above.
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

    /** Declares which fields, if changed/filled by the user, should trigger
     * Android's "Save to PeerVault?" bar via onSaveRequest above. Requires
     * at least a password field to be worth saving. */
    private fun buildSaveInfo(fields: FieldFinder.Fields): SaveInfo? {
        val passwordId = fields.passwordId ?: return null
        val saveDataTypes = SaveInfo.SAVE_DATA_TYPE_PASSWORD or
            (if (fields.usernameId != null) SaveInfo.SAVE_DATA_TYPE_USERNAME else 0)
        val requiredIds = listOfNotNull(fields.usernameId, passwordId).toTypedArray()
        return SaveInfo.Builder(saveDataTypes, requiredIds).build()
    }

    private fun buildDataset(fields: FieldFinder.Fields, websiteName: String, username: String, password: String): Dataset {
        val builder = Dataset.Builder()
        val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_2).apply {
            setTextViewText(android.R.id.text1, websiteName)
            setTextViewText(android.R.id.text2, username)
        }
        fields.usernameId?.let { builder.setValue(it, AutofillValue.forText(username), presentation) }
        fields.passwordId?.let { builder.setValue(it, AutofillValue.forText(password), presentation) }
        return builder.build()
    }
}

/**
 * Walks an AssistStructure once and locates the best-guess username and
 * password AutofillIds using Android's standard autofill hints first, then
 * falling back to InputType/HTML heuristics for apps that don't set hints.
 *
 * Also extracts the page's web domain when the structure came from a
 * browser tab (Chrome, Brave, and other Chromium-based browsers populate
 * `ViewNode.webDomain` on the relevant nodes of the rendered page). This
 * matters a great deal: a single browser process hosts every website the
 * user visits under ONE Android package name (e.g. "com.brave.browser"),
 * so using `activityComponent.packageName` as the identifier — which the
 * previous version of this file did — means every single site inside that
 * browser collapses into the same identifier and can never match a
 * specific saved entry by domain. Using `webDomain` when present fixes
 * this for Brave, Chrome, Edge, Firefox (in WebView-compat mode), etc.
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
                // Heuristic fallback: text field with password InputType, or
                // id/hint text containing "user"/"email"/"pass".
                val isPasswordInputType = (node.inputType and android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD) != 0 ||
                    (node.inputType and android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD) != 0
                val idOrHint = ((node.idEntry ?: "") + " " + (node.hint ?: "")).lowercase()
                if (isPasswordInputType && passwordId == null) {
                    passwordId = node.autofillId
                } else if ((idOrHint.contains("user") || idOrHint.contains("email") || idOrHint.contains("login")) && usernameId == null) {
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
