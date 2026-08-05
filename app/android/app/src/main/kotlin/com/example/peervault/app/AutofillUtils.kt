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
        focusedId: AutofillId?
    ): Boolean {
        val passwordId = fields.passwordId ?: return false

        val suggestedPassword = generateStrongPassword(20)
        val suggestPresentation = RemoteViews(packageName, com.example.peervault.R.layout.autofill_remote_view).apply {
            setTextViewText(com.example.peervault.R.id.title, "\uD83D\uDD12 Generate strong password")
            setTextViewText(com.example.peervault.R.id.subtitle, "PeerVault Generator")
        }

        val builder = Dataset.Builder()

        val inlinePresentation = if (useInline && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !inlineSpecs.isNullOrEmpty()) {
            val dummyIntent = PendingIntent.getActivity(
                context, queryHashCode + 1003,
                Intent(context, PeerVaultAutofillAuthActivity::class.java).apply {
                    putExtra("notify_only", true) // Ensures it immediately closes if accidentally tapped
                },
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            buildInlinePresentation(context, inlineSpecs.first(), "\uD83D\uDD12 Generate password", "")
        } else null

        if (inlinePresentation != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setValue(passwordId, AutofillValue.forText(suggestedPassword), suggestPresentation, inlinePresentation)
            focusedId?.let {
                if (it != passwordId && it != fields.usernameId) {
                    builder.setValue(it, AutofillValue.forText(suggestedPassword), suggestPresentation, inlinePresentation)
                }
            }
        } else {
            builder.setValue(passwordId, AutofillValue.forText(suggestedPassword), suggestPresentation)
            focusedId?.let {
                if (it != passwordId && it != fields.usernameId) {
                    builder.setValue(it, AutofillValue.forText(suggestedPassword), suggestPresentation)
                }
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
        val builder = Dataset.Builder()
        
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
        val builder = Dataset.Builder()
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
        val saveDataTypes = SaveInfo.SAVE_DATA_TYPE_PASSWORD or
            (if (fields.usernameId != null) SaveInfo.SAVE_DATA_TYPE_USERNAME else 0)
        val requiredIds = listOfNotNull(fields.usernameId, passwordId).toTypedArray()
        
        val builder = SaveInfo.Builder(saveDataTypes, requiredIds)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setFlags(SaveInfo.FLAG_SAVE_ON_ALL_VIEWS_INVISIBLE)
        }
        return builder.build()
    }
}
