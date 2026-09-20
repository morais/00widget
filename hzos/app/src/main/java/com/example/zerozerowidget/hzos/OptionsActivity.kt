package com.example.zerozerowidget.hzos

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.example.zerozerowidget.hzos.ui.options.OptionsPanel
import com.example.zerozerowidget.hzos.ui.theme.ZeroZeroWidgetTheme
import com.example.zerozerowidget.hzos.ui.trackPanelTransparency

/** Additional options (panel look today). Singleton: reopening reuses it. */
class OptionsActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as ZeroZeroWidgetApp
        trackPanelTransparency(app)
        setContent {
            ZeroZeroWidgetTheme {
                OptionsPanel(app = app, onClose = { finishAndRemoveTask() })
            }
        }
    }
}
