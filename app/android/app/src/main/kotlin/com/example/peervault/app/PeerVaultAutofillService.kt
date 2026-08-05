package com.example.peervault.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.Context
import android.content.Intent
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
 *      approach causes "contents cannot be autofilled" errors in browser
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

        android.util.Log.d("PeerVault", "onFillRequest: usernameId=${fields.usernameId}, passwordId=${fields.passwordId}, app=${fields.appIdentifier}")

        if (fields.usernameId == null && fields.passwordId == null) {
            callback.onSuccess(null)
            return
        }

        serviceScope.launch {
            try {
                kotlinx.coroutines.withTimeout(4500L) {
                    val unlocked = AutofillBridge.isUnlocked(applicationContext)
                    val query = fields.appIdentifier

                    val inlineSpecs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        request.inlineSuggestionsRequest?.inlinePresentationSpecs
                    } else null
                    val useInline = inlineSpecs != null && inlineSpecs.isNotEmpty()

                    val focusedId = request.fillContexts.last().focusedId

                    if (!unlocked) {
                        // Vault is locked — return an authentication-gated dataset instead of a system notification
                        val appIntent = Intent(applicationContext, PeerVaultAutofillAuthActivity::class.java).apply {
                            putExtra("notify_only", false)
                            putExtra(PeerVaultAutofillAuthActivity.EXTRA_QUERY, query)
                            putExtra(PeerVaultAutofillAuthActivity.EXTRA_USERNAME_ID, fields.usernameId)
                            putExtra(PeerVaultAutofillAuthActivity.EXTRA_PASSWORD_ID, fields.passwordId)
                            putExtra(PeerVaultAutofillAuthActivity.EXTRA_FOCUSED_ID, focusedId)
                            if (inlineSpecs != null) {
                                putParcelableArrayListExtra("inline_specs", ArrayList(inlineSpecs))
                            }
                            addFlags(Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
                            addFlags(Intent.FLAG_ACTIVITY_NO_HISTORY)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
                        }
                        val pendingIntent = PendingIntent.getActivity(
                            applicationContext, 4001, appIntent,
                            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
                        )

                        val responseBuilder = FillResponse.Builder()
                        val autofillIds = listOfNotNull(fields.usernameId, fields.passwordId, focusedId)
                            .distinct()
                            .toTypedArray()
                        
                        val presentation = RemoteViews(packageName, com.example.peervault.R.layout.autofill_remote_view).apply {
                            setTextViewText(com.example.peervault.R.id.title, "\uD83D\uDD13 Unlock PeerVault")
                            setViewVisibility(com.example.peervault.R.id.subtitle, android.view.View.GONE) // Hide subtitle
                        }

                        val authDatasetBuilder = Dataset.Builder()
                        authDatasetBuilder.setAuthentication(pendingIntent.intentSender)

                        if (useInline && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && inlineSpecs != null) {
                            val inlinePresentation = AutofillUtils.buildInlinePresentation(applicationContext, inlineSpecs.first(), "\uD83D\uDD13 Unlock PeerVault", "")
                            inlinePresentation?.let {
                                authDatasetBuilder.setInlinePresentation(it)
                            }
                            autofillIds.forEach { id ->
                                authDatasetBuilder.setValue(id, android.view.autofill.AutofillValue.forText("PLACEHOLDER"), presentation)
                            }
                        } else {
                            autofillIds.forEach { id ->
                                authDatasetBuilder.setValue(id, android.view.autofill.AutofillValue.forText("PLACEHOLDER"), presentation)
                            }
                        }

                        responseBuilder.addDataset(authDatasetBuilder.build())
                        callback.onSuccess(responseBuilder.build())
                        return@withTimeout
                    }

                    // Vault is unlocked — search for matching entries
                    val raw = AutofillBridge.searchEntries(applicationContext, query)
                    val json = JSONObject(raw)
                    val entries = json.getJSONArray("entries")

                    val responseBuilder = FillResponse.Builder()
                    var datasetsAdded = 0

                    if (entries.length() > 0) {
                        // Vault is unlocked (user already did biometric to unlock).
                        // Return real credentials directly — tapping a chip fills immediately.
                        for (i in 0 until entries.length()) {
                            val entry = entries.getJSONObject(i)
                            val websiteName = entry.optString("websiteName", "")
                            val username = entry.optString("username", "")
                            val password = entry.optString("password", "")

                            val dataset = if (useInline && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                AutofillUtils.buildInlineDataset(
                                    applicationContext, packageName, fields, websiteName, username, password,
                                    inlineSpecs!!.first(), i, focusedId
                                )
                            } else {
                                AutofillUtils.buildDropdownDataset(packageName, fields, websiteName, username, password, focusedId)
                            }
                            responseBuilder.addDataset(dataset)
                            datasetsAdded++
                        }
                    }

                    if (entries.length() == 0 && fields.passwordId != null) {
                        // No saved credentials for this site — offer password generation
                        val suggestAdded = AutofillUtils.addSuggestPasswordDataset(
                            applicationContext, packageName, responseBuilder, fields, useInline, inlineSpecs, query.hashCode(), focusedId
                        )
                        if (suggestAdded) datasetsAdded++
                    }

                        AutofillUtils.buildSaveInfo(fields)?.let { responseBuilder.setSaveInfo(it) }

                    if (datasetsAdded > 0) {
                        android.util.Log.d("PeerVault", "Autofill onSuccess with $datasetsAdded datasets, inline=$useInline")
                        callback.onSuccess(responseBuilder.build())
                    } else {
                        android.util.Log.d("PeerVault", "Autofill onSuccess(null) — no datasets to show")
                        callback.onSuccess(null)
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("PeerVault", "Autofill OS Timeout/Error: ${e.message}", e)
                callback.onSuccess(null)
            }
        }
    }

    override fun onSaveRequest(request: android.service.autofill.SaveRequest, callback: android.service.autofill.SaveCallback) {
        val context: android.service.autofill.FillContext = request.fillContexts.last()
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
}


/**
 * Walks an AssistStructure once and locates the best-guess username and
 * password AutofillIds using a multi-layered detection strategy:
 *
 *   Layer 0 (highest confidence): HTML `autocomplete` attributes from
 *           browser webviews — `current-password`, `new-password`,
 *           `username`, `email`.
 *   Layer 1: Android autofill hints (`View.AUTOFILL_HINT_USERNAME`, etc.)
 *   Layer 2: InputType flags (`TYPE_TEXT_VARIATION_PASSWORD`, etc.)
 *   Layer 3 (lowest confidence): idEntry/hint keyword matching with
 *           tokenized word-boundary checks (not substring).
 *
 * Exclusion: known non-login contexts (chat, search, compose, etc.) are
 * filtered out using token-level matching (not substring) to avoid false
 * negatives like "research_password" being excluded by a "search" keyword.
 *
 * Structural guard: a heuristic-only username field (from layer 3) is
 * discarded if no password field was found anywhere — this prevents lone
 * text inputs in chat apps from triggering autofill. Android-hint-based
 * or HTML-attribute-based username fields are kept even without a password
 * field, because two-step login forms legitimately have username-only pages.
 *
 * Extracts the page's web domain when present (Chrome, Brave, Edge, etc.
 * populate `ViewNode.webDomain` on rendered page nodes). Using `webDomain`
 * instead of `packageName` prevents every website inside a single browser
 * from collapsing into one identifier.
 */
object FieldFinder {
    data class Fields(val usernameId: AutofillId?, val passwordId: AutofillId?, val appIdentifier: String)

    // ── Keywords ──────────────────────────────────────────────

    private val USERNAME_KEYWORDS = setOf(
        "username", "user_name", "userid", "user_id", "userlogin",
        "email", "emailaddress", "email_address",
        "login", "loginid", "login_id", "login_name",
        "account", "accountid", "account_name",
        "phone", "phonenumber", "phone_number", "mobile",
        "identifier", "credential"
    )

    private val PASSWORD_KEYWORDS = setOf(
        "password", "passwd", "pass_word", "passcode",
        "pwd", "pin", "secret", "passphrase",
        "current_password", "new_password", "confirm_password",
        "currentpassword", "newpassword", "confirmpassword"
    )

    /** HTML `autocomplete` attribute values that indicate credential fields. */
    private val HTML_USERNAME_AUTOCOMPLETE = setOf(
        "username", "email", "tel"
    )
    private val HTML_PASSWORD_AUTOCOMPLETE = setOf(
        "current-password", "new-password", "password"
    )

    /**
     * Words that indicate NON-login contexts, checked at token level.
     * "search" won't exclude "research_password" because tokenization
     * splits it into {"research", "password"}, not matching "search".
     */
    private val EXCLUDED_KEYWORDS = setOf(
        "message", "chat", "compose", "comment",
        "search", "query", "caption", "bio",
        "description", "note", "post", "reply",
        "dm", "direct", "story", "status",
        "tweet", "send", "write",
        "share", "forward", "freeform"
    )

    // ── Tokenizer ─────────────────────────────────────────────

    private fun tokenize(input: String): Set<String> {
        return input.lowercase()
            .replace(Regex("([a-z])([A-Z])"), "$1_$2") // camelCase -> snake_case
            .split(Regex("[_\\-. ]+"))
            .filter { it.isNotBlank() }
            .toSet()
    }

    private fun matchesKeywords(idEntry: String?, hint: String?, keywords: Set<String>): Boolean {
        val rawText = ((idEntry ?: "") + " " + (hint ?: "")).lowercase()
        if (rawText.isBlank()) return false
        // Check exact normalized match first (e.g. "emailAddress" -> "emailaddress")
        val normalized = rawText.replace(Regex("[^a-z0-9]"), "")
        if (keywords.any { normalized == it.replace("_", "") }) return true
        // Check token-level matching
        val tokens = tokenize(rawText)
        return keywords.any { keyword ->
            val keyTokens = tokenize(keyword)
            keyTokens.all { kt -> tokens.contains(kt) }
        }
    }

    /**
     * Token-level exclusion check. Returns true ONLY if the field's tokens
     * match an excluded keyword — substring matching is NOT used, so
     * "user_message_compose" is excluded (contains token "compose") but
     * "research_password" is NOT excluded (no token "search" — only "research").
     */
    private fun isExcludedContext(idEntry: String?, hint: String?): Boolean {
        val rawText = ((idEntry ?: "") + " " + (hint ?: "")).lowercase()
        if (rawText.isBlank()) return false
        val tokens = tokenize(rawText)
        return EXCLUDED_KEYWORDS.any { tokens.contains(it) }
    }

    // ── Main detection ────────────────────────────────────────

    fun find(structure: AssistStructure): Fields {
        var htmlUsernameId: AutofillId? = null
        var htmlPasswordId: AutofillId? = null
        var hintBasedUsernameId: AutofillId? = null
        var hintBasedPasswordId: AutofillId? = null
        var heuristicUsernameId: AutofillId? = null
        var heuristicPasswordId: AutofillId? = null
        var webDomain: String? = null
        val packageName = structure.activityComponent?.packageName ?: ""

        structure.forEachViewNode { node ->
            // Extract web domain from any node that has it
            if (webDomain == null) {
                val domain = node.webDomain
                if (!domain.isNullOrBlank()) webDomain = domain
            }

            val idEntry = node.idEntry
            val hint = node.hint

            // Skip excluded contexts to prevent triggering in chat apps
            if (isExcludedContext(idEntry, hint)) {
                android.util.Log.d("FieldFinder", "EXCLUDED: idEntry=$idEntry, hint=$hint")
                return@forEachViewNode
            }

            // ── Layer 0: HTML autocomplete attributes (highest confidence for webviews) ──
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val htmlInfo = node.htmlInfo
                if (htmlInfo != null) {
                    val attributes = htmlInfo.attributes
                    if (attributes != null) {
                        for (pair in attributes) {
                            if (pair.first.equals("autocomplete", ignoreCase = true) ||
                                pair.first.equals("type", ignoreCase = true) ||
                                pair.first.equals("name", ignoreCase = true)) {
                                val attrValue = pair.second?.lowercase() ?: continue
                                if (HTML_PASSWORD_AUTOCOMPLETE.any { attrValue.contains(it) }) {
                                    htmlPasswordId = htmlPasswordId ?: node.autofillId
                                    android.util.Log.d("FieldFinder", "HTML password: attr=${pair.first}=$attrValue")
                                }
                                if (HTML_USERNAME_AUTOCOMPLETE.any { attrValue.contains(it) }) {
                                    htmlUsernameId = htmlUsernameId ?: node.autofillId
                                    android.util.Log.d("FieldFinder", "HTML username: attr=${pair.first}=$attrValue")
                                }
                            }
                        }
                    }
                }
            }

            // ── Layer 1: Android autofill hints (high confidence) ──
            val hints = node.autofillHints
            if (hints != null) {
                if (hints.any { it == View.AUTOFILL_HINT_USERNAME || it == View.AUTOFILL_HINT_EMAIL_ADDRESS }) {
                    hintBasedUsernameId = hintBasedUsernameId ?: node.autofillId
                }
                if (hints.any { it == View.AUTOFILL_HINT_PASSWORD || it == "newPassword" || it == "new-password" }) {
                    hintBasedPasswordId = hintBasedPasswordId ?: node.autofillId
                }
            }

            // ── Layer 2: InputType flags (medium confidence for password) ──
            val inputType = node.inputType
            val isPasswordInputType = (inputType and android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD) != 0 ||
                (inputType and android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD) != 0 ||
                (inputType and android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD) != 0 ||
                (inputType == (android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD)) ||
                (inputType == (android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD))

            if (isPasswordInputType && heuristicPasswordId == null) {
                heuristicPasswordId = node.autofillId
                android.util.Log.d("FieldFinder", "InputType password: inputType=$inputType, id=$idEntry")
            }

            // ── Layer 3: Keyword matching (lowest confidence, strict word-boundary) ──
            if (matchesKeywords(idEntry, hint, PASSWORD_KEYWORDS) && heuristicPasswordId == null) {
                heuristicPasswordId = node.autofillId
            }
            if (matchesKeywords(idEntry, hint, USERNAME_KEYWORDS) && heuristicUsernameId == null) {
                heuristicUsernameId = node.autofillId
            }
        }

        // Resolution: prefer HTML-based > hint-based > heuristic
        val usernameId = htmlUsernameId ?: hintBasedUsernameId ?: heuristicUsernameId
        val passwordId = htmlPasswordId ?: hintBasedPasswordId ?: heuristicPasswordId

        // STRUCTURAL GUARD: If we only found a "username" field from heuristics
        // (layer 3) but NO password field from ANY layer, this is very likely
        // NOT a login form (e.g. a lone text field in a chat app). Discard it.
        // Exception: HTML-attribute-based and Android-hint-based username fields
        // are kept, because 2-step login forms legitimately have username-only pages.
        val finalUsernameId = if (passwordId == null && usernameId != null &&
            htmlUsernameId == null && hintBasedUsernameId == null) {
            android.util.Log.d("FieldFinder", "Discarding heuristic-only username (no password field found)")
            null
        } else {
            usernameId
        }

        val appIdentifier = webDomain?.removePrefix("www.") ?: packageName
        android.util.Log.d("FieldFinder", "Result: username=$finalUsernameId, password=$passwordId, app=$appIdentifier")
        return Fields(finalUsernameId, passwordId, appIdentifier)
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
