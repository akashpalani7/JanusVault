package com.example.peervault.app

import android.content.Intent
import android.os.Bundle
import android.service.autofill.Dataset
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Transparent activity the OS launches when the user taps a locked
 * "Unlock PeerVault to autofill" suggestion or an authentication-gated
 * inline chip. Runs an androidx.biometric.BiometricPrompt to verify the
 * user's identity, then searches the vault for matching entries and returns
 * the real Dataset (with actual passwords) as the activity result per the
 * Autofill Framework's authentication contract.
 *
 * Called in TWO scenarios:
 *   1. notify_only=true — vault was locked, user tapped notification → unlock
 *   2. notify_only=false — vault is unlocked but user must biometric-verify
 *      before credentials are pasted (auth gating)
 */
class PeerVaultAutofillAuthActivity : FragmentActivity() {

    private val scope = MainScope()

    companion object {
        const val EXTRA_QUERY = "peervault.extra.query"
        const val EXTRA_USERNAME_ID = "peervault.extra.username_id"
        const val EXTRA_PASSWORD_ID = "peervault.extra.password_id"
        const val EXTRA_FOCUSED_ID = "peervault.extra.focused_id"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val query = intent.getStringExtra(EXTRA_QUERY) ?: ""
        val usernameId = intent.getParcelableExtra<android.view.autofill.AutofillId>(EXTRA_USERNAME_ID)
        val passwordId = intent.getParcelableExtra<android.view.autofill.AutofillId>(EXTRA_PASSWORD_ID)
        val focusedId = intent.getParcelableExtra<android.view.autofill.AutofillId>(EXTRA_FOCUSED_ID)

        val executor = ContextCompat.getMainExecutor(this)
        val prompt = BiometricPrompt(
            this,
            executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    scope.launch { completeAfterAuth(query, usernameId, passwordId, focusedId) }
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    setResult(RESULT_CANCELED)
                    finish()
                }

                override fun onAuthenticationFailed() {
                    // Let the prompt retry rather than closing immediately.
                }
            },
        )

        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Unlock PeerVault")
            .setSubtitle("Authenticate to autofill your saved password")
            .setAllowedAuthenticators(
                androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
            .build()

        prompt.authenticate(promptInfo)
    }

    private suspend fun completeAfterAuth(
        query: String,
        usernameId: android.view.autofill.AutofillId?,
        passwordId: android.view.autofill.AutofillId?,
        focusedId: android.view.autofill.AutofillId?
    ) {
        // Dismiss the "PeerVault is Locked" notification if it's still visible
        val notifManager = getSystemService(android.content.Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        notifManager.cancel(4001)

        // If vault is still locked, unlock it now (biometric was already verified)
        if (!AutofillBridge.isUnlocked(applicationContext)) {
            val unlocked = AutofillBridge.unlockVault(applicationContext)
            if (!unlocked) {
                setResult(RESULT_CANCELED)
                finish()
                return
            }
        }

        // If this was a notify-only unlock (vault was locked, no autofill fields),
        // just close — the user needs to re-tap the field to trigger a new onFillRequest
        if (intent.getBooleanExtra("notify_only", false)) {
            finish()
            return
        }

        if (usernameId == null && passwordId == null) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }

        val raw = AutofillBridge.searchEntries(applicationContext, query)
        val json = JSONObject(raw)
        val entries = json.getJSONArray("entries")
        val inlineSpecs = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            intent.getParcelableArrayListExtra<android.widget.inline.InlinePresentationSpec>("inline_specs")
        } else null
        val useInline = inlineSpecs != null && inlineSpecs.isNotEmpty()

        // ── CRITICAL FIX ──────────────────────────────────────────────
        // The autofill service sets authentication on the DATASET level
        // (authDatasetBuilder.setAuthentication()), NOT the FillResponse
        // level. Per Android docs, dataset-level auth activities MUST
        // return a single Dataset via EXTRA_AUTHENTICATION_RESULT.
        // Returning a FillResponse here causes Android to silently
        // discard it → password never fills.
        // ───────────────────────────────────────────────────────────────

        // Find the first matching credential with a non-blank password
        var matchEntry: JSONObject? = null
        for (i in 0 until entries.length()) {
            val entry = entries.getJSONObject(i)
            if (entry.optString("password", "").isNotBlank()) {
                matchEntry = entry
                break
            }
        }

        if (matchEntry == null) {
            android.util.Log.w("PeerVault", "Auth: no matching entry with password found")
            setResult(RESULT_CANCELED)
            finish()
            return
        }

        val websiteName = matchEntry.optString("websiteName", "")
        val websiteUrl = matchEntry.optString("websiteUrl", "")
        val title = if (websiteName.isNotBlank()) websiteName else if (websiteUrl.isNotBlank()) websiteUrl else "PeerVault Account"
        val username = matchEntry.optString("username", "")
        val password = matchEntry.optString("password", "")

        val tempFields = FieldFinder.Fields(usernameId, passwordId, "")

        // Build a single Dataset (NOT a FillResponse) with real credentials
        val dataset = if (useInline && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            AutofillUtils.buildInlineDataset(
                applicationContext, packageName, tempFields, title, username, password,
                inlineSpecs!!.first(), 0, focusedId
            )
        } else {
            AutofillUtils.buildDropdownDataset(packageName, tempFields, title, username, password, focusedId)
        }

        val resultIntent = Intent()
        resultIntent.putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset)

        android.util.Log.d("PeerVault", "Auth: returning Dataset for '$title' (user=$username)")
        setResult(RESULT_OK, resultIntent)
        finish()
    }

}
