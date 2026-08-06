package com.example.peervault.app

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.autofill.Dataset
import android.service.autofill.FillResponse
import android.service.autofill.InlinePresentation
import android.service.autofill.SaveInfo
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import android.widget.inline.InlinePresentationSpec
import androidx.annotation.RequiresApi
import androidx.autofill.inline.v1.InlineSuggestionUi
import androidx.autofill.inline.UiVersions
import java.security.SecureRandom

object AutofillUtils {

    fun generateStrongPassword(length: Int = 16): String {
        val chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*"
        val random = SecureRandom()
        val sb = java.lang.StringBuilder(length)
        for (i in 0 until length) {
            sb.append(chars[random.nextInt(chars.length)])
        }
        return sb.toString()
    }

    @RequiresApi(Build.VERSION_CODES.R)
    fun buildInlinePresentation(
        context: Context,
        spec: InlinePresentationSpec,
        title: String,
        subtitle: String,
    ): InlinePresentation? {
        val isInlineCompatible = UiVersions.getVersions(spec.style).contains(UiVersions.INLINE_UI_VERSION_1)
        if (!isInlineCompatible) {
            android.util.Log.w("PeerVault", "Autofill request INLINE_UI_VERSION_1 unsupported")
            return null
        }
        // Bitwarden explicitly uses a generic, empty service PendingIntent for the slice UI content
        // so that the slice taps inherently map back through the Android Framework Dataset handler 
        // rather than launching their own rogue activities natively from the keyboard interface.
        val dummyIntent = PendingIntent.getService(
            context,
            0,
            Intent(),
            PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val maxTitle = if (title.length > 20) title.take(17) + "..." else title
        val maxSubtitle = if (subtitle.length > 15) subtitle.take(12) + "..." else subtitle

        val builder = InlineSuggestionUi.newContentBuilder(dummyIntent)
            .setTitle(maxTitle)
        
        if (maxSubtitle.isNotEmpty()) {
            builder.setSubtitle(maxSubtitle)
        }

        val slice = builder.build().slice

        return InlinePresentation(slice, spec, /* pinned= */ false)
    }

    fun addSuggestPasswordDataset(
        context: Context,
        packageName: String,
        responseBuilder: FillResponse.Builder,
        fields: FieldFinder.Fields,
        useInline: Boolean,
        inlineSpecs: List<InlinePresentationSpec>?,
        queryHashCode: Int,
        focusedId: AutofillId?,
        query: String = "",
        capturedUsername: String = ""
    ): Boolean {
        val passwordId = fields.passwordId ?: return false

        val suggestPresentation = RemoteViews(packageName, com.example.peervault.R.layout.autofill_remote_view).apply {
            setTextViewText(com.example.peervault.R.id.title, "\uD83D\uDD12 Generate strong password")
            setTextViewText(com.example.peervault.R.id.subtitle, "PeerVault Generator")
        }

        // Auth-gated: tapping the chip launches the generator activity
        // where the user can configure password length and character sets.
        val genIntent = Intent(context, PeerVaultAutofillGeneratorActivity::class.java).apply {
            putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_QUERY, query)
            putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_USERNAME, capturedUsername)
            putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_USERNAME_ID, fields.usernameId)
            putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_PASSWORD_ID, passwordId)
            putExtra(PeerVaultAutofillGeneratorActivity.EXTRA_FOCUSED_ID, focusedId)
            if (inlineSpecs != null) {
                putParcelableArrayListExtra("inline_specs", ArrayList(inlineSpecs))
            }
            addFlags(Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
            addFlags(Intent.FLAG_ACTIVITY_NO_HISTORY)
            addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
        }
        val mutabilityFlag = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val genPendingIntent = PendingIntent.getActivity(
            context, queryHashCode + 2000, genIntent,
            PendingIntent.FLAG_CANCEL_CURRENT or mutabilityFlag
        )

        val builder = Dataset.Builder().setId(java.util.UUID.randomUUID().toString())
        builder.setAuthentication(genPendingIntent.intentSender)

        val inlinePresentation = if (useInline && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !inlineSpecs.isNullOrEmpty()) {
            buildInlinePresentation(context, inlineSpecs.first(), "\uD83D\uDD12 Generate password", "")
        } else null

        if (inlinePresentation != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setInlinePresentation(inlinePresentation)
        }

        val autofillIds = listOfNotNull(fields.usernameId, fields.passwordId, focusedId)
            .distinct()
            .toTypedArray()

        if (android.os.Build.VERSION.SDK_INT >= 33) {
            val presentationBuilder = android.service.autofill.Presentations.Builder()
                .setMenuPresentation(suggestPresentation)
            inlinePresentation?.let { presentationBuilder.setInlinePresentation(it) }
            val fieldPresentations = presentationBuilder.build()

            autofillIds.forEach { id ->
                val fb = android.service.autofill.Field.Builder()
                    .setValue(AutofillValue.forText("PLACEHOLDER"))
                    .setPresentations(fieldPresentations)
                builder.setField(id, fb.build())
            }
        } else {
            autofillIds.forEach { id ->
                builder.setValue(id, AutofillValue.forText("PLACEHOLDER"), suggestPresentation)
            }
        }

        try {
            responseBuilder.addDataset(builder.build())
            return true
        } catch (e: Exception) {
            android.util.Log.w("PeerVault", "Failed to build suggest dataset: ${e.message}")
            return false
        }
    }

    @RequiresApi(Build.VERSION_CODES.R)
    fun buildInlineDataset(
        context: Context,
        packageName: String,
        fields: FieldFinder.Fields,
        websiteName: String,
        username: String,
        password: String,
        spec: InlinePresentationSpec,
        index: Int,
        focusedId: AutofillId?,
    ): Dataset {
        val presentation = RemoteViews(packageName, com.example.peervault.R.layout.autofill_remote_view).apply {
            setTextViewText(com.example.peervault.R.id.title, websiteName)
            if (username.isNotBlank()) {
                setTextViewText(com.example.peervault.R.id.subtitle, username)
            } else {
                setViewVisibility(com.example.peervault.R.id.subtitle, android.view.View.GONE)
            }
        }
        val inlinePresentation = buildInlinePresentation(context, spec, websiteName, username)
        
        // When appending multiple datasets directly to a FillResponse without Auth,
        // Android Autofill requires each dataset to have a unique string ID to correctly
        // map click selections. If absent, you can view the chips but tapping does nothing.
        val builder = Dataset.Builder().setId(java.util.UUID.randomUUID().toString())
        
        if (Build.VERSION.SDK_INT >= 33) { // Build.VERSION_CODES.TIRAMISU
            val presentationBuilder = android.service.autofill.Presentations.Builder()
            // Only set inline presentation if it was successfully built.
            // If null (keyboard doesn't support INLINE_UI_VERSION_1), the chip
            // simply won't be shown and the dropdown fallback is used instead.
            inlinePresentation?.let { presentationBuilder.setInlinePresentation(it) }
            val presentations = presentationBuilder.setMenuPresentation(presentation).build()

            if (username.isNotBlank() && fields.usernameId != null) {
                builder.setField(fields.usernameId, android.service.autofill.Field.Builder().setValue(AutofillValue.forText(username)).setPresentations(presentations).build())
            }
            if (password.isNotBlank() && fields.passwordId != null) {
                builder.setField(fields.passwordId, android.service.autofill.Field.Builder().setValue(AutofillValue.forText(password)).setPresentations(presentations).build())
            }
            if (focusedId != null && focusedId != fields.usernameId && focusedId != fields.passwordId) {
                val valToInject = if (password.isNotBlank()) password else username
                if (valToInject.isNotBlank()) {
                    builder.setField(focusedId, android.service.autofill.Field.Builder().setValue(AutofillValue.forText(valToInject)).setPresentations(presentations).build())
                }
            }
        } else {
            // Pre-Tiramisu: only set inline presentation if not null
            inlinePresentation?.let { builder.setInlinePresentation(it) }
            
            if (username.isNotBlank() && fields.usernameId != null) {
                builder.setValue(fields.usernameId, AutofillValue.forText(username), presentation) 
            }
            if (password.isNotBlank() && fields.passwordId != null) {
                builder.setValue(fields.passwordId, AutofillValue.forText(password), presentation) 
            }
            if (focusedId != null && focusedId != fields.usernameId && focusedId != fields.passwordId) {
                val valToInject = if (password.isNotBlank()) password else username
                if (valToInject.isNotBlank()) {
                    builder.setValue(focusedId, AutofillValue.forText(valToInject), presentation)
                }
            }
        }

        return builder.build()
    }

    fun buildDropdownDataset(
        packageName: String,
        fields: FieldFinder.Fields,
        websiteName: String,
        username: String,
        password: String,
        focusedId: AutofillId?,
    ): Dataset {
        val builder = Dataset.Builder().setId(java.util.UUID.randomUUID().toString())
        val presentation = RemoteViews(packageName, com.example.peervault.R.layout.autofill_remote_view).apply {
            setTextViewText(com.example.peervault.R.id.title, websiteName)
            if (username.isNotBlank()) {
                setTextViewText(com.example.peervault.R.id.subtitle, username)
            } else {
                setViewVisibility(com.example.peervault.R.id.subtitle, android.view.View.GONE)
            }
        }
        
        if (Build.VERSION.SDK_INT >= 33) {
            val presentations = android.service.autofill.Presentations.Builder().setMenuPresentation(presentation).build()
            
            if (username.isNotBlank() && fields.usernameId != null) {
                builder.setField(fields.usernameId, android.service.autofill.Field.Builder().setValue(AutofillValue.forText(username)).setPresentations(presentations).build())
            }
            if (password.isNotBlank() && fields.passwordId != null) {
                builder.setField(fields.passwordId, android.service.autofill.Field.Builder().setValue(AutofillValue.forText(password)).setPresentations(presentations).build())
            }
            if (focusedId != null && focusedId != fields.usernameId && focusedId != fields.passwordId) {
                val valToInject = if (password.isNotBlank()) password else username
                if (valToInject.isNotBlank()) {
                    builder.setField(focusedId, android.service.autofill.Field.Builder().setValue(AutofillValue.forText(valToInject)).setPresentations(presentations).build())
                }
            }
        } else {
            if (username.isNotBlank() && fields.usernameId != null) {
                builder.setValue(fields.usernameId, AutofillValue.forText(username), presentation) 
            }
            if (password.isNotBlank() && fields.passwordId != null) {
                builder.setValue(fields.passwordId, AutofillValue.forText(password), presentation) 
            }
            if (focusedId != null && focusedId != fields.usernameId && focusedId != fields.passwordId) {
                val valToInject = if (password.isNotBlank()) password else username
                if (valToInject.isNotBlank()) {
                    builder.setValue(focusedId, AutofillValue.forText(valToInject), presentation)
                }
            }
        }

        return builder.build()
    }

    fun buildSaveInfo(fields: FieldFinder.Fields): SaveInfo? {
        val passwordId = fields.passwordId ?: return null
        val saveDataTypes = SaveInfo.SAVE_DATA_TYPE_PASSWORD
        val requiredIds = arrayOf(passwordId)
        
        val builder = SaveInfo.Builder(saveDataTypes, requiredIds)
        if (fields.usernameId != null) {
            builder.setOptionalIds(arrayOf(fields.usernameId))
        }
        val displayApp = fields.appIdentifier.replaceFirstChar { if (it.isLowerCase()) it.titlecase(java.util.Locale.getDefault()) else it.toString() }
        builder.setDescription("Save credentials for $displayApp")
        return builder.build()
    }
}
