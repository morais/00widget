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
import com.example.zerozerowidget.hzos.auth.ensureMetaUserMatches
import kotlinx.coroutines.launch

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

    override fun onStart() {
        super.onStart()
        // A Meta account switch doesn't restart panels: re-check on every
        // foreground so a stranger's token never survives one. Clearing
        // drops the dashboard to its signed-out state on its own.
        val app = application as ZeroZeroWidgetApp
        app.appScope.launch { ensureMetaUserMatches(app) }
    }
}
