package com.example.zerozerowidget.hzos.ui

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import com.example.zerozerowidget.hzos.CardDetailActivity
import com.example.zerozerowidget.hzos.SettingsActivity
import com.example.zerozerowidget.hzos.ZeroZeroWidgetApp
import kotlinx.coroutines.launch

/**
 * Multi-panel navigation. Each surface is its own activity; Horizon OS shows
 * each activity in its own shell panel — no SDK involved.
 *
 * Two launch shapes, and the difference matters:
 * - [openSettingsPanel]: singleton settings. NEW_TASK without
 *   MULTIPLE_TASK (plus singleTask launchMode in the manifest) reuses the
 *   one open instance instead of stacking duplicates.
 * - [openDetailPanel]: one card detail. Adds MULTIPLE_TASK so every pop-out
 *   is a new panel — pop out three cards, get three panels.
 */
fun Context.openSettingsPanel() {
    startActivity(
        Intent(this, SettingsActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT or Intent.FLAG_ACTIVITY_NEW_TASK)
        },
    )
}

/**
 * Dashboard "Sign in": opens settings already asking, so the panel
 * returns to the root destination and starts the device flow on arrival.
 */
fun Context.openSettingsPanelAndSignIn() {
    startActivity(
        Intent(this, SettingsActivity::class.java).apply {
            putExtra(SettingsActivity.EXTRA_AUTO_SIGN_IN, true)
            addFlags(Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT or Intent.FLAG_ACTIVITY_NEW_TASK)
        },
    )
}

/** One card or activity detail per pop-out: MULTIPLE_TASK gives every pop-out its own panel. */
fun Context.openDetailPanel(cardId: String) {
    startActivity(
        Intent(this, CardDetailActivity::class.java).apply {
            putExtra(CardDetailActivity.EXTRA_CARD_ID, cardId)
            addFlags(
                Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT
                    or Intent.FLAG_ACTIVITY_NEW_TASK
                    or Intent.FLAG_ACTIVITY_MULTIPLE_TASK,
            )
        },
    )
}

/** Same pop-out story for activities: every one gets its own panel. */
fun Context.openActivityDetailPanel(externalActivityId: String) {
    startActivity(
        Intent(this, CardDetailActivity::class.java).apply {
            putExtra(CardDetailActivity.EXTRA_ACTIVITY_ID, externalActivityId)
            addFlags(
                Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT
                    or Intent.FLAG_ACTIVITY_NEW_TASK
                    or Intent.FLAG_ACTIVITY_MULTIPLE_TASK,
            )
        },
    )
}

/**
 * Applies the transparency preference to this panel's window, live. Called
 * from every panel activity's onCreate; the Flow keeps it applied for the
 * activity's whole life, so flipping the toggle in the Connection panel
 * re-skins every open panel without recreating anything.
 *
 * Deliberately touches ONLY the background drawable, never the pixel
 * format: every activity is born translucent (PanelAppTheme.Transparent in
 * the manifest), so the surface is always alpha-capable and opaque mode is
 * just black paint. Changing PixelFormat at runtime is what produced the
 * hover black-flashes and scroll smearing — never do that again.
 */
fun ComponentActivity.trackPanelTransparency(app: ZeroZeroWidgetApp) {
    lifecycleScope.launch {
        app.panelPrefs.transparent.collect { transparent ->
            window.setBackgroundDrawable(
                ColorDrawable(if (transparent) Color.TRANSPARENT else Color.BLACK),
            )
        }
    }
}
