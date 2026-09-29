package com.zerozerowidget.hzos

import android.content.Intent
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
        // The launcher reopening an app whose task was started some other
        // way (a panel, adb) puts a new dashboard on top of the old one
        // instead of bringing the task forward, and the translucent window
        // shows both. A launcher start that isn't the task's root is that
        // duplicate: close it, which leaves the existing dashboard in front.
        if (!isTaskRoot && intent.action == Intent.ACTION_MAIN && intent.hasCategory(Intent.CATEGORY_LAUNCHER)) {
            finish()
            return
        }
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
