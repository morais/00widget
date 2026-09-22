package com.example.zerozerowidget.hzos

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import com.example.zerozerowidget.hzos.ui.settings.SettingsPanel
import com.example.zerozerowidget.hzos.ui.theme.ZeroZeroWidgetTheme
import com.example.zerozerowidget.hzos.ui.trackPanelTransparency
import kotlinx.coroutines.launch

/** Connection panel: phone sign-in + manual URL/key entry. Singleton. */
class SettingsActivity : ComponentActivity() {
    companion object {
        /**
         * Open already asking: the panel returns to the root destination
         * and the sign-in section kicks its device flow without another
         * tap. Each arrival bumps [signInRequest], so a repeat press
         * while the panel is open starts the flow again.
         */
        const val EXTRA_AUTO_SIGN_IN = "extra_auto_sign_in"
    }

    private var pendingSendCallback: ((Boolean) -> Unit)? = null
    private var signInRequest by mutableIntStateOf(0)

    private val sendAuthLauncher: ActivityResultLauncher<Intent> =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            // Dialog outcome only (allowed or not). Login completion is
            // determined by device-code polling, never by this.
            pendingSendCallback?.invoke(result.resultCode == Activity.RESULT_OK)
            pendingSendCallback = null
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.getBooleanExtra(EXTRA_AUTO_SIGN_IN, false)) signInRequest++
        val app = application as ZeroZeroWidgetApp
        trackPanelTransparency(app)
        setContent {
            ZeroZeroWidgetTheme {
                SettingsPanel(
                    app = app,
                    onClose = { finishAndRemoveTask() },
                    onSendAuthUrl = { authUrl, onSent ->
                        sendAuthUrl(authUrl, onSent)
                    },
                    signInRequest = signInRequest,
                    onSignInRequestConsumed = { signInRequest = 0 },
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // singleTask reuses the open panel: a fresh request still has to
        // reach the composed screen, which it does as state.
        if (intent.getBooleanExtra(EXTRA_AUTO_SIGN_IN, false)) signInRequest++
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
