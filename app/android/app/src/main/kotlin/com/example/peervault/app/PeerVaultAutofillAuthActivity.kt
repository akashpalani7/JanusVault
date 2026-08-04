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
 * "Unlock PeerVault to autofill" suggestion (see setAuthentication in
 * PeerVaultAutofillService). Runs an androidx.biometric.BiometricPrompt
 * HERE — this is a real Activity, unlike the headless background engine,
 * so it's the correct place for biometric UI to live. On success, it asks
 * Dart to unwrap the VEK and fetch matching entries, builds the real
 * Dataset, and returns it as the activity result per the Autofill
 * Framework's authentication contract.
 */
class PeerVaultAutofillAuthActivity : FragmentActivity() {

    private val scope = MainScope()

    companion object {
        const val EXTRA_QUERY = "peervault.extra.query"
        const val EXTRA_USERNAME_ID = "peervault.extra.username_id"
        const val EXTRA_PASSWORD_ID = "peervault.extra.password_id"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val query = intent.getStringExtra(EXTRA_QUERY) ?: ""
        val usernameId = intent.getParcelableExtra<android.view.autofill.AutofillId>(EXTRA_USERNAME_ID)
        val passwordId = intent.getParcelableExtra<android.view.autofill.AutofillId>(EXTRA_PASSWORD_ID)

        val executor = ContextCompat.getMainExecutor(this)
        val prompt = BiometricPrompt(
            this,
            executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    scope.launch { completeAfterAuth(query, usernameId, passwordId) }
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

    private suspend fun completeAfterAuth(query: String, usernameId: android.view.autofill.AutofillId?, passwordId: android.view.autofill.AutofillId?) {
        val manager = getSystemService(android.content.Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        manager.cancel(4001)

        val unlocked = AutofillBridge.unlockVault(applicationContext)
        
        if (intent.getBooleanExtra("notify_only", false)) {
            finish()
            return
        }

        if (!unlocked || (usernameId == null && passwordId == null)) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }

        val raw = AutofillBridge.searchEntries(applicationContext, query)
        val json = JSONObject(raw)
        val entries = json.getJSONArray("entries")
        if (entries.length() == 0) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }

        val responseBuilder = android.service.autofill.FillResponse.Builder()
        val inlineSpecs = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            intent.getParcelableArrayListExtra<android.widget.inline.InlinePresentationSpec>("inline_specs")
        } else null
        val useInline = android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R && !inlineSpecs.isNullOrEmpty()
        
        for (i in 0 until entries.length()) {
            val entry = entries.getJSONObject(i)
            val builder = Dataset.Builder()
            
            val websiteName = entry.optString("websiteName", "")
            val websiteUrl = entry.optString("websiteUrl", "")
            val title = if (websiteName.isNotBlank()) websiteName else if (websiteUrl.isNotBlank()) websiteUrl else "PeerVault Account"
            val username = entry.optString("username", "")
            val password = entry.optString("password", "")
            
            if (password.isBlank()) continue
            
            val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_2).apply {
                setTextViewText(android.R.id.text1, title)
                setTextViewText(android.R.id.text2, username)
            }
            
            if (useInline && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                // Determine the correct spec index to use
                val spec = inlineSpecs!![minOf(i, inlineSpecs.size - 1)]
                val dummyIntent = android.app.PendingIntent.getActivity(
                    applicationContext, 
                    3000 + i, 
                    Intent(), 
                    android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT
                )
                val inlinePresentation = buildInlinePresentation(spec, title, username, dummyIntent)
                
                usernameId?.let { builder.setValue(it, AutofillValue.forText(username), presentation, inlinePresentation) }
                passwordId?.let { builder.setValue(it, AutofillValue.forText(password), presentation, inlinePresentation) }
            } else {
                usernameId?.let { builder.setValue(it, AutofillValue.forText(username), presentation) }
                passwordId?.let { builder.setValue(it, AutofillValue.forText(password), presentation) }
            }
            responseBuilder.addDataset(builder.build())
        }

        val resultIntent = Intent()
        resultIntent.putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, responseBuilder.build())
        setResult(RESULT_OK, resultIntent)
        finish()
    }

    @androidx.annotation.RequiresApi(android.os.Build.VERSION_CODES.R)
    private fun buildInlinePresentation(
        spec: android.widget.inline.InlinePresentationSpec,
        title: String,
        subtitle: String,
        pendingIntent: android.app.PendingIntent,
    ): android.service.autofill.InlinePresentation {
        val slice = androidx.autofill.inline.v1.InlineSuggestionUi.newContentBuilder(pendingIntent)
            .setTitle(if (subtitle.isNotEmpty()) "$title | $subtitle" else title)
            .build()
            .slice

        return android.service.autofill.InlinePresentation(slice, spec, /* pinned= */ false)
    }
}
