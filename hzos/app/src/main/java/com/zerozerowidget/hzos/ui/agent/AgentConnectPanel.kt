package com.zerozerowidget.hzos.ui.agent

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.data.ConnectionStore
import com.zerozerowidget.hzos.data.MCPConnectionSummary
import com.zerozerowidget.hzos.data.ZeroWidgetApi
import com.zerozerowidget.hzos.data.describeBrowserApproval
import com.zerozerowidget.hzos.ui.PanelPrefs
import com.zerozerowidget.hzos.ui.cardAlphaState
import com.zerozerowidget.hzos.ui.cards.DeleteRow
import com.zerozerowidget.hzos.ui.cards.GlassCard
import com.zerozerowidget.hzos.ui.connectionState
import com.zerozerowidget.hzos.ui.openDeepLink
import com.zerozerowidget.hzos.ui.relativeTime
import com.zerozerowidget.hzos.ui.theme.spacing
import com.zerozerowidget.hzos.ui.uiset.UiSetCopyIcon
import com.zerozerowidget.hzos.ui.uiset.UiSetIconButton
import com.zerozerowidget.hzos.ui.uiset.UiSetPrimaryButton
import com.zerozerowidget.hzos.ui.uiset.UiSetSecondaryButton
import com.zerozerowidget.hzos.ui.uiset.UiSetTextField
import com.zerozerowidget.hzos.ui.uiset.uiSetAccent
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalColorScheme
import metavrx.uiset.compose.theme.LocalContentColors
import metavrx.uiset.compose.theme.LocalTypography

/**
 * "Connect an agent" guide, ported from iOS ConnectAgentGuideView: what a
 * connector is, the connected-agents list with disconnect, and per-client
 * setup (Claude, ChatGPT, Manus, OpenCode, Codex, other) with copyable
 * commands and the account's own MCP endpoint. Copy kept near-verbatim;
 * copy buttons replace the SF Symbols iOS uses.
 */
@Composable
fun AgentConnectPanel(app: ZeroZeroWidgetApp) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val connection by app.connectionStore.connectionState()
    val signedIn = connection.apiKey.isNotBlank()
    val cardAlpha by app.panelPrefs.cardAlphaState()
    var connections by remember { mutableStateOf<List<MCPConnectionSummary>>(emptyList()) }
    var connectionsError by remember { mutableStateOf<String?>(null) }
    var connectionsLoaded by remember { mutableStateOf(false) }
    var busyId by remember { mutableStateOf<String?>(null) }
    // DataStore hasn't emitted on first composition, so the collected
    // connection still holds the signed-out initial — and the signed-in
    // cards below would pop in a beat later, pushing the guides down.
    // Gate the whole screen on the first real emission (local disk, fast)
    // so the layout below renders once, in its final shape.
    var connectionKnown by remember { mutableStateOf(false) }

    suspend fun authedApi(): ZeroWidgetApi? = app.authedApi()

    suspend fun loadConnections() {
        val api = authedApi() ?: run {
            connections = emptyList()
            connectionsError = null
            connectionsLoaded = true
            return
        }
        try {
            connections = api.listMCPConnections()
            connectionsError = null
        } catch (e: Exception) {
            connectionsError = (e.message ?: e.javaClass.simpleName).take(200)
        } finally {
            connectionsLoaded = true
        }
    }

    LaunchedEffect(Unit) {
        app.connectionStore.connection.first()
        connectionKnown = true
    }
    LaunchedEffect(signedIn) {
        // A fresh account means a fresh list: loading, not the old rows.
        connectionsLoaded = false
        loadConnections()
    }
    // Returning from the browser (where connecting happens) reloads, like
    // iOS reloading on scene-phase active.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) scope.launch { loadConnections() }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }

    val baseUrl = ConnectionStore.effectiveBaseUrl(connection.baseUrl).orEmpty()
    val mcpEndpoint = baseUrl.ifBlank { null }?.trimEnd('/')?.plus("/mcp")

    if (!connectionKnown) {
        Column(
            Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(spacing.medium)
        ) {
            GlassCard(cardAlpha = cardAlpha) {
                Text(
                    "Loading…",
                    style = LocalTypography.current.body,
                    color = LocalContentColors.current.secondary
                )
            }
        }
        return
    }

    Column(
        Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        GlassCard(cardAlpha = cardAlpha) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.medium)) {
                Text(
                    "A connector lets an assistant publish cards and Live Activities on your behalf " +
                        "without you handing it a token. It asks for permission once, you approve it " +
                        "while signed in, and it is issued its own credential.",
                    style = LocalTypography.current.body,
                    color = LocalContentColors.current.secondary
                )
                if (!signedIn) {
                    Text(
                        "Sign in on the Connection panel first. Approving a connector needs an " +
                            "account that already exists — the permission screen cannot create one.",
                        style = LocalTypography.current.body
                    )
                }
            }
        }

        if (signedIn) {
            McpLoginSection(app = app)
        }

        // Directly after the login: what this account already granted.
        // Reviewing what is connected closes the login question before
        // the per-client guides begin.
        if (signedIn) {
            GlassCard(cardAlpha = cardAlpha) {
                Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                    Text("Connected agents", style = LocalTypography.current.title)
                    connectionsError?.let {
                        Text(it, style = LocalTypography.current.bodySmall, color = LocalColorScheme.current.negative.content)
                    }
                    // The list answers over the network: hold a Loading…
                    // row instead of flashing "No agents" before the rows
                    // arrive and shifting everything below.
                    if (!connectionsLoaded) {
                        Text(
                            "Loading…",
                            style = LocalTypography.current.body,
                            color = LocalContentColors.current.secondary
                        )
                    } else if (connections.isEmpty()) {
                        Text(
                            "No agents are currently connected.",
                            style = LocalTypography.current.body,
                            color = LocalContentColors.current.secondary
                        )
                    }
                    connections.forEach { item ->
                        ConnectionRow(
                            item = item,
                            busy = busyId == item.id,
                            onDisconnect = {
                                scope.launch {
                                    busyId = item.id
                                    try {
                                        authedApi()?.disconnectMCPConnection(item.id)
                                        connections = connections.filterNot { it.id == item.id }
                                    } catch (e: Exception) {
                                        connectionsError =
                                            (e.message ?: e.javaClass.simpleName).take(200)
                                    } finally {
                                        busyId = null
                                    }
                                }
                            }
                        )
                    }
                    Text(
                        "Disconnecting stops that agent's 00Widget access immediately. It may remain " +
                            "listed in that client until you remove it there.",
                        style = LocalTypography.current.bodySmall,
                        color = LocalContentColors.current.secondary
                    )
                }
            }
        }

        GuideSection(app = app, title = "Claude") {
            Step(1, "Tap Connect Claude below. It opens claude.ai with the connector details already filled in.")
            Step(2, "Sign in to claude.ai if it asks, then tap Add.")
            Step(3, "Approve the permission screen. It publishes to whichever 00Widget account you are signed in as there.")
            val claudeUrl = mcpEndpoint?.let(::claudeConnectorUrl)
            if (claudeUrl != null) {
                UiSetSecondaryButton("Connect Claude", onClick = { openDeepLink(context, claudeUrl) })
            }
            mcpEndpoint?.let { endpoint ->
                Text(
                    "Using Claude Code? Run this command, then open /mcp in Claude Code to complete OAuth.",
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary
                )
                CodeBlock(text = "claude mcp add --transport http 00widget $endpoint")
            }
            Text(
                "You only do this once. A connector belongs to your Claude account rather than to a " +
                    "device, so it is there afterwards wherever you use Claude.",
                style = LocalTypography.current.bodySmall,
                color = LocalContentColors.current.secondary
            )
        }

        GuideSection(app = app, title = "ChatGPT") {
            Step(1, "In ChatGPT on the web, enable Developer mode from Settings → Apps → Advanced settings, or your workspace's Apps settings.")
            Step(2, "Create a custom app and paste the MCP address below as the MCP server URL.")
            Step(3, "Connect it, then sign in to 00Widget and approve access.")
            LinkButton(context, "Developer mode and MCP apps in ChatGPT", "https://help.openai.com/en/articles/12584461-developer-mode-and-full-mcp-connectors-in-chatgpt")
            mcpEndpoint?.let { CodeBlock(text = it) }
        }

        GuideSection(app = app, title = "Manus") {
            Step(1, "In Manus, go to Settings → Integrations → Custom MCP Servers and select Add Server.")
            Step(2, "Name it 00Widget and enter the MCP address below as the server URL.")
            Step(3, "Test the connection, then complete the 00Widget sign-in when prompted.")
            LinkButton(context, "Manus custom MCP instructions", "https://manus.im/docs/integrations/custom-mcp")
            mcpEndpoint?.let { CodeBlock(text = it) }
        }

        GuideSection(app = app, title = "OpenCode") {
            Step(1, "Run this command once.")
            Step(2, "Approve the 00Widget sign-in in the browser window that opens.")
            mcpEndpoint?.let {
                CodeBlock(text = "opencode mcp add 00widget --url $it && opencode mcp auth 00widget")
            }
        }

        GuideSection(app = app, title = "Codex") {
            Step(1, "In the ChatGPT desktop app, open Settings → MCP Servers → Add server.")
            Step(2, "Name it 00Widget, choose Streamable HTTP, and enter the MCP address below.")
            Step(3, "Save, restart, then select Authenticate and approve access.")
            mcpEndpoint?.let { CodeBlock(text = it) }
            mcpEndpoint?.let {
                CodeBlock(text = "codex mcp add 00widget --url $it && codex mcp login 00widget")
            }
            LinkButton(context, "Codex MCP instructions", "https://learn.chatgpt.com/docs/extend/mcp?surface=cli")
        }

        GuideSection(app = app, title = "Other MCP client") {
            Step(1, "Add a custom or remote MCP server.")
            Step(2, "Choose Streamable HTTP and enter the MCP address below.")
            Step(3, "Save the server, then complete the 00Widget OAuth sign-in.")
            mcpEndpoint?.let { CodeBlock(text = it) }
            Text(
                "Works with MCP clients that support remote Streamable HTTP and OAuth.",
                style = LocalTypography.current.bodySmall,
                color = LocalContentColors.current.secondary
            )
            LinkButton(context, "Cursor", "https://cursor.com/docs/mcp")
            LinkButton(context, "VS Code", "https://code.visualstudio.com/docs/agent-customization/mcp-servers")
            LinkButton(context, "Gemini CLI", "https://google-gemini.github.io/gemini-cli/docs/tools/mcp-server.html")
        }
    }
}

/**
 * Approves an MCP login code shown by a client that cannot finish OAuth on
 * its own — no iPhone needed. Signed in only, answered on the app
 * credential: approving binds the pending login to this tenant, denying
 * kills it. Only ever approve a code shown on your own screen.
 */
@Composable
private fun McpLoginSection(app: ZeroZeroWidgetApp) {
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
                val api = app.authedApi() ?: throw IllegalStateException("Not connected.")
                val (status, body) = api.approveBrowserSignIn(
                    normalized,
                    if (approved) "approve" else "deny"
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

    val cardAlpha by app.panelPrefs.cardAlphaState()
    GlassCard(cardAlpha = cardAlpha) {
        Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
            Text("MCP login", style = LocalTypography.current.title)
            Text(
                "Connecting an assistant? It shows an 8-character code — " +
                    "approve it here and the login completes. Only approve " +
                    "a code shown on your own screen.",
                style = LocalTypography.current.bodySmall,
                color = LocalContentColors.current.secondary
            )
            UiSetTextField(
                value = code,
                label = "Code (XXXX-XXXX)",
                onValueChange = {
                    code = it
                    notice = null
                },
                modifier = Modifier.fillMaxWidth(),
                enabled = !busy
            )
            Row(horizontalArrangement = Arrangement.spacedBy(spacing.small)) {
                UiSetPrimaryButton(
                    "Approve",
                    onClick = { decide(true) },
                    enabled = !busy,
                    modifier = Modifier.weight(1f)
                )
                UiSetSecondaryButton(
                    "Deny",
                    onClick = { decide(false) },
                    enabled = !busy,
                    modifier = Modifier.weight(1f)
                )
            }
            notice?.let {
                Text(
                    it,
                    style = LocalTypography.current.bodySmall,
                    color = if (noticeError) {
                        LocalColorScheme.current.negative.content
                    } else {
                        uiSetAccent()
                    }
                )
            }
        }
    }
}

@Composable
private fun GuideSection(
    app: ZeroZeroWidgetApp,
    title: String,
    content: @Composable () -> Unit
) {
    val cardAlpha by app.panelPrefs.cardAlphaState()
    GlassCard(cardAlpha = cardAlpha) {
        Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
            Text(title, style = LocalTypography.current.title)
            content()
        }
    }
}

@Composable
private fun Step(number: Int, text: String) {
    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(spacing.medium)) {
        Box(
            Modifier.size(22.dp).background(uiSetAccent(), CircleShape),
            contentAlignment = Alignment.Center
        ) {
            Text(
                number.toString(),
                style = LocalTypography.current.caption,
                color = Color.White
            )
        }
        Text(
            text,
            style = LocalTypography.current.body,
            modifier = Modifier.weight(1f)
        )
    }
}

@Composable
private fun LinkButton(context: Context, label: String, url: String) {
    UiSetSecondaryButton(label, onClick = { openDeepLink(context, url) })
}

@Composable
private fun CodeBlock(text: String) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var copied by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(spacing.small)) {
        Text(
            text,
            style = LocalTypography.current.bodySmall.copy(fontFamily = FontFamily.Monospace),
            color = LocalContentColors.current.secondary,
            modifier = Modifier.weight(1f)
        )
        UiSetIconButtonCopy(copied = copied, onCopy = {
            val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText("00Widget MCP", text))
            copied = true
            scope.launch {
                delay(3000)
                copied = false
            }
        })
    }
}

@Composable
private fun UiSetIconButtonCopy(copied: Boolean, onCopy: () -> Unit) {
    UiSetIconButton(
        onClick = onCopy,
        contentDescription = if (copied) "Copied" else "Copy"
    ) {
        UiSetCopyIcon(copied)
    }
}

@Composable
private fun ConnectionRow(item: MCPConnectionSummary, busy: Boolean, onDisconnect: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(spacing.small)
    ) {
        Column(Modifier.weight(1f)) {
            Text(item.clientName, style = LocalTypography.current.body)
            Text(
                connectionSubtitle(item),
                style = LocalTypography.current.bodySmall,
                color = LocalContentColors.current.secondary
            )
        }
        DeleteRow(
            label = "Disconnect",
            busy = busy,
            error = null,
            onDelete = onDisconnect,
            confirmTitle = "Disconnect ${item.clientName}?",
            confirmText = "It stops publishing to 00Widget until it is connected again.",
            // Intrinsic, never fixed: the column takes the button's own
            // text width, so the label cannot wrap at any type size. A
            // fixed width squeezed the text column to nothing; wrap
            // alone let the inner row fill the parent and did the same.
            modifier = Modifier.width(IntrinsicSize.Max)
        )
    }
}

private fun connectionSubtitle(item: MCPConnectionSummary): String {
    val use = item.lastUsedAt?.let { relativeTime(it)?.let { r -> "Used $r" } } ?: "Never used"
    val access = if ("publish" in item.scopes) "Read and publish" else "Read only"
    return "$use · $access"
}

/** claude.ai prefill, escaping everything outside RFC 3986 unreserved. */
private fun claudeConnectorUrl(endpoint: String): String {
    val escaped = buildString {
        endpoint.toByteArray(Charsets.UTF_8).forEach { b ->
            val c = b.toInt().and(0xFF).toChar()
            if (c.isLetterOrDigit() || c in "-._~") {
                append(c)
            } else {
                append("%" + b.toInt().and(0xFF).toString(16).uppercase().padStart(2, '0'))
            }
        }
    }
    return "https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=00Widget&connectorUrl=$escaped"
}
