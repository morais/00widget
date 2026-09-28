package com.zerozerowidget.hzos

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.zerozerowidget.hzos.ui.dashboard.ActivityDetailPanel
import com.zerozerowidget.hzos.ui.dashboard.CardDetailPanel
import com.zerozerowidget.hzos.ui.openDeepLink
import com.zerozerowidget.hzos.ui.theme.ZeroZeroWidgetTheme
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalTypography

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
        // Which store the id refers to. Ids alone cannot say: a server card
        // and a local sample may share one.
        val isSample = intent.getBooleanExtra(EXTRA_IS_SAMPLE, false)
        setContent {
            ZeroZeroWidgetTheme {
                when {
                    !cardId.isNullOrBlank() -> CardDetailPanel(
                        app = app,
                        cardId = cardId,
                        isSample = isSample,
                        onOpenLink = { url -> openDeepLink(this, url) },
                        onDeleted = { finishAndRemoveTask() }
                    )

                    !activityId.isNullOrBlank() -> ActivityDetailPanel(
                        app = app,
                        externalActivityId = activityId,
                        isSample = isSample,
                        onOpenLink = { url -> openDeepLink(this, url) },
                        onDeleted = { finishAndRemoveTask() }
                    )

                    else -> Text(
                        "Nothing to show.",
                        style = LocalTypography.current.body
                    )
                }
            }
        }
    }

    companion object {
        const val EXTRA_CARD_ID = "extra_card_id"
        const val EXTRA_ACTIVITY_ID = "extra_activity_id"
        const val EXTRA_IS_SAMPLE = "extra_is_sample"
    }
}
