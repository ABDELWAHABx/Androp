package app.androp.android.utils

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.util.Log

object ClipboardUtil {
    private const val TAG = "ClipboardUtil"

    /**
     * Get the current text from clipboard
     */
    fun getClipboardText(context: Context): String? {
        return try {
            val clipboardManager =
                context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clipData = clipboardManager.primaryClip

            if (clipData != null && clipData.itemCount > 0) {
                val item = clipData.getItemAt(0)
                // Use coerceToText to handle non-text items if needed, or stick to text
                item.text?.toString() ?: item.coerceToText(context)?.toString()
            } else {
                null
            }
        } catch (e: Exception) {
            // Keep error logging for exceptions
            Log.e(TAG, "Error getting clipboard text: ${e.message}")
            null
        }
    }

    /**
     * Set text to clipboard
     */
    fun setClipboardText(context: Context, text: String): Boolean {
        return try {
            val clipboardManager =
                context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clipData = ClipData.newPlainText("androp", text)
            clipboardManager.setPrimaryClip(clipData)

            true
        } catch (e: Exception) {
            Log.e(TAG, "Error setting clipboard text: ${e.message}")
            false
        }
    }

    /**
     * Register clipboard change listener
     * Returns a listener that can be used to unregister
     */
    fun registerClipboardListener(
        context: Context,
        onClipboardChanged: (String) -> Unit
    ): ClipboardManager.OnPrimaryClipChangedListener {
        val clipboardManager =
            context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

        val listener = ClipboardManager.OnPrimaryClipChangedListener {
            try {
                val clipText = getClipboardText(context)
                if (!clipText.isNullOrEmpty()) {

                    onClipboardChanged(clipText)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error in clipboard listener: ${e.message}")
            }
        }

        clipboardManager.addPrimaryClipChangedListener(listener)
        Log.d(TAG, "Clipboard listener registered")
        return listener
    }

    /**
     * Unregister clipboard change listener
     */
    fun unregisterClipboardListener(
        context: Context,
        listener: ClipboardManager.OnPrimaryClipChangedListener
    ) {
        try {
            val clipboardManager =
                context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboardManager.removePrimaryClipChangedListener(listener)
            Log.d(TAG, "Clipboard listener unregistered")
        } catch (e: Exception) {
            Log.e(TAG, "Error unregistering clipboard listener: ${e.message}")
        }
    }

    /**
     * Set a content URI to clipboard (useful for images)
     */
    fun copyUriToClipboard(context: Context, uri: android.net.Uri): Boolean {
        return try {
            val clipboardManager =
                context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clipData =
                ClipData.newUri(context.contentResolver, "androp Image", uri)
            clipboardManager.setPrimaryClip(clipData)

            true
        } catch (e: Exception) {
            Log.e(TAG, "Error setting clipboard URI: ${e.message}")
            false
        }
    }
}
