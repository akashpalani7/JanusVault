package com.example.peervault.app

import android.content.Intent
import android.os.Bundle
import android.service.autofill.Dataset
import android.view.Gravity
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.*
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch

/**
 * Native Kotlin activity that opens when the "Generate password" autofill
 * chip is tapped. Shows a minimal UI with:
 *   - Website name (pre-filled, read-only)
 *   - Password length slider (8–64, default 20)
 *   - Generated password preview
 *   - "Save & Fill" button
 *
 * After the user taps "Save & Fill", the activity:
 *   1. Saves the new entry to the vault via AutofillBridge
 *   2. Returns a Dataset with the generated password → Android fills the field
 *
 * Uses a native AlertDialog-style layout (no Flutter engine startup cost).
 */
class PeerVaultAutofillGeneratorActivity : FragmentActivity() {

    private val scope = MainScope()

    companion object {
        const val EXTRA_QUERY = "peervault.gen.query"
        const val EXTRA_USERNAME = "peervault.gen.username"
        const val EXTRA_PASSWORD = "peervault.gen.password"
        const val EXTRA_USERNAME_ID = "peervault.gen.username_id"
        const val EXTRA_PASSWORD_ID = "peervault.gen.password_id"
        const val EXTRA_FOCUSED_ID = "peervault.gen.focused_id"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val query = intent.getStringExtra(EXTRA_QUERY) ?: ""
        val isSaveRequest = intent.getBooleanExtra("is_save_request", false)
        val usernameId = intent.getParcelableExtra<android.view.autofill.AutofillId>(EXTRA_USERNAME_ID)
        val passwordId = intent.getParcelableExtra<android.view.autofill.AutofillId>(EXTRA_PASSWORD_ID)
        val focusedId = intent.getParcelableExtra<android.view.autofill.AutofillId>(EXTRA_FOCUSED_ID)
        val inlineSpecs = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            intent.getParcelableArrayListExtra<android.widget.inline.InlinePresentationSpec>("inline_specs")
        } else null

        // ── Build the UI programmatically (no XML needed) ───────────

        val dp = { v: Int -> (v * resources.displayMetrics.density).toInt() }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(32), dp(24), dp(24))
            setBackgroundColor(0xFF1E1E2E.toInt())
        }

        // Title
        val titleTv = TextView(this).apply {
            text = if (isSaveRequest) "💾 Save Password" else "🔑 Generate Password"
            textSize = 22f
            setTextColor(0xFFFFFFFF.toInt())
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(8))
        }
        root.addView(titleTv)

        // Account Name
        val nameEt = EditText(this).apply {
            hint = "Account Name"
            setHintTextColor(0xFF666688.toInt())
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0xFF2A2A3E.toInt())
            setPadding(dp(12), dp(12), dp(12), dp(12))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, dp(4), 0, dp(8)) }
            isSingleLine = true
            
            // Auto-format "instagram.com" -> "Instagram"
            val defaultName = query.substringBeforeLast('.').replaceFirstChar { 
                if (it.isLowerCase()) it.titlecase(java.util.Locale.getDefault()) else it.toString() 
            }
            setText(defaultName.ifEmpty { "Saved Account" })
        }
        root.addView(nameEt)

        // Website label
        val websiteEt = EditText(this).apply {
            hint = "Website URL / App package"
            setHintTextColor(0xFF666688.toInt())
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0xFF2A2A3E.toInt())
            setPadding(dp(12), dp(12), dp(12), dp(12))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, dp(4), 0, dp(8)) }
            isSingleLine = true
            setText(query) // Automatically fill with autofetched domain
        }
        root.addView(websiteEt)

        // Username input
        val usernameEt = EditText(this).apply {
            hint = "Username / Email"
            setHintTextColor(0xFF666688.toInt())
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0xFF2A2A3E.toInt())
            setPadding(dp(12), dp(12), dp(12), dp(12))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, dp(4), 0, dp(20)) }
            isSingleLine = true
            
            val initialUsername = intent.getStringExtra(EXTRA_USERNAME) ?: ""
            if (initialUsername.isNotEmpty()) {
                setText(initialUsername)
            }
        }
        root.addView(usernameEt)

        // Password preview / input
        val passwordPreview = EditText(this).apply {
            if (isSaveRequest) hint = "Password"
            textSize = 16f
            setTextColor(0xFF00E676.toInt())
            gravity = Gravity.CENTER
            setPadding(dp(12), dp(12), dp(12), dp(12))
            setBackgroundColor(0xFF2A2A3E.toInt())
            setTypeface(android.graphics.Typeface.MONOSPACE)
            isSingleLine = false
            maxLines = 3
        }
        root.addView(passwordPreview)

        // Spacer
        root.addView(android.view.View(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(16))
        })

        // Length label
        val lengthLabel = TextView(this).apply {
            text = "Length: 20"
            textSize = 14f
            setTextColor(0xFFCCCCEE.toInt())
        }
        root.addView(lengthLabel)

        // Length slider (8–64)
        val slider = SeekBar(this).apply {
            max = 56  // 64 - 8 = 56 range
            progress = 12  // default = 8 + 12 = 20
            setPadding(0, dp(4), 0, dp(16))
        }
        root.addView(slider)

        // Character set toggles
        val toggleRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(20))
        }

        val cbUpper = CheckBox(this).apply { text = "A-Z"; isChecked = true; setTextColor(0xFFCCCCEE.toInt()) }
        val cbLower = CheckBox(this).apply { text = "a-z"; isChecked = true; setTextColor(0xFFCCCCEE.toInt()) }
        val cbDigits = CheckBox(this).apply { text = "0-9"; isChecked = true; setTextColor(0xFFCCCCEE.toInt()) }
        val cbSymbols = CheckBox(this).apply { text = "!@#"; isChecked = true; setTextColor(0xFFCCCCEE.toInt()) }

        toggleRow.addView(cbUpper)
        toggleRow.addView(cbLower)
        toggleRow.addView(cbDigits)
        toggleRow.addView(cbSymbols)
        root.addView(toggleRow)

        // Generate function
        fun generatePassword(): String {
            val length = slider.progress + 8
            var chars = ""
            if (cbUpper.isChecked) chars += "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            if (cbLower.isChecked) chars += "abcdefghijklmnopqrstuvwxyz"
            if (cbDigits.isChecked) chars += "0123456789"
            if (cbSymbols.isChecked) chars += "!@#\$%^&*()-_=+[]{};<>?"
            if (chars.isEmpty()) chars = "abcdefghijklmnopqrstuvwxyz0123456789"
            val random = java.security.SecureRandom()
            return (1..length).map { chars[random.nextInt(chars.length)] }.joinToString("")
        }

        // Initial generation
        if (isSaveRequest) {
            passwordPreview.setText(intent.getStringExtra(EXTRA_PASSWORD) ?: "")
        } else {
            passwordPreview.setText(generatePassword())
        }

        // Regenerate on slider change
        slider.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                lengthLabel.text = "Length: ${progress + 8}"
                passwordPreview.setText(generatePassword())
            }
            override fun onStartTrackingTouch(seekBar: SeekBar?) {}
            override fun onStopTrackingTouch(seekBar: SeekBar?) {}
        })

        // Regenerate on toggle change
        val toggleListener = CompoundButton.OnCheckedChangeListener { _, _ ->
            passwordPreview.setText(generatePassword())
        }
        cbUpper.setOnCheckedChangeListener(toggleListener)
        cbLower.setOnCheckedChangeListener(toggleListener)
        cbDigits.setOnCheckedChangeListener(toggleListener)
        cbSymbols.setOnCheckedChangeListener(toggleListener)

        // Regenerate button
        val regenBtn = Button(this).apply {
            text = "🔄 Regenerate"
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0xFF3A3A5E.toInt())
            setPadding(dp(16), dp(8), dp(16), dp(8))
        }
        regenBtn.setOnClickListener {
            passwordPreview.setText(generatePassword())
        }
        root.addView(regenBtn)
        
        // Hide generator tools for save requests
        if (isSaveRequest) {
            lengthLabel.visibility = android.view.View.GONE
            slider.visibility = android.view.View.GONE
            toggleRow.visibility = android.view.View.GONE
            regenBtn.visibility = android.view.View.GONE
        }
        
        // Spacer
        root.addView(android.view.View(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(16))
        })

        // Save & Fill button
        val saveBtn = Button(this).apply {
            text = if (isSaveRequest) "✅ Save to Vault" else "✅ Save & Fill"
            textSize = 16f
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0xFF6C63FF.toInt())
            setPadding(dp(24), dp(12), dp(24), dp(12))
        }
        saveBtn.setOnClickListener {
            saveBtn.isEnabled = false
            saveBtn.text = "Saving..."
            scope.launch {
                try {
                    val finalName = nameEt.text.toString().trim()
                    val finalWebsite = websiteEt.text.toString().trim()
                    val finalUsername = usernameEt.text.toString().trim()
                    val finalPassword = passwordPreview.text.toString().trim()
                    
                    // Save to vault
                    AutofillBridge.saveCapturedCredential(
                        applicationContext, finalName, finalWebsite, finalUsername, finalPassword
                    )

                    if (isSaveRequest) {
                        setResult(RESULT_OK)
                        finish()
                        return@launch
                    }

                    // Build the Dataset to return
                    val fields = FieldFinder.Fields(usernameId, passwordId, "")
                    
                    val v1Spec = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R && inlineSpecs != null) {
                        inlineSpecs.firstOrNull { spec ->
                            androidx.autofill.inline.UiVersions.getVersions(spec.style).contains(androidx.autofill.inline.UiVersions.INLINE_UI_VERSION_1)
                        }
                    } else null
                    
                    val useInline = v1Spec != null

                    val dataset = if (useInline && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                        AutofillUtils.buildInlineDataset(
                            applicationContext, packageName, fields, finalWebsite, finalUsername, finalPassword,
                            v1Spec!!, 0, focusedId
                        )
                    } else {
                        AutofillUtils.buildDropdownDataset(packageName, fields, finalWebsite, finalUsername, finalPassword, focusedId)
                    }

                    val resultIntent = Intent()
                    resultIntent.putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset)
                    setResult(RESULT_OK, resultIntent)
                    android.util.Log.d("PeerVault", "Generator: saved & returning password for '$query'")
                    finish()
                } catch (e: Exception) {
                    android.util.Log.e("PeerVault", "Generator error: ${e.message}", e)
                    Toast.makeText(applicationContext, "Error: ${e.message}", Toast.LENGTH_SHORT).show()
                    saveBtn.isEnabled = true
                    saveBtn.text = "✅ Save & Fill"
                }
            }
        }
        root.addView(saveBtn)

        // Cancel button
        val cancelBtn = Button(this).apply {
            text = "Cancel"
            setTextColor(0xFFAAAAAA.toInt())
            setBackgroundColor(android.graphics.Color.TRANSPARENT)
            setPadding(dp(24), dp(8), dp(24), dp(8))
        }
        cancelBtn.setOnClickListener {
            setResult(RESULT_CANCELED)
            finish()
        }
        root.addView(cancelBtn)

        // Wrap in a ScrollView
        val scrollView = ScrollView(this).apply {
            setBackgroundColor(0xFF1E1E2E.toInt())
            addView(root)
        }
        setContentView(scrollView)
    }
}
