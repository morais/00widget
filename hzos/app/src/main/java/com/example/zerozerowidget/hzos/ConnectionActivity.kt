package com.example.zerozerowidget.hzos

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import com.example.zerozerowidget.hzos.ui.settings.ConnectionPanel
import com.example.zerozerowidget.hzos.ui.theme.ZeroZeroWidgetTheme
import kotlinx.coroutines.launch

/** Connection panel: phone sign-in + manual URL/key entry. Singleton. */
class ConnectionActivity : ComponentActivity() {
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
        setContent {
            ZeroZeroWidgetTheme {
                ConnectionPanel(
                    app = app,
                    onClose = { finishAndRemoveTask() },
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
            sendAuthLauncher.launch(intent)
        }
    }

    private fun app(): ZeroZeroWidgetApp = application as ZeroZeroWidgetApp
}
