package com.zerozerowidget.hzos

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import com.zerozerowidget.hzos.ui.dashboard.ActivityDetailPanel
import com.zerozerowidget.hzos.ui.dashboard.CardDetailPanel
import com.zerozerowidget.hzos.ui.openDeepLink
import com.zerozerowidget.hzos.ui.theme.ZeroZeroWidgetTheme

/**
 * Detail panels for cards and activities. Launched with MULTIPLE_TASK, so
 * every pop-out is its own shell panel. Exactly one id extra is present.
 */
class CardDetailActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as ZeroZeroWidgetApp
        val cardId = intent.getStringExtra(EXTRA_CARD_ID)
        val activityId = intent.getStringExtra(EXTRA_ACTIVITY_ID)
        setContent {
            ZeroZeroWidgetTheme {
                when {
                    !cardId.isNullOrBlank() -> CardDetailPanel(
                        app = app,
                        cardId = cardId,
                        onOpenLink = { url -> openDeepLink(this, url) },
                        onDeleted = { finishAndRemoveTask() },
                    )
                    !activityId.isNullOrBlank() -> ActivityDetailPanel(
                        app = app,
                        externalActivityId = activityId,
                        onOpenLink = { url -> openDeepLink(this, url) },
                        onDeleted = { finishAndRemoveTask() },
                    )
                    else -> Text(
                        "Nothing to show.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }
    }

    companion object {
        const val EXTRA_CARD_ID = "extra_card_id"
        const val EXTRA_ACTIVITY_ID = "extra_activity_id"
    }
}
