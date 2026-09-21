package com.example.zerozerowidget.hzos

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import com.example.zerozerowidget.hzos.ui.openAgentConnectPanel
import com.example.zerozerowidget.hzos.ui.settings.SettingsPanel
import com.example.zerozerowidget.hzos.ui.openOptionsPanel
import com.example.zerozerowidget.hzos.ui.theme.ZeroZeroWidgetTheme
import com.example.zerozerowidget.hzos.ui.trackPanelTransparency
import kotlinx.coroutines.launch

/** Connection panel: phone sign-in + manual URL/key entry. Singleton. */
class SettingsActivity : ComponentActivity() {
    private var pendingSendCallback: ((Boolean) -> Unit)? = null

    private val sendAuthLauncher: ActivityResultLauncher<Intent> =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            // Dialog outcome only (allowed or not). Login completion is
            // determined by device-code polling, never by this.
            pendingSendCallback?.invoke(result.resultCode == Activity.RESULT_OK)
            pendingSendCallback = null
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as ZeroZeroWidgetApp
        trackPanelTransparency(app)
        setContent {
            ZeroZeroWidgetTheme {
                SettingsPanel(
                    app = app,
                    onClose = { finishAndRemoveTask() },
                    onOpenOptions = { openOptionsPanel() },
                    onOpenAgentConnect = { openAgentConnectPanel() },
                    onSendAuthUrl = { authUrl, onSent ->
                        sendAuthUrl(authUrl, onSent)
                    },
                )
            }
        }
    }

    private fun sendAuthUrl(authUrl: String, onSent: (Boolean) -> Unit) {
        app().appScope.launch {
            val intent = app().horizonAuth.buildSendIntent(authUrl)
            if (intent == null) {
                onSent(false)
                return@launch
            }
            pendingSendCallback = onSent
            try {
                sendAuthLauncher.launch(intent)
            } catch (e: Exception) {
                // No handler for the OS dialog (old OS, no Horizon app):
                // report not-sent instead of crashing the scope.
                android.util.Log.e("HorizonAuth", "send dialog launch failed: ${e.javaClass.simpleName}")
                pendingSendCallback = null
                onSent(false)
            }
        }
    }

    private fun app(): ZeroZeroWidgetApp = application as ZeroZeroWidgetApp
}
