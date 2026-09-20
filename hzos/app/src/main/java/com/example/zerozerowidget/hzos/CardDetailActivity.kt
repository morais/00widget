package com.example.zerozerowidget.hzos

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import com.example.zerozerowidget.hzos.ui.dashboard.ActivityDetailPanel
import com.example.zerozerowidget.hzos.ui.dashboard.CardDetailPanel
import com.example.zerozerowidget.hzos.ui.openDeepLink
import com.example.zerozerowidget.hzos.ui.theme.ZeroZeroWidgetTheme
import com.example.zerozerowidget.hzos.ui.trackPanelTransparency

/**
 * Detail panels for cards and activities. Launched with MULTIPLE_TASK, so
 * every pop-out is its own shell panel. Exactly one id extra is present.
 */
class CardDetailActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as ZeroZeroWidgetApp
        trackPanelTransparency(app)
        val cardId = intent.getStringExtra(EXTRA_CARD_ID)
        val activityId = intent.getStringExtra(EXTRA_ACTIVITY_ID)
        setContent {
            ZeroZeroWidgetTheme {
                when {
                    !cardId.isNullOrBlank() -> CardDetailPanel(
                        app = app,
                        cardId = cardId,
                        onOpenLink = { url -> openDeepLink(this, url) },
                    )
                    !activityId.isNullOrBlank() -> ActivityDetailPanel(
                        app = app,
                        externalActivityId = activityId,
                        onOpenLink = { url -> openDeepLink(this, url) },
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
