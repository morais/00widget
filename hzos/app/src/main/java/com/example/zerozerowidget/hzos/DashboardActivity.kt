package com.example.zerozerowidget.hzos

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.example.zerozerowidget.hzos.ui.dashboard.DashboardPanel
import com.example.zerozerowidget.hzos.ui.openActivitiesPanel
import com.example.zerozerowidget.hzos.ui.openConnectionPanel
import com.example.zerozerowidget.hzos.ui.openDetailPanel
import com.example.zerozerowidget.hzos.ui.theme.ZeroZeroWidgetTheme

/** Launcher panel: the card list. Entry point of the app. */
class DashboardActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as ZeroZeroWidgetApp
        setContent {
            ZeroZeroWidgetTheme {
                DashboardPanel(
                    app = app,
                    onOpenActivities = { openActivitiesPanel() },
                    onOpenSettings = { openConnectionPanel() },
                    onPopOut = { cardId -> openDetailPanel(cardId) },
                )
            }
        }
    }
}
