package com.example.zerozerowidget.hzos

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.example.zerozerowidget.hzos.ui.activities.ActivitiesPanel
import com.example.zerozerowidget.hzos.ui.openConnectionPanel
import com.example.zerozerowidget.hzos.ui.theme.ZeroZeroWidgetTheme

/** Live Activities panel. Singleton: reopening reuses this instance. */
class ActivitiesActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as ZeroZeroWidgetApp
        setContent {
            ZeroZeroWidgetTheme {
                ActivitiesPanel(
                    app = app,
                    onClose = { finishAndRemoveTask() },
                    onOpenSettings = { openConnectionPanel() },
                )
            }
        }
    }
}
