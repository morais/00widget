package com.example.zerozerowidget.hzos

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.example.zerozerowidget.hzos.ui.dashboard.DashboardPanel
import com.example.zerozerowidget.hzos.ui.openActivityDetailPanel
import com.example.zerozerowidget.hzos.ui.openSettingsPanel
import com.example.zerozerowidget.hzos.ui.openDetailPanel
import com.example.zerozerowidget.hzos.ui.theme.ZeroZeroWidgetTheme
import com.example.zerozerowidget.hzos.ui.trackPanelTransparency

/** Launcher panel: the card list. Entry point of the app. */
class DashboardActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as ZeroZeroWidgetApp
        trackPanelTransparency(app)
        setContent {
            ZeroZeroWidgetTheme {
                DashboardPanel(
                    app = app,
                    onOpenSettings = { openSettingsPanel() },
                    onPopOut = { cardId -> openDetailPanel(cardId) },
                    onPopOutActivity = { id -> openActivityDetailPanel(id) },
                )
            }
        }
    }
}
