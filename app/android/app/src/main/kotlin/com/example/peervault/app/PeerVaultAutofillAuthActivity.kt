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
        
        window.setLayout(
            android.view.ViewGroup.LayoutParams.MATCH_PARENT,
            android.view.ViewGroup.LayoutParams.MATCH_PARENT
        )

        // Ensure there is an actual view hierarchy that Android 11 can apply MATCH_PARENT to instantly
        val rootFrame = android.widget.FrameLayout(this)
        setContentView(rootFrame)

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

        if (intent.getBooleanExtra("save_request", false)) {
            val appIdentifier = intent.getStringExtra(EXTRA_QUERY) ?: ""
            val username = intent.getStringExtra("save_username") ?: ""
            val password = intent.getStringExtra("save_password") ?: ""
            val titleCasedName = appIdentifier.replaceFirstChar { if (it.isLowerCase()) it.titlecase(java.util.Locale.getDefault()) else it.toString() }
            AutofillBridge.saveCapturedCredential(applicationContext, titleCasedName, appIdentifier, username, password)
            android.widget.Toast.makeText(applicationContext, "Saved to PeerVault!", android.widget.Toast.LENGTH_SHORT).show()
            
            val resultIntent = Intent()
            setResult(RESULT_OK, resultIntent)
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
        
        val v1Spec = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R && inlineSpecs != null) {
            inlineSpecs.firstOrNull { spec ->
                androidx.autofill.inline.UiVersions.getVersions(spec.style).contains(androidx.autofill.inline.UiVersions.INLINE_UI_VERSION_1)
            }
        } else null
        
        val useInline = v1Spec != null

        // ── DATASET-LEVEL AUTH ────────────────────────────────────
        // Because response-level auth breaks inline chips on Android,
        // we use dataset-level auth for "Unlock Vault". The Android
        // framework requires that dataset-level auth activities return
        // a SINGLE Dataset via EXTRA_AUTHENTICATION_RESULT.
        // ───────────────────────────────────────────────────────────────

        val validEntries = mutableListOf<JSONObject>()
        for (i in 0 until entries.length()) {
            val entry = entries.getJSONObject(i)
            if (entry.optString("password", "").isNotBlank()) {
                validEntries.add(entry)
            }
        }

        val tempFields = FieldFinder.Fields(usernameId, passwordId, "")

        if (validEntries.isEmpty()) {
            android.util.Log.w("PeerVault", "Auth: no matching entry with password found, returning Generate Password dataset")
            
            val suggestPresentation = android.widget.RemoteViews(packageName, com.example.peervault.R.layout.autofill_remote_view).apply {
                setTextViewText(com.example.peervault.R.id.title, "\uD83D\uDD12 Generate strong password")
                setTextViewText(com.example.peervault.R.id.subtitle, "PeerVault Generator")
            }

            val genIntent = Intent(applicationContext, PeerVaultAutofillGeneratorActivity::class.java).apply {
                putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_QUERY, query)
                putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_USERNAME, intent.getStringExtra(PeerVaultAutofillGeneratorActivity.EXTRA_USERNAME) ?: "")
                putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_USERNAME_ID, usernameId)
                putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_PASSWORD_ID, passwordId)
                putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_FOCUSED_ID, focusedId)
                if (inlineSpecs != null) {
                    putParcelableArrayListExtra("inline_specs", ArrayList(inlineSpecs.toList()))
                }
                addFlags(Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
                addFlags(Intent.FLAG_ACTIVITY_NO_HISTORY)
                addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
            }
            
            val mutabilityFlag = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                android.app.PendingIntent.FLAG_MUTABLE
            } else {
                android.app.PendingIntent.FLAG_UPDATE_CURRENT
            }
            
            val genPendingIntent = android.app.PendingIntent.getActivity(
                applicationContext, java.util.UUID.randomUUID().hashCode(), genIntent,
                android.app.PendingIntent.FLAG_CANCEL_CURRENT or mutabilityFlag
            )

            val builder = android.service.autofill.Dataset.Builder().setId(java.util.UUID.randomUUID().toString())
            builder.setAuthentication(genPendingIntent.intentSender)

            val inlinePresentation = if (useInline && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                AutofillUtils.buildInlinePresentation(applicationContext, v1Spec!!, "\uD83D\uDD12 Generate password", "")
            } else null

            if (inlinePresentation != null && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                builder.setInlinePresentation(inlinePresentation)
            }

            val autofillIds = listOfNotNull(tempFields.usernameId, tempFields.passwordId, focusedId)
                .distinct()
                .toTypedArray()

            if (android.os.Build.VERSION.SDK_INT >= 33) {
                val presentationBuilder = android.service.autofill.Presentations.Builder()
                    .setMenuPresentation(suggestPresentation)
                inlinePresentation?.let { presentationBuilder.setInlinePresentation(it) }
                val fieldPresentations = presentationBuilder.build()
                
                autofillIds.forEach { id ->
                    val fb = android.service.autofill.Field.Builder()
                        .setValue(android.view.autofill.AutofillValue.forText("PLACEHOLDER"))
                        .setPresentations(fieldPresentations)
                    builder.setField(id, fb.build())
                }
            } else {
                autofillIds.forEach { id ->
                    builder.setValue(id, android.view.autofill.AutofillValue.forText("PLACEHOLDER"), suggestPresentation)
                }
            }

            val resultIntent = Intent()
            resultIntent.putExtra(android.view.autofill.AutofillManager.EXTRA_AUTHENTICATION_RESULT, builder.build())
            setResult(RESULT_OK, resultIntent)
            finish()
            return
        }

        fun returnDatasetForEntry(entry: JSONObject) {
            val websiteName = entry.optString("websiteName", "")
            val websiteUrl = entry.optString("websiteUrl", "")
            val title = if (websiteName.isNotBlank()) websiteName else if (websiteUrl.isNotBlank()) websiteUrl else "PeerVault Account"
            val username = entry.optString("username", "")
            val password = entry.optString("password", "")

            val dataset = if (useInline && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                AutofillUtils.buildInlineDataset(
                    applicationContext, packageName, tempFields, title, username, password,
                    v1Spec!!, 0, focusedId
                )
            } else {
                AutofillUtils.buildDropdownDataset(packageName, tempFields, title, username, password, focusedId)
            }

            val resultIntent = Intent()
            resultIntent.putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset)
            android.util.Log.d("PeerVault", "Auth: returning single Dataset for '$title' (user=$username)")
            setResult(RESULT_OK, resultIntent)
            finish()
        }

        // ── MULTI-ACCOUNT UI ──────────────────────────────────────────
        // There are multiple matching accounts, OR we still want to show the UI
        // so the user has the option to Generate a new password.
        val dp = { v: Int -> (v * resources.displayMetrics.density).toInt() }

        val root = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(dp(24), dp(72), dp(24), dp(24))
            setBackgroundColor(0xFF1E1E2E.toInt())
        }

        val topBranding = android.widget.TextView(this).apply {
            text = "🛡️ PeerVault"
            textSize = 14f
            setTextColor(0xFF8888AA.toInt())
            gravity = android.view.Gravity.CENTER
            setPadding(0, 0, 0, dp(16))
        }
        root.addView(topBranding)

        val titleTv = android.widget.TextView(this).apply {
            text = "Select Account"
            textSize = 22f
            setTextColor(0xFFFFFFFF.toInt())
            gravity = android.view.Gravity.CENTER
            setPadding(0, 0, 0, dp(16))
        }
        root.addView(titleTv)

        validEntries.forEach { entry ->
            val username = entry.optString("username", "")
            val accTitle = entry.optString("websiteName", "")
            val displayLabel = if (username.isNotBlank()) username else accTitle.ifBlank { "Saved Account" }

            val btn = android.widget.Button(this).apply {
                text = "👤 $displayLabel"
                textSize = 16f
                setTextColor(0xFFFFFFFF.toInt())
                setBackgroundColor(0xFF3A3A5E.toInt())
                setPadding(dp(16), dp(16), dp(16), dp(16))
                layoutParams = android.widget.LinearLayout.LayoutParams(
                    android.widget.LinearLayout.LayoutParams.MATCH_PARENT,
                    android.widget.LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    setMargins(0, 0, 0, dp(12))
                }
            }
            btn.setOnClickListener {
                btn.isEnabled = false
                returnDatasetForEntry(entry)
            }
            root.addView(btn)
        }

        val generateBtn = android.widget.Button(this).apply {
            text = "➕ Generate New Password"
            textSize = 16f
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0xFF2A2A3E.toInt())
            setPadding(dp(16), dp(16), dp(16), dp(16))
            layoutParams = android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.MATCH_PARENT,
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                setMargins(0, dp(12), 0, dp(12))
            }
        }
        generateBtn.setOnClickListener {
            val genIntent = Intent(applicationContext, PeerVaultAutofillGeneratorActivity::class.java).apply {
                putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_QUERY, query)
                putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_USERNAME, intent.getStringExtra(PeerVaultAutofillGeneratorActivity.EXTRA_USERNAME) ?: "")
                putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_USERNAME_ID, usernameId)
                putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_PASSWORD_ID, passwordId)
                putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_FOCUSED_ID, focusedId)
                if (inlineSpecs != null) {
                    putParcelableArrayListExtra("inline_specs", ArrayList(inlineSpecs.toList()))
                }
            }
            startActivityForResult(genIntent, 999)
        }
        root.addView(generateBtn)

        val cancelBtn = android.widget.Button(this).apply {
            text = "Cancel"
            setTextColor(0xFFAAAAAA.toInt())
            setBackgroundColor(android.graphics.Color.TRANSPARENT)
            setPadding(dp(24), dp(8), dp(24), dp(8))
            layoutParams = android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.MATCH_PARENT, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, dp(16), 0, 0) }
        }
        cancelBtn.setOnClickListener {
            setResult(RESULT_CANCELED)
            finish()
        }
        root.addView(cancelBtn)

        val scrollView = android.widget.ScrollView(this).apply {
            setBackgroundColor(0xFF1E1E2E.toInt())
            addView(root)
        }
        
        // Append to the root frame created in onCreate to prevent bounds cropping
        val rootFrame = findViewById<android.widget.FrameLayout>(android.R.id.content).getChildAt(0) as? android.widget.FrameLayout
        if (rootFrame != null) {
            rootFrame.addView(scrollView)
        } else {
            setContentView(scrollView)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 999) {
            if (resultCode == RESULT_OK) {
                // Pass the dataset from Generator directly to OS
                setResult(RESULT_OK, data)
                finish()
            }
            // If cancelled, stay on the selection screen.
        }
    }

}
