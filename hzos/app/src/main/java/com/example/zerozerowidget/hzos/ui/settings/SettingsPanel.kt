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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
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
import com.example.zerozerowidget.hzos.auth.ensureMetaUserMatches
import com.example.zerozerowidget.hzos.data.ConnectionStore
import com.example.zerozerowidget.hzos.data.DeviceAuthApi
import com.example.zerozerowidget.hzos.data.DummyAccountData
import com.example.zerozerowidget.hzos.data.HorizonOutcome
import com.example.zerozerowidget.hzos.data.SubscriptionState
import com.example.zerozerowidget.hzos.data.ZeroWidgetApi
import com.example.zerozerowidget.hzos.data.awaitDeviceToken
import com.example.zerozerowidget.hzos.data.describeBrowserApproval
import com.example.zerozerowidget.hzos.data.horizonSignInBody
import com.example.zerozerowidget.hzos.data.runHorizonSignIn
import com.example.zerozerowidget.hzos.ui.agent.AgentConnectPanel
import com.example.zerozerowidget.hzos.ui.cards.GlassCard
import com.example.zerozerowidget.hzos.ui.openDeepLink
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private enum class HorizonPhase { IDLE, PROVING, CHOICE, WAITING }

private enum class SettingsDestination { ROOT, AGENT, DEVELOPER, SUBSCRIPTION }

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
    signInRequest: Int = 0,
    onSignInRequestConsumed: () -> Unit = {},
) {
    var destination by remember { mutableStateOf(SettingsDestination.ROOT) }
    val title = when (destination) {
        SettingsDestination.ROOT -> "Settings"
        SettingsDestination.AGENT -> "Connect an agent"
        SettingsDestination.DEVELOPER -> "Developer"
        SettingsDestination.SUBSCRIPTION -> "Subscription"
    }
    // A dashboard "Sign in" press lands here mid-flow: come back to the
    // root where the sign-in section lives, wherever the panel was left.
    LaunchedEffect(signInRequest) {
        if (signInRequest > 0) destination = SettingsDestination.ROOT
    }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
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
                onOpenSubscription = { destination = SettingsDestination.SUBSCRIPTION },
                onSendAuthUrl = onSendAuthUrl,
                signInRequest = signInRequest,
                onSignInRequestConsumed = onSignInRequestConsumed,
            )
            SettingsDestination.AGENT -> AgentConnectPanel(app = app)
            SettingsDestination.DEVELOPER -> DeveloperPanel(app = app)
            SettingsDestination.SUBSCRIPTION -> SubscriptionSection(app = app)
        }
    }
}

@Composable
private fun SettingsRoot(
    app: ZeroZeroWidgetApp,
    onOpenAgent: () -> Unit,
    onOpenDeveloper: () -> Unit,
    onOpenSubscription: () -> Unit,
    onSendAuthUrl: (authUrl: String, onSent: (Boolean) -> Unit) -> Unit,
    signInRequest: Int = 0,
    onSignInRequestConsumed: () -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val connection by app.connectionStore.connection.collectAsState(
        initial = ConnectionStore.Connection("", ""),
    )
    val signedIn = connection.apiKey.isNotBlank()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )

    // Same switch check as the dashboard foreground: opening Settings on a
    // switched account lands on sign-in instead of a stranger's session.
    LaunchedEffect(connection.apiKey) {
        ensureMetaUserMatches(app)
    }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        GlassCard(cardAlpha = cardAlpha) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                // Section title like every other card on this screen —
                // "Server", as on iOS.
                Text("Server", style = MaterialTheme.typography.titleSmall)
                if (!signedIn) {
                    HorizonSignInSection(
                        app = app,
                        onSendAuthUrl = onSendAuthUrl,
                        onSignedIn = { base, token, metaUserId ->
                            scope.launch {
                                app.connectionStore.save(base, token, metaUserId)
                                app.repository.refresh()
                            }
                        },
                        signInRequest = signInRequest,
                        onSignInRequestConsumed = onSignInRequestConsumed,
                    )
                } else {
                    AccountSection(
                        app = app,
                        // Purchase flow lives behind the build flag; without
                        // it the status row is display-only, as before.
                        onOpenSubscription = if (com.example.zerozerowidget.hzos.BuildConfig.SUBSCRIPTIONS_ENABLED) {
                            onOpenSubscription
                        } else {
                            null
                        },
                    )
                }

                if (signedIn) {
                    FilledTonalButton(
                        onClick = {
                            // Silent: the sign-in section replacing this
                            // button says everything about the new state.
                            scope.launch { app.connectionStore.clear() }
                        },
                    ) { Text("Sign out") }
                }
            }
        }

        Spacer(Modifier.height(4.dp))
        if (signedIn) {
            Spacer(Modifier.height(4.dp))
            BrowserApprovalSection(app = app)
        }
        AgentConfigSection(app = app, onOpenAgentConnect = onOpenAgent)
        Spacer(Modifier.height(4.dp))
        AboutSection(onOpenDeveloper = onOpenDeveloper)
    }
}

/**
 * Who this device is signed in as, asked live: a reinstall authenticates
 * with nothing cached to show, so the server is the source of truth.
 * Email like iOS, falling back to the account display name when there is
 * no email (Horizon-created tenants have none) — never the raw Meta id,
 * which is an opaque key, not a name. Plus the subscription status beside
 * it when the deployment sells any — with subscriptions off the server
 * answers 404 and the row stays away. The status row doubles as the
 * doorway to the purchase screen while a purchase flow is compiled in.
 * Anything failing degrades to the plain row.
 */
@Composable
private fun AccountSection(
    app: ZeroZeroWidgetApp,
    onOpenSubscription: (() -> Unit)? = null,
) {
    var accountName by remember { mutableStateOf<String?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var subscription by remember { mutableStateOf<SubscriptionState?>(null) }
    var subscriptionAnswered by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        try {
            val current = app.connectionStore.current()
            val base = current.baseUrl.ifBlank {
                com.example.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL
            }
            if (current.apiKey.isBlank() || base.isBlank()) return@LaunchedEffect
            val api = ZeroWidgetApi(app.http, base, current.apiKey)
            val account = api.fetchAccount()
            accountName = account.ownerEmail?.takeIf { it.isNotBlank() }
                ?: account.displayName?.takeIf { it.isNotBlank() }
            loaded = true
            subscription = api.fetchSubscription()
            subscriptionAnswered = true
        } catch (e: Exception) {
            loaded = true
            subscriptionAnswered = true
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            if (!loaded || accountName.isNullOrBlank()) {
                Text("Signed in.", style = MaterialTheme.typography.bodyMedium)
            } else {
                Text(
                    "Signed in as",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    accountName!!,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        if (subscriptionAnswered && subscription != null) {
            // Doorway to the purchase screen when the build sells anything,
            // a plain status row otherwise — like iOS, where Subscription
            // is a NavigationLink only with the flag on.
            val rowModifier = if (onOpenSubscription != null) {
                Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onOpenSubscription)
            } else {
                Modifier.fillMaxWidth()
            }
            Row(rowModifier, verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Subscription",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    subscription!!.displayLabel,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (subscription!!.needsAttention) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
                if (onOpenSubscription != null) {
                    Text(
                        ">",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 8.dp),
                    )
                }
            }
        }
    }
}

/**
 * Approves a browser asking to sign in as this account — the MCP path
 * without an iPhone. Signed in only, answered on the app credential. The
 * browser shows an 8-character code; approving binds its pending login to
 * this tenant, denying kills it. Only ever approve a code shown on your
 * own screen.
 */
@Composable
private fun BrowserApprovalSection(app: ZeroZeroWidgetApp) {
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }
    var noticeError by remember { mutableStateOf(false) }

    fun decide(approved: Boolean) {
        val normalized = code.trim()
        if (normalized.isBlank() || busy) return
        busy = true
        notice = null
        scope.launch {
            try {
                val current = app.connectionStore.current()
                val base = current.baseUrl.ifBlank {
                    com.example.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL
                }
                if (current.apiKey.isBlank() || base.isBlank()) {
                    throw IllegalStateException("Not connected.")
                }
                val api = ZeroWidgetApi(app.http, base, current.apiKey)
                val (status, body) = api.approveBrowserSignIn(
                    normalized,
                    if (approved) "approve" else "deny",
                )
                notice = describeBrowserApproval(status, body, approved)
                noticeError = status !in 200..299
                if (status in 200..299) code = ""
            } catch (e: Exception) {
                notice = (e.message ?: e.javaClass.simpleName).take(200)
                noticeError = true
            } finally {
                busy = false
            }
        }
    }

    GlassCard(cardAlpha = 1f) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Browser sign-in", style = MaterialTheme.typography.titleSmall)
            Text(
                "A browser asking to sign in as this account — for MCP use " +
                    "without an iPhone. Only approve a code shown on your own screen.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedTextField(
                value = code,
                onValueChange = { code = it; notice = null },
                label = { Text("Code (XXXX-XXXX)") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text),
                modifier = Modifier.fillMaxWidth(),
                enabled = !busy,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = { decide(true) },
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                ) { Text("Approve") }
                FilledTonalButton(
                    onClick = { decide(false) },
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                ) { Text("Deny") }
            }
            notice?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (noticeError) MaterialTheme.colorScheme.error
                    else MaterialTheme.colorScheme.primary,
                )
            }
        }
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
            // The token path and the connector doorway are the two ways in;
            // the rule keeps them from reading as one paragraph.
            HorizontalDivider()
            if (signedIn) {
                RotateAgentTokensSection(app = app)
                HorizontalDivider()
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

/**
 * Replaces the tokens the account's agents publish with. Logged-in only,
 * mirroring the rotation in iOS AccountExitView — but note what it is and
 * is not: it revokes `publisher`/`agent` purpose keys, never the token
 * shown above (this headset's own sign-in) and never connectors, so the
 * headset stays signed in and assistants stay connected. The replacement
 * is answered once, so it is shown here for handoff, not stored anywhere.
 */
@Composable
private fun RotateAgentTokensSection(app: ZeroZeroWidgetApp) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var confirming by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var rotated by remember { mutableStateOf<com.example.zerozerowidget.hzos.data.AgentTokenRotation?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var copied by remember { mutableStateOf(false) }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Agent tokens", style = MaterialTheme.typography.titleSmall)
        Text(
            "Use this if an agent token may have been exposed. Every old agent " +
                "token stops working and one replacement is created — give " +
                "it to your agents. This headset stays signed in; its own token " +
                "above is untouched.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        error?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }
        rotated?.let {
            Text(
                "Rotated — ${it.revokedAgentTokens} old token(s) revoked. " +
                    "Copy the replacement now; it is shown once.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary,
            )
            Row(verticalAlignment = Alignment.Top) {
                SelectionContainer(Modifier.weight(1f)) {
                    Text(
                        it.token,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                IconButton(
                    onClick = {
                        val clipboard =
                            context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(ClipData.newPlainText("00Widget agent token", it.token))
                        copied = true
                        scope.launch {
                            delay(10_000)
                            copied = false
                        }
                    },
                ) {
                    Icon(
                        if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy,
                        contentDescription = if (copied) "Agent token copied" else "Copy agent token",
                    )
                }
            }
        }
        FilledTonalButton(
            onClick = { confirming = true },
            enabled = !busy,
        ) { Text(if (busy) "Rotating…" else "Rotate agent token") }
    }

    if (confirming) {
        AlertDialog(
            onDismissRequest = { if (!busy) confirming = false },
            title = { Text("Rotate the agent token?") },
            text = {
                Text("Every agent publishing with an old token stops until it gets the replacement.")
            },
            confirmButton = {
                FilledTonalButton(
                    onClick = {
                        confirming = false
                        busy = true
                        error = null
                        scope.launch {
                            try {
                                val current = app.connectionStore.current()
                                val base = current.baseUrl.ifBlank {
                                    com.example.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL
                                }
                                val api = com.example.zerozerowidget.hzos.data.ZeroWidgetApi(
                                    app.http, base, current.apiKey,
                                )
                                rotated = api.rotateAgentToken()
                            } catch (e: Exception) {
                                error = (e.message ?: e.javaClass.simpleName).take(200)
                            } finally {
                                busy = false
                            }
                        }
                    },
                    enabled = !busy,
                ) { Text("Rotate") }
            },
            dismissButton = {
                FilledTonalButton(onClick = { confirming = false }) { Text("Cancel") }
            },
        )
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
                            app.connectionStore.save(normalized, current.apiKey, current.metaUserId)
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
 * Horizon sign-in: one button proving the headset's Meta identity to the
 * Worker (`POST /v1/auth/horizon`), then either done, an explicit
 * create/join choice, or iPhone approval polling for a join. Hands the
 * resulting token plus the Meta id it was issued for to [onSignedIn], so a
 * later account switch is detectable. Every failure names its cause; the
 * join fallback (manual code entry) doubles as the path where
 * `send_auth_url` is unavailable.
 */
@Composable
private fun HorizonSignInSection(
    app: ZeroZeroWidgetApp,
    onSendAuthUrl: (authUrl: String, onSent: (Boolean) -> Unit) -> Unit,
    onSignedIn: (baseUrl: String, token: String, metaUserId: String) -> Unit,
    signInRequest: Int = 0,
    onSignInRequestConsumed: () -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    var phase by remember { mutableStateOf(HorizonPhase.IDLE) }
    var userCode by remember { mutableStateOf("") }
    var verifyUri by remember { mutableStateOf("") }
    var linkSent by remember { mutableStateOf<Boolean?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var pollJob by remember { mutableStateOf<Job?>(null) }
    // The Meta id the in-flight attempt proved, saved with the token.
    // Retries re-prove (fresh proof, same user), so this trails the latest.
    var attemptUserId by remember { mutableStateOf("") }

    fun cancel() {
        pollJob?.cancel()
        pollJob = null
        phase = HorizonPhase.IDLE
    }

    suspend fun resolveBaseUrl(): String {
        // Server URL resolves here, not in a text field: saved value
        // first, build default second.
        val stored = app.connectionStore.current()
        val raw = stored.baseUrl.ifBlank {
            com.example.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL
        }
        return ConnectionStore.normalizeBaseUrl(raw)
            ?: throw IllegalArgumentException("No Worker URL configured (Developer screen).")
    }

    fun begin(choice: String?) {
        if (phase != HorizonPhase.IDLE && phase != HorizonPhase.CHOICE) return
        error = null
        phase = HorizonPhase.PROVING
        pollJob = scope.launch {
            try {
                val normalized = resolveBaseUrl()
                // Pre-credential: the key is unused, and the horizon call
                // sends no Authorization header at all.
                val unauthed = ZeroWidgetApi(app.http, normalized, "")
                when (
                    val outcome = runHorizonSignIn(
                        identity = { app.horizonAuth.getMetaIdentity() },
                        request = { userId, proof, ch ->
                            attemptUserId = userId
                            unauthed.postHorizonSignIn(horizonSignInBody(userId, proof, ch))
                        },
                        choice = choice,
                    )
                ) {
                    is HorizonOutcome.SignedIn -> {
                        onSignedIn(normalized, outcome.token, outcome.userId)
                        phase = HorizonPhase.IDLE
                    }
                    HorizonOutcome.NeedChoice -> phase = HorizonPhase.CHOICE
                    is HorizonOutcome.JoinCode -> {
                        val code = outcome.code
                        userCode = code.userCode
                        verifyUri = code.verificationUri
                        linkSent = null
                        phase = HorizonPhase.WAITING
                        onSendAuthUrl(code.completeUri) { sent -> linkSent = sent }
                        val deadline = System.currentTimeMillis() +
                            minOf(code.expiresInSeconds * 1000L, 600_000L)
                        val deviceApi = DeviceAuthApi(app.http, normalized)
                        val token = awaitDeviceToken(
                            deviceApi,
                            code.deviceCode,
                            code.intervalSeconds,
                            deadline,
                        )
                        onSignedIn(normalized, token, attemptUserId)
                        phase = HorizonPhase.IDLE
                    }
                    is HorizonOutcome.Failed -> {
                        error = outcome.message
                        phase = HorizonPhase.IDLE
                    }
                }
            } catch (e: CancellationException) {
                phase = HorizonPhase.IDLE
                throw e
            } catch (e: Exception) {
                android.util.Log.e(
                    "HorizonAuth",
                    "sign-in failed: ${e.javaClass.simpleName}: ${e.message}",
                )
                error = (e.message ?: e.javaClass.simpleName).take(200)
                phase = HorizonPhase.IDLE
            }
        }
    }

    if (!app.horizonAuth.isAvailable) {
        Text(
            "Sign-in needs a Horizon Platform app ID " +
                "(`platformAppId` in hzos/local.properties).",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        return
    }

    // A dashboard "Sign in" press opens this screen already asking: kick
    // the sign-in flow without waiting for another tap. Once per request —
    // after a cancel the button is the way back in.
    LaunchedEffect(signInRequest) {
        if (signInRequest > 0) {
            begin(null)
            onSignInRequestConsumed()
        }
    }

    when (phase) {
        HorizonPhase.IDLE -> {
            error?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            }
            Button(onClick = { begin(null) }) { Text("Sign in") }
        }
        HorizonPhase.PROVING -> {
            Text("Signing in…", style = MaterialTheme.typography.bodyMedium)
            FilledTonalButton(onClick = ::cancel) { Text("Cancel") }
        }
        HorizonPhase.CHOICE -> {
            // Said here rather than by choosing silently: a new account and
            // someone else's existing one are different tenants, and only
            // the operator knows which this headset should join.
            Text(
                "This headset isn't linked to an account yet.",
                style = MaterialTheme.typography.bodyMedium,
            )
            Button(
                onClick = { begin("create") },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Create a new account") }
            FilledTonalButton(
                onClick = { begin("join_apple") },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Join my iPhone account") }
            FilledTonalButton(onClick = ::cancel) { Text("Cancel") }
        }
        HorizonPhase.WAITING -> {
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
