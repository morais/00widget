package com.example.zerozerowidget.hzos.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
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
import com.example.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.example.zerozerowidget.hzos.data.ConnectionStore
import com.example.zerozerowidget.hzos.ui.cards.GlassCard
import com.example.zerozerowidget.hzos.ui.openDeepLink
import com.example.zerozerowidget.hzos.data.DeviceAuthApi
import com.example.zerozerowidget.hzos.data.awaitDeviceToken
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

private enum class SignInPhase { IDLE, REQUESTING, WAITING }

/**
 * Connection panel. Manual Worker URL + API key entry — the placeholder until
 * real login lands (see ConnectionStore AUTH TODO and hzos/README.md).
 *
 * Paste a tenant API token with the `device` preset from the Worker's
 * `/admin` page (`read` + `actions:run`: dashboard reads and safe action
 * buttons, nothing else). A `publisher` token is wrong here — it 403s on
 * action runs and needlessly grants `publish` + `webhook:manage`. Save
 * validates the URL shape (https, http only for local hosts) and immediately
 * triggers a dashboard refresh so a typo shows up as an error, not silence.
 */
/**
 * Connection panel: sign in with the phone flow, sign out again. There is
 * deliberately no manual credential entry — the Worker URL lives on the
 * developer screen (Options · Developer, readonly when the build provides
 * one) and the API key arrives only through the device flow.
 */
@Composable
fun SettingsPanel(
    app: ZeroZeroWidgetApp,
    onClose: () -> Unit,
    onOpenOptions: () -> Unit,
    onOpenAgentConnect: () -> Unit,
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

    Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Settings", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
            IconButton(onClick = onClose) {
                Icon(Icons.Filled.Close, contentDescription = "Close")
            }
        }

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
                    Text("Signed in.", style = MaterialTheme.typography.bodyMedium)
                    Text(
                        connection.baseUrl.ifBlank {
                            com.example.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
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
        AgentConfigSection(onOpenAgentConnect = onOpenAgentConnect)
        Spacer(Modifier.height(4.dp))
        AboutSection(onOpenOptions = onOpenOptions)
    }
}

/**
 * About: version (tap → options), privacy, terms. URLs come from the
 * gitignored store config; a blank URL hides its row, so clones without
 * listing metadata show version alone.
 */
@Composable
private fun AboutSection(onOpenOptions: () -> Unit) {
    val context = LocalContext.current
    GlassCard(cardAlpha = 1f) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("About", style = MaterialTheme.typography.titleSmall)
            VersionRow(onOpenOptions = onOpenOptions)
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
 * Agent config entry: connectors for assistants plus the token path for
 * things you run yourself. The guide lives on its own panel; this is the
 * doorway, mirroring iOS Settings.
 */
@Composable
private fun AgentConfigSection(onOpenAgentConnect: () -> Unit) {
    GlassCard(cardAlpha = 1f) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Agent config", style = MaterialTheme.typography.titleSmall)
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
private fun VersionRow(onOpenOptions: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpenOptions),
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
                "(`platformAppId` in hzos/local.properties). Manual paste below.",
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
                                    "No Worker URL configured (Options · Developer).",
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
