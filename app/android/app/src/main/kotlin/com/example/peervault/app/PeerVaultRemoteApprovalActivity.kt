package com.example.peervault.app

import android.os.Bundle
import androidx.biometric.BiometricPrompt
import androidx.fragment.app.FragmentActivity
import java.util.concurrent.Executor

/**
 * Launched from the notification ApprovalNotifier posts. Exists purely
 * because BiometricPrompt requires a real Activity — the background
 * FlutterEngine handling the actual sync/approval logic has none. Shows
 * the system biometric/device-credential prompt immediately; whatever the
 * result, it's reported back to that SAME engine via
 * AutofillBridge.resolveApproval and this activity finishes right away.
 * There is no custom UI here beyond what BiometricPrompt itself draws.
 */
class PeerVaultRemoteApprovalActivity : FragmentActivity() {
    companion object {
        const val EXTRA_ACTION_LABEL = "action_label"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val actionLabel = intent.getStringExtra(EXTRA_ACTION_LABEL) ?: "access a saved password"

        val executor = Executor { command -> runOnUiThread(command) }
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                AutofillBridge.resolveApproval(true)
                com.example.peervault.MainActivity.resolveApproval(true)
                ApprovalNotifier.dismiss(applicationContext)
                finish()
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                AutofillBridge.resolveApproval(false)
                com.example.peervault.MainActivity.resolveApproval(false)
                ApprovalNotifier.dismiss(applicationContext)
                finish()
            }

            override fun onAuthenticationFailed() {
                // A single failed attempt (e.g. wrong finger) — let the
                // prompt keep showing rather than denying immediately;
                // onAuthenticationError fires once the prompt gives up.
            }
        }

        val prompt = BiometricPrompt(this, executor, callback)
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Approve from your browser?")
            .setSubtitle("Your PeerVault browser extension wants to $actionLabel")
            .setAllowedAuthenticators(
                androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
            .build()
        prompt.authenticate(info)
    }
}
