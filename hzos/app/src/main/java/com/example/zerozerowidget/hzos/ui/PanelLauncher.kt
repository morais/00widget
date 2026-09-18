package com.example.zerozerowidget.hzos.ui

import android.content.Context
import android.content.Intent
import com.example.zerozerowidget.hzos.ActivitiesActivity
import com.example.zerozerowidget.hzos.CardDetailActivity
import com.example.zerozerowidget.hzos.ConnectionActivity

/**
 * Multi-panel navigation. Each surface is its own activity; Horizon OS shows
 * each activity in its own shell panel — no SDK involved.
 *
 * Two launch shapes, and the difference matters:
 * - [openSingletonPanel]: activities + settings. NEW_TASK without
 *   MULTIPLE_TASK (plus singleTask launchMode in the manifest) reuses the
 *   one open instance instead of stacking duplicates.
 * - [openDetailPanel]: one card detail. Adds MULTIPLE_TASK so every pop-out
 *   is a new panel — pop out three cards, get three panels.
 */
fun Context.openActivitiesPanel() {
    startActivity(
        Intent(this, ActivitiesActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT or Intent.FLAG_ACTIVITY_NEW_TASK)
        },
    )
}

fun Context.openConnectionPanel() {
    startActivity(
        Intent(this, ConnectionActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT or Intent.FLAG_ACTIVITY_NEW_TASK)
        },
    )
}

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
