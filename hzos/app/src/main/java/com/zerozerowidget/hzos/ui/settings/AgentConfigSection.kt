package com.zerozerowidget.hzos.ui.settings

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.data.AgentTokenRotation
import com.zerozerowidget.hzos.data.ConnectionStore
import com.zerozerowidget.hzos.data.DummyAccountData
import com.zerozerowidget.hzos.ui.cards.GlassCard
import com.zerozerowidget.hzos.ui.connectionState
import com.zerozerowidget.hzos.ui.copySecret
import com.zerozerowidget.hzos.ui.showDummyAccountDataState
import com.zerozerowidget.hzos.ui.theme.spacing
import com.zerozerowidget.hzos.ui.uiset.UiSetConfirmDialog
import com.zerozerowidget.hzos.ui.uiset.UiSetCopyIcon
import com.zerozerowidget.hzos.ui.uiset.UiSetIconButton
import com.zerozerowidget.hzos.ui.uiset.UiSetSecondaryButton
import com.zerozerowidget.hzos.ui.uiset.uiSetAccent
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalColorScheme
import metavrx.uiset.compose.theme.LocalContentColors
import metavrx.uiset.compose.theme.LocalTypography

/**
 * Agent config entry: the "Dear agent" integration text iOS Settings shows,
 * plus the connector doorway below it.
 *
 * Signed out, the text names the server and says the token arrives after
 * sign-in; signed in, it names the token too. The displayed string and the
 * copied string are deliberately the same: a copy button that quietly puts
 * the real token on the clipboard while the screen shows a placeholder is
 * how the token ends up pasted in front of whoever the placeholder was
 * hiding it from.
 */
@Composable
internal fun AgentConfigSection(
    app: ZeroZeroWidgetApp,
    cardAlpha: Float,
    onOpenAgentConnect: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val connection by app.connectionStore.connectionState()
    val showDummy by app.panelPrefs.showDummyAccountDataState()
    var copied by remember { mutableStateOf(false) }
    val baseUrl = ConnectionStore.effectiveBaseUrl(connection.baseUrl).orEmpty()
    val signedIn = connection.apiKey.isNotBlank()
    val displayedToken = if (showDummy) DummyAccountData.API_KEY else connection.apiKey
    val agentConfig = if (!signedIn) {
        "Dear agent: To integrate with 00Widget, read the instructions at $baseUrl; " +
            "use that as the base URL. You'll need an authorization token, " +
            "which will be available after you sign in."
    } else {
        "Dear agent: To integrate with 00Widget, read the instructions at $baseUrl; " +
            "use that as the base URL, and use $displayedToken as the authorization token."
    }

    GlassCard(cardAlpha = cardAlpha) {
        Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
            Text("Agent config", style = LocalTypography.current.title)
            Row(verticalAlignment = Alignment.Top) {
                SelectionContainer(Modifier.weight(1f)) {
                    Text(
                        agentConfig,
                        style = LocalTypography.current.bodySmall,
                        color = LocalContentColors.current.secondary
                    )
                }
                UiSetIconButton(
                    onClick = {
                        // Signed in, the config carries the token: copied
                        // as a secret (sensitive, cleared after a minute).
                        copySecret(app, "00Widget agent config", agentConfig)
                        copied = true
                        scope.launch {
                            // Acknowledgement of the tap, not a running
                            // clipboard status — matches iOS (10s there).
                            delay(10_000)
                            copied = false
                        }
                    },
                    contentDescription = if (copied) "Agent config copied" else "Copy agent config"
                ) {
                    UiSetCopyIcon(copied)
                }
            }
            if (copied) {
                Text(
                    "Copied",
                    style = LocalTypography.current.bodySmall,
                    color = uiSetAccent()
                )
            }
            // The token path and the connector doorway are the two ways in;
            // the rule keeps them from reading as one paragraph. UiSet
            // ships the divider color but no divider component.
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(LocalColorScheme.current.divider)
            )
            Text(
                "Connect assistants (Claude, ChatGPT, OpenCode…) without handing them a token.",
                style = LocalTypography.current.bodySmall,
                color = LocalContentColors.current.secondary
            )
            UiSetSecondaryButton("Connect an agent", onClick = onOpenAgentConnect)
        }
    }
}

/**
 * Replaces the tokens the account's agents publish with. Logged-in only,
 * mirroring the rotation in iOS AccountExitView — but note what it is and
 * is not: it revokes `publisher`/`agent` purpose keys, never the token
 * shown above (this headset's own sign-in) and never connectors, so the
 * headset stays signed in and assistants stay connected. The replacement
 * is answered once, so it is shown here for handoff, not stored anywhere.
 */
@Composable
internal fun RotateAgentTokensSection(app: ZeroZeroWidgetApp) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var confirming by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var rotated by remember { mutableStateOf<AgentTokenRotation?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var copied by remember { mutableStateOf(false) }

    Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
        Text("Agent tokens", style = LocalTypography.current.title)
        Text(
            "Use this if an agent token may have been exposed. Every old agent " +
                "token stops working and one replacement is created — give " +
                "it to your agents. This headset stays signed in.",
            style = LocalTypography.current.bodySmall,
            color = LocalContentColors.current.secondary
        )
        error?.let {
            Text(
                it,
                style = LocalTypography.current.bodySmall,
                color = LocalColorScheme.current.negative.content
            )
        }
        rotated?.let {
            Text(
                "Rotated — ${it.revokedAgentTokens} old token(s) revoked. " +
                    "Copy the replacement now; it is shown once.",
                style = LocalTypography.current.bodySmall,
                color = uiSetAccent()
            )
            Row(verticalAlignment = Alignment.Top) {
                SelectionContainer(Modifier.weight(1f)) {
                    Text(
                        it.token,
                        style = LocalTypography.current.bodySmall,
                        color = LocalContentColors.current.secondary
                    )
                }
                UiSetIconButton(
                    onClick = {
                        copySecret(app, "00Widget agent token", it.token)
                        copied = true
                        scope.launch {
                            delay(10_000)
                            copied = false
                        }
                    },
                    contentDescription = if (copied) "Agent token copied" else "Copy agent token"
                ) {
                    UiSetCopyIcon(copied)
                }
            }
        }
        UiSetSecondaryButton(
            if (busy) "Rotating…" else "Rotate agent token",
            onClick = { confirming = true },
            enabled = !busy
        )
    }

    if (confirming) {
        UiSetConfirmDialog(
            title = "Rotate the agent token?",
            text = "Every agent publishing with an old token stops until it gets the replacement.",
            confirmLabel = "Rotate",
            onConfirm = {
                confirming = false
                busy = true
                error = null
                scope.launch {
                    try {
                        val api = app.authedApi() ?: throw IllegalStateException("Not connected.")
                        rotated = api.rotateAgentToken()
                    } catch (e: Exception) {
                        error = (e.message ?: e.javaClass.simpleName).take(200)
                    } finally {
                        busy = false
                    }
                }
            },
            dismissLabel = "Cancel",
            onDismiss = { if (!busy) confirming = false },
            destructive = true,
            confirmEnabled = !busy
        )
    }
}
