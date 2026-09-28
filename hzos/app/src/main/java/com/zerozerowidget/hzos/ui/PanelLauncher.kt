package com.zerozerowidget.hzos.ui

import android.content.Context
import android.content.Intent
import com.zerozerowidget.hzos.CardDetailActivity
import com.zerozerowidget.hzos.SettingsActivity

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
        }
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
        }
    )
}

/** One card or activity detail per pop-out: MULTIPLE_TASK gives every pop-out its own panel. */
fun Context.openDetailPanel(cardId: String, isSample: Boolean) {
    startActivity(
        Intent(this, CardDetailActivity::class.java).apply {
            putExtra(CardDetailActivity.EXTRA_CARD_ID, cardId)
            putExtra(CardDetailActivity.EXTRA_IS_SAMPLE, isSample)
            addFlags(
                Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT
                    or Intent.FLAG_ACTIVITY_NEW_TASK
                    or Intent.FLAG_ACTIVITY_MULTIPLE_TASK
            )
        }
    )
}

/** Same pop-out story for activities: every one gets its own panel. */
fun Context.openActivityDetailPanel(externalActivityId: String, isSample: Boolean) {
    startActivity(
        Intent(this, CardDetailActivity::class.java).apply {
            putExtra(CardDetailActivity.EXTRA_ACTIVITY_ID, externalActivityId)
            putExtra(CardDetailActivity.EXTRA_IS_SAMPLE, isSample)
            addFlags(
                Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT
                    or Intent.FLAG_ACTIVITY_NEW_TASK
                    or Intent.FLAG_ACTIVITY_MULTIPLE_TASK
            )
        }
    )
}
