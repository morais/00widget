package com.example.zerozerowidget.hzos.ui.agent

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
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
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.example.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.example.zerozerowidget.hzos.data.ConnectionStore
import com.example.zerozerowidget.hzos.data.MCPConnectionSummary
import com.example.zerozerowidget.hzos.data.ZeroWidgetApi
import com.example.zerozerowidget.hzos.data.describeBrowserApproval
import com.example.zerozerowidget.hzos.ui.cards.DeleteRow
import com.example.zerozerowidget.hzos.ui.cards.GlassCard
import com.example.zerozerowidget.hzos.ui.openDeepLink
import com.example.zerozerowidget.hzos.ui.relativeTime
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

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
    val connection by app.connectionStore.connection.collectAsState(
        initial = ConnectionStore.Connection("", ""),
    )
    val signedIn = connection.apiKey.isNotBlank()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsStateWithLifecycle(
        initialValue = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    var connections by remember { mutableStateOf<List<MCPConnectionSummary>>(emptyList()) }
    var connectionsError by remember { mutableStateOf<String?>(null) }
    var busyId by remember { mutableStateOf<String?>(null) }

    suspend fun authedApi(): ZeroWidgetApi? {
        val current = app.connectionStore.current()
        if (current.apiKey.isBlank()) return null
        val base = current.baseUrl.ifBlank {
            com.example.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL
        }
        if (base.isBlank()) return null
        return ZeroWidgetApi(app.http, base, current.apiKey)
    }

    suspend fun loadConnections() {
        val api = authedApi() ?: run {
            connections = emptyList()
            connectionsError = null
            return
        }
        try {
            connections = api.listMCPConnections()
            connectionsError = null
        } catch (e: Exception) {
            connectionsError = (e.message ?: e.javaClass.simpleName).take(200)
        }
    }

    LaunchedEffect(signedIn) { loadConnections() }
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

    val baseUrl = connection.baseUrl.ifBlank {
        com.example.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL
    }
    val mcpEndpoint = baseUrl.ifBlank { null }?.trimEnd('/')?.plus("/mcp")

    Column(
        Modifier
            .fillMaxWidth()
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("Connect an agent", style = MaterialTheme.typography.headlineSmall)
        GlassCard(cardAlpha = cardAlpha) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "A connector lets an assistant publish cards and Live Activities on your behalf " +
                        "without you handing it a token. It asks for permission once, you approve it " +
                        "while signed in, and it is issued its own credential.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (!signedIn) {
                    Text(
                        "Sign in on the Connection panel first. Approving a connector needs an " +
                            "account that already exists — the permission screen cannot create one.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }

        if (signedIn) {
            GlassCard(cardAlpha = cardAlpha) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Connected agents", style = MaterialTheme.typography.titleSmall)
                    connectionsError?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                    }
                    if (connections.isEmpty()) {
                        Text(
                            "No agents are currently connected.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
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
                            },
                        )
                    }
                    Text(
                        "Disconnecting stops that agent's 00Widget access immediately. It may remain " +
                            "listed in that client until you remove it there.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        if (signedIn) {
            McpLoginSection(app = app)
        }

        GuideSection(app = app, title = "Claude") {
            Step(1, "Tap Connect Claude below. It opens claude.ai with the connector details already filled in.")
            Step(2, "Sign in to claude.ai if it asks, then tap Add.")
            Step(3, "Approve the permission screen. It publishes to whichever 00Widget account you are signed in as there.")
            val claudeUrl = mcpEndpoint?.let(::claudeConnectorUrl)
            if (claudeUrl != null) {
                FilledTonalButton(onClick = { openDeepLink(context, claudeUrl) }) {
                    Text("Connect Claude")
                }
            }
            mcpEndpoint?.let { endpoint ->
                Text(
                    "Using Claude Code? Run this command, then open /mcp in Claude Code to complete OAuth.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                CodeBlock(text = "claude mcp add --transport http 00widget $endpoint")
            }
            Text(
                "You only do this once. A connector belongs to your Claude account rather than to a " +
                    "device, so it is there afterwards wherever you use Claude.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
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
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            LinkButton(context, "Cursor", "https://cursor.com/docs/mcp")
            LinkButton(context, "VS Code", "https://code.visualstudio.com/docs/agent-customization/mcp-servers")
            LinkButton(context, "Gemini CLI", "https://google-gemini.github.io/gemini-cli/docs/tools/mcp-server.html")
        }
    }
}

/**
 * Approves an MCP login code shown by a terminal client that cannot finish
 * OAuth on its own — no iPhone needed. Signed in only, answered on the app
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

    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    GlassCard(cardAlpha = cardAlpha) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("MCP login", style = MaterialTheme.typography.titleSmall)
            Text(
                "Connecting an assistant? It shows an 8-character code — " +
                    "approve it here and the login completes. Only approve " +
                    "a code shown on your own screen.",
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

@Composable
private fun GuideSection(
    app: ZeroZeroWidgetApp,
    title: String,
    content: @Composable () -> Unit,
) {
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    GlassCard(cardAlpha = cardAlpha) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            content()
        }
    }
}

@Composable
private fun Step(number: Int, text: String) {
    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(
            Modifier.size(22.dp).background(MaterialTheme.colorScheme.primary, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                number.toString(),
                style = MaterialTheme.typography.labelSmall,
                color = androidx.compose.ui.graphics.Color.White,
            )
        }
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun LinkButton(context: Context, label: String, url: String) {
    FilledTonalButton(onClick = { openDeepLink(context, url) }) {
        Text(label)
    }
}

@Composable
private fun CodeBlock(text: String) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var copied by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text,
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        IconButtonCopy(copied = copied, onCopy = {
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
private fun IconButtonCopy(copied: Boolean, onCopy: () -> Unit) {
    androidx.compose.material3.IconButton(onClick = onCopy) {
        Icon(
            if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy,
            contentDescription = if (copied) "Copied" else "Copy",
        )
    }
}

@Composable
private fun ConnectionRow(item: MCPConnectionSummary, busy: Boolean, onDisconnect: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(item.clientName, style = MaterialTheme.typography.bodyMedium)
            Text(
                connectionSubtitle(item),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        DeleteRow(
            label = "Disconnect",
            busy = busy,
            error = null,
            onDelete = onDisconnect,
            modifier = Modifier.width(110.dp),
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
            if (c.isLetterOrDigit() || c in "-._~") append(c)
            else append("%" + b.toInt().and(0xFF).toString(16).uppercase().padStart(2, '0'))
        }
    }
    return "https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=00Widget&connectorUrl=$escaped"
}
