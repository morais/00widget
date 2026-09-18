package com.example.zerozerowidget.hzos

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import com.example.zerozerowidget.hzos.ui.dashboard.CardDetailPanel
import com.example.zerozerowidget.hzos.ui.openDeepLink
import com.example.zerozerowidget.hzos.ui.theme.ZeroZeroWidgetTheme

/**
 * One card's detail. Launched with MULTIPLE_TASK, so every pop-out is its
 * own shell panel: three popped-out cards, three panels side by side.
 */
class CardDetailActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as ZeroZeroWidgetApp
        val cardId = intent.getStringExtra(EXTRA_CARD_ID)
        setContent {
            ZeroZeroWidgetTheme {
                if (cardId.isNullOrBlank()) {
                    Text(
                        "No card id supplied.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                } else {
                    CardDetailPanel(
                        app = app,
                        cardId = cardId,
                        onClose = { finishAndRemoveTask() },
                        onOpenLink = { url -> openDeepLink(this, url) },
                    )
                }
            }
        }
    }

    companion object {
        const val EXTRA_CARD_ID = "extra_card_id"
    }
}
