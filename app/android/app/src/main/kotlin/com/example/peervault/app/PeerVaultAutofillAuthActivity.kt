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
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val query = intent.getStringExtra(EXTRA_QUERY) ?: ""
        val structure = intent.getParcelableExtra<android.app.assist.AssistStructure>(AutofillManager.EXTRA_ASSIST_STRUCTURE)
        val fields = structure?.let { FieldFinder.find(it) }

        val executor = ContextCompat.getMainExecutor(this)
        val prompt = BiometricPrompt(
            this,
            executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    scope.launch { completeAfterAuth(query, fields) }
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

    private suspend fun completeAfterAuth(query: String, fields: FieldFinder.Fields?) {
        val unlocked = AutofillBridge.unlockVault(applicationContext)
        if (!unlocked || fields == null) {
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

        // Simplest correct behaviour: return the first match. A fuller
        // implementation would show an in-activity picker when there are
        // multiple accounts for the same site (the architecture doc calls
        // this out explicitly — every account has its own UUID).
        val entry = entries.getJSONObject(0)
        val builder = Dataset.Builder()
        val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_2).apply {
            setTextViewText(android.R.id.text1, entry.getString("websiteName"))
            setTextViewText(android.R.id.text2, entry.getString("username"))
        }
        fields.usernameId?.let { builder.setValue(it, AutofillValue.forText(entry.getString("username")), presentation) }
        fields.passwordId?.let { builder.setValue(it, AutofillValue.forText(entry.getString("password")), presentation) }

        val resultIntent = Intent()
        resultIntent.putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, builder.build())
        setResult(RESULT_OK, resultIntent)
        finish()
    }
}
