package com.zerozerowidget.hzos.ui

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.os.Build
import android.os.PersistableBundle
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** How long a copied credential stays on the clipboard. */
private const val SECRET_CLIP_TTL_MS = 60_000L

/**
 * Copies text that carries a credential (the agent config with its token,
 * a rotated agent token): marked sensitive, so the system never shows it in
 * a clipboard preview, and cleared after a minute if it is still ours
 * (audit S5). The clear runs in the app scope, so closing Settings does
 * not cancel it.
 *
 * "Still ours" is judged by [label]. Android 10+ hides the clipboard from
 * an app without focus; when the check cannot read it, it leaves the
 * clipboard alone rather than risk wiping something the user copied since.
 */
fun copySecret(app: ZeroZeroWidgetApp, label: String, text: String) {
    val clipboard = app.getSystemService(ClipboardManager::class.java) ?: return
    val clip = ClipData.newPlainText(label, text).apply {
        description.extras = PersistableBundle().apply {
            // EXTRA_IS_SENSITIVE is API 33; the key is honoured below it too.
            val key = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ClipDescription.EXTRA_IS_SENSITIVE
            } else {
                "android.content.extra.IS_SENSITIVE"
            }
            putBoolean(key, true)
        }
    }
    clipboard.setPrimaryClip(clip)
    app.appScope.launch {
        delay(SECRET_CLIP_TTL_MS)
        if (clipboard.primaryClipDescription?.label == label) clipboard.clearPrimaryClip()
    }
}
