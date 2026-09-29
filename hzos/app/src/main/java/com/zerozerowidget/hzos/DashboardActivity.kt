package com.zerozerowidget.hzos

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.zerozerowidget.hzos.ui.ProvideTickingNow
import com.zerozerowidget.hzos.ui.dashboard.DashboardPanel
import com.zerozerowidget.hzos.ui.openActivityDetailPanel
import com.zerozerowidget.hzos.ui.openDetailPanel
import com.zerozerowidget.hzos.ui.openSettingsPanel
import com.zerozerowidget.hzos.ui.theme.ZeroZeroWidgetTheme

/** Launcher panel: the card list. Entry point of the app. */
class DashboardActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as ZeroZeroWidgetApp
        setContent {
            ZeroZeroWidgetTheme {
                ProvideTickingNow {
                    DashboardPanel(
                        app = app,
                        onOpenSettings = { openSettingsPanel() },
                        onPopOut = { cardId, isSample -> openDetailPanel(cardId, isSample) },
                        onPopOutActivity = { id, isSample -> openActivityDetailPanel(id, isSample) }
                    )
                }
            }
        }
    }
}
