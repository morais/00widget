package com.example.zerozerowidget.hzos.ui.settings

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.example.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.example.zerozerowidget.hzos.data.ConnectionStore
import com.example.zerozerowidget.hzos.data.DummyAccountData
import com.example.zerozerowidget.hzos.ui.agent.AgentConnectPanel
import com.example.zerozerowidget.hzos.ui.cards.GlassCard
import com.example.zerozerowidget.hzos.ui.openDeepLink
import com.example.zerozerowidget.hzos.data.DeviceAuthApi
import com.example.zerozerowidget.hzos.data.awaitDeviceToken
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private enum class SignInPhase { IDLE, REQUESTING, WAITING }

private enum class SettingsDestination { ROOT, AGENT, DEVELOPER }

/**
 * Settings is one panel with drill-in destinations, not separate shell
 * panels: the root (connection, agent doorway, about), the agent guide,
 * and the developer screen, with a back button between them.
 */
@Composable
fun SettingsPanel(
    app: ZeroZeroWidgetApp,
    onClose: () -> Unit,
    onSendAuthUrl: (authUrl: String, onSent: (Boolean) -> Unit) -> Unit,
) {
    var destination by remember { mutableStateOf(SettingsDestination.ROOT) }
    val title = when (destination) {
        SettingsDestination.ROOT -> "Settings"
        SettingsDestination.AGENT -> "Connect an agent"
        SettingsDestination.DEVELOPER -> "Developer"
    }

    Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            if (destination != SettingsDestination.ROOT) {
                FilledTonalButton(onClick = { destination = SettingsDestination.ROOT }) {
                    Text("Back")
                }
                Spacer(Modifier.width(8.dp))
            }
            Text(
                title,
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onClose) {
                Icon(Icons.Filled.Close, contentDescription = "Close")
            }
        }

        when (destination) {
            SettingsDestination.ROOT -> SettingsRoot(
                app = app,
                onOpenAgent = { destination = SettingsDestination.AGENT },
                onOpenDeveloper = { destination = SettingsDestination.DEVELOPER },
                onSendAuthUrl = onSendAuthUrl,
            )
            SettingsDestination.AGENT -> AgentConnectPanel(app = app)
            SettingsDestination.DEVELOPER -> DeveloperPanel(app = app)
        }
    }
}

@Composable
private fun SettingsRoot(
    app: ZeroZeroWidgetApp,
    onOpenAgent: () -> Unit,
    onOpenDeveloper: () -> Unit,
    onSendAuthUrl: (authUrl: String, onSent: (Boolean) -> Unit) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val connection by app.connectionStore.connection.collectAsState(
        initial = ConnectionStore.Connection("", ""),
    )
    val signedIn = connection.apiKey.isNotBlank()
    var message by remember { mutableStateOf<String?>(null) }
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        GlassCard(cardAlpha = cardAlpha) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (!signedIn) {
                    PhoneSignInSection(
                        app = app,
                        onSendAuthUrl = onSendAuthUrl,
                        onSignedIn = { base, token ->
                            scope.launch {
                                app.connectionStore.save(base, token)
                                app.repository.refresh()
                                message = "Connected — dashboard is refreshing."
                            }
                        },
                    )
                } else {
                    // Signed in is one row. The server address lives on the
                    // Developer screen; repeating it here buys nothing.
                    Text("Signed in.", style = MaterialTheme.typography.bodyMedium)
                }

                message?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (it.startsWith("Connected") || it.startsWith("Signed"))
                            MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.error,
                    )
                }

                if (signedIn) {
                    FilledTonalButton(
                        onClick = {
                            scope.launch {
                                app.connectionStore.clear()
                                message = "Signed out. Panels show the not-connected state."
                            }
                        },
                    ) { Text("Sign out") }
                }
            }
        }

        Spacer(Modifier.height(4.dp))
        AgentConfigSection(app = app, onOpenAgentConnect = onOpenAgent)
        Spacer(Modifier.height(4.dp))
        AboutSection(onOpenDeveloper = onOpenDeveloper)
    }
}

/**
 * About: version (tap → developer), privacy, terms. URLs come from the
 * gitignored store config; a blank URL hides its row, so clones without
 * listing metadata show version alone.
 */
@Composable
private fun AboutSection(onOpenDeveloper: () -> Unit) {
    val context = LocalContext.current
    GlassCard(cardAlpha = 1f) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("About", style = MaterialTheme.typography.titleSmall)
            VersionRow(onOpenDeveloper = onOpenDeveloper)
            val privacy = com.example.zerozerowidget.hzos.BuildConfig.PRIVACY_URL
            if (privacy.isNotBlank()) {
                LinkRow(label = "Privacy policy") { openDeepLink(context, privacy) }
            }
            val terms = com.example.zerozerowidget.hzos.BuildConfig.TERMS_URL
            if (terms.isNotBlank()) {
                LinkRow(label = "Terms of service") { openDeepLink(context, terms) }
            }
        }
    }
}

@Composable
private fun LinkRow(label: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        Text(
            ">",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

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
private fun AgentConfigSection(app: ZeroZeroWidgetApp, onOpenAgentConnect: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val connection by app.connectionStore.connection.collectAsState(
        initial = ConnectionStore.Connection("", ""),
    )
    val showDummy by app.panelPrefs.showDummyAccountData.collectAsState(initial = false)
    var copied by remember { mutableStateOf(false) }
    val baseUrl = connection.baseUrl.ifBlank {
        com.example.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL
    }
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

    GlassCard(cardAlpha = 1f) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Agent config", style = MaterialTheme.typography.titleSmall)
            Row(verticalAlignment = Alignment.Top) {
                SelectionContainer(Modifier.weight(1f)) {
                    Text(
                        agentConfig,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                IconButton(
                    onClick = {
                        val clipboard =
                            context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(ClipData.newPlainText("00Widget agent config", agentConfig))
                        copied = true
                        scope.launch {
                            // Acknowledgement of the tap, not a running
                            // clipboard status — matches iOS (10s there).
                            // Unlike iOS there is no pasteboard expiry here,
                            // so the row promises nothing about clearing.
                            delay(10_000)
                            copied = false
                        }
                    },
                ) {
                    Icon(
                        if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy,
                        contentDescription = if (copied) "Agent config copied" else "Copy agent config",
                    )
                }
            }
            if (copied) {
                Text(
                    "Copied",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
            Text(
                "Connect assistants (Claude, ChatGPT, OpenCode…) without handing them a token.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            FilledTonalButton(onClick = onOpenAgentConnect) { Text("Connect an agent") }
        }
    }
}

@Composable
private fun VersionRow(onOpenDeveloper: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpenDeveloper),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "Version ${com.example.zerozerowidget.hzos.BuildConfig.VERSION_NAME} " +
                "(${com.example.zerozerowidget.hzos.BuildConfig.VERSION_CODE})",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        Text(
            ">",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * Developer destination: Worker URL, sample-indicator visibility, and panel
 * look. No "provided by the build" note — a readonly field already says
 * it can't be changed.
 */
@Composable
private fun DeveloperPanel(app: ZeroZeroWidgetApp) {
    val scope = rememberCoroutineScope()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    val transparent by app.panelPrefs.transparent.collectAsState(initial = true)
    val hideIndicators by app.panelPrefs.hideSampleIndicators.collectAsState(initial = false)
    val showDummyAccountData by app.panelPrefs.showDummyAccountData.collectAsState(initial = false)
    var sliderAlpha by remember(cardAlpha) { mutableStateOf(cardAlpha) }
    val locked = com.example.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL.isNotBlank()
    var serverUrl by remember { mutableStateOf("") }
    var savedNote by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        serverUrl = app.connectionStore.current().baseUrl
    }

    GlassCard(cardAlpha = cardAlpha) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Server", style = MaterialTheme.typography.titleSmall)
            OutlinedTextField(
                value = if (locked) {
                    com.example.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL
                } else {
                    serverUrl
                },
                onValueChange = { serverUrl = it; savedNote = null },
                label = { Text("Worker URL (https://…)") },
                singleLine = true,
                readOnly = locked,
                enabled = !locked,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )
            if (!locked) {
                savedNote?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
                Button(
                    onClick = {
                        scope.launch {
                            val normalized = ConnectionStore.normalizeBaseUrl(serverUrl)
                            if (normalized == null) {
                                savedNote = "URL must be https (http only for localhost)."
                                return@launch
                            }
                            val current = app.connectionStore.current()
                            app.connectionStore.save(normalized, current.apiKey)
                            app.repository.refresh()
                            savedNote = "Saved — dashboard is refreshing."
                        }
                    },
                ) { Text("Save server") }
            }
            Text("Screenshots and recordings", style = MaterialTheme.typography.titleSmall)
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Show dummy account data", style = MaterialTheme.typography.bodyMedium)
                    Text(
                        "A visibly fake token on the Settings screen instead of your own.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = showDummyAccountData,
                    onCheckedChange = { checked ->
                        scope.launch { app.panelPrefs.setShowDummyAccountData(checked) }
                    },
                )
            }
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Hide sample indicators", style = MaterialTheme.typography.bodyMedium)
                    Text(
                        "Demo data stays; badges and notice go away.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = hideIndicators,
                    onCheckedChange = { checked ->
                        scope.launch { app.panelPrefs.setHideSampleIndicators(checked) }
                    },
                )
            }
            Text(
                "Dummy account data shows a visibly fake token in Agent config instead of " +
                    "your own. The real token still authorizes every request, and Copy " +
                    "agent config copies what is on screen — so turn this off before " +
                    "handing the token to an agent.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text("Look", style = MaterialTheme.typography.titleSmall)
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Transparent panels", style = MaterialTheme.typography.bodyMedium)
                    Text(
                        "Passthrough shows through the window; cards stay solid.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = transparent,
                    onCheckedChange = { checked ->
                        scope.launch { app.panelPrefs.setTransparent(checked) }
                    },
                )
            }
            Column(Modifier.fillMaxWidth()) {
                Text("Card opacity", style = MaterialTheme.typography.bodyMedium)
                Text(
                    "How solid cards are over passthrough: ${(sliderAlpha * 100).toInt()}%.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Slider(
                value = sliderAlpha,
                onValueChange = { sliderAlpha = it },
                onValueChangeFinished = {
                    scope.launch { app.panelPrefs.setCardAlpha(sliderAlpha) }
                },
                valueRange = 0.5f..1f,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/**
 * Phone sign-in via the Horizon Login API (`send_auth_url`) + Worker device
 * flow. Requests a code, pushes the approval URL to the Horizon mobile app,
 * polls until approved, and hands the resulting token to [onSignedIn].
 * Every failure — no app ID, no Platform SDK, declined dialog, server
 * without the device flow — degrades to the manual code display below,
 * which is also the required fallback on older Horizon OS versions.
 */
@Composable
private fun PhoneSignInSection(
    app: ZeroZeroWidgetApp,
    onSendAuthUrl: (authUrl: String, onSent: (Boolean) -> Unit) -> Unit,
    onSignedIn: (baseUrl: String, token: String) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var phase by remember { mutableStateOf(SignInPhase.IDLE) }
    var userCode by remember { mutableStateOf("") }
    var verifyUri by remember { mutableStateOf("") }
    var linkSent by remember { mutableStateOf<Boolean?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var pollJob by remember { mutableStateOf<Job?>(null) }

    fun cancel() {
        pollJob?.cancel()
        pollJob = null
        phase = SignInPhase.IDLE
    }

    if (!app.horizonAuth.isAvailable) {
        Text(
            "Phone sign-in needs a Horizon Platform app ID " +
                "(`platformAppId` in hzos/local.properties).",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        return
    }

    when (phase) {
        SignInPhase.IDLE -> {
            error?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            }
            Button(
                onClick = {
                    error = null
                    phase = SignInPhase.REQUESTING
                    pollJob = scope.launch {
                        try {
                            // Server URL resolves here, not in a text field:
                            // saved value first, build default second.
                            val stored = app.connectionStore.current()
                            val raw = stored.baseUrl.ifBlank {
                                com.example.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL
                            }
                            val normalized = ConnectionStore.normalizeBaseUrl(raw)
                                ?: throw IllegalArgumentException(
                                    "No Worker URL configured (Developer screen).",
                                )
                            val api = DeviceAuthApi(app.http, normalized)
                            val code = api.requestCode()
                            userCode = code.userCode
                            verifyUri = code.verificationUri
                            linkSent = null
                            phase = SignInPhase.WAITING
                            onSendAuthUrl(code.completeUri) { sent -> linkSent = sent }
                            val deadline = System.currentTimeMillis() +
                                minOf(code.expiresInSeconds * 1000L, 600_000L)
                            val token = awaitDeviceToken(api, code.deviceCode, code.intervalSeconds, deadline)
                            onSignedIn(normalized, token)
                            phase = SignInPhase.IDLE
                        } catch (e: CancellationException) {
                            phase = SignInPhase.IDLE
                            throw e
                        } catch (e: Exception) {
                            android.util.Log.e(
                                "HorizonAuth",
                                "device flow failed: ${e.javaClass.simpleName}: ${e.message}",
                            )
                            error = (e.message ?: e.javaClass.simpleName).take(200)
                            phase = SignInPhase.IDLE
                        }
                    }
                },
            ) { Text("Sign in with phone") }
        }
        SignInPhase.REQUESTING -> {
            Text("Requesting a sign-in code…", style = MaterialTheme.typography.bodyMedium)
            FilledTonalButton(onClick = ::cancel) { Text("Cancel") }
        }
        SignInPhase.WAITING -> {
            Text("Approve on your phone", style = MaterialTheme.typography.titleSmall)
            Text(
                userCode,
                style = MaterialTheme.typography.headlineMedium,
                color = MaterialTheme.colorScheme.primary,
            )
            Text(
                when (linkSent) {
                    null -> "Sending to your phone…"
                    true -> "Approval sent to your Horizon mobile app — tap the notification."
                    false -> "Phone request wasn't sent — enter the code manually below."
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (linkSent != true) {
                Text(verifyUri, style = MaterialTheme.typography.bodySmall)
            }
            Text("Waiting for approval…", style = MaterialTheme.typography.bodyMedium)
            FilledTonalButton(onClick = ::cancel) { Text("Cancel") }
        }
    }
}
