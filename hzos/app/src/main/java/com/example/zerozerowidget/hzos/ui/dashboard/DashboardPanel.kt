package com.example.zerozerowidget.hzos.ui.dashboard

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.example.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.example.zerozerowidget.hzos.data.DashboardCard
import com.example.zerozerowidget.hzos.ui.cards.ActionButtons
import com.example.zerozerowidget.hzos.ui.cards.CardHeadline
import com.example.zerozerowidget.hzos.ui.cards.CardTemplateBody
import com.example.zerozerowidget.hzos.ui.cards.DetailCard
import com.example.zerozerowidget.hzos.ui.isStale
import com.example.zerozerowidget.hzos.ui.openDeepLink
import com.example.zerozerowidget.hzos.ui.relativeTime
import kotlinx.coroutines.launch

/**
 * Main dashboard panel: card list + inline expansion + pop-out. Tapping a
 * card expands it in place; "Pop out" opens it in its own shell panel (a
 * separate activity instance — pop out twice and you get two panels).
 */
@Composable
fun DashboardPanel(
    app: ZeroZeroWidgetApp,
    onOpenActivities: () -> Unit,
    onOpenSettings: () -> Unit,
    onPopOut: (cardId: String) -> Unit,
) {
    val context = LocalContext.current
    val state by app.repository.state.collectAsStateWithLifecycle()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    var selectedId by remember { mutableStateOf<String?>(null) }
    var runningId by remember { mutableStateOf<String?>(null) }
    var runError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize().padding(20.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Dashboard", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
            state.lastSyncEpochMs?.let {
                Text(
                    "synced ${relativeTime(java.time.Instant.ofEpochMilli(it).toString()) ?: ""}",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            IconButton(onClick = { app.repository.refresh() }) { Text("Refresh", style = MaterialTheme.typography.labelLarge) }
            TextButton(onClick = onOpenActivities) { Text("Activities") }
            TextButton(onClick = onOpenSettings) { Text("Settings") }
        }

        when {
            !state.isConfigured -> {
                Text(
                    "Not connected. Open the Connection panel (⚙) and enter your Worker URL + API key.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(8.dp))
                Button(onClick = onOpenSettings) { Text("Open Connection") }
            }
            state.error != null && state.cards.isEmpty() -> {
                Text(state.error!!, color = MaterialTheme.colorScheme.error)
                Spacer(Modifier.height(8.dp))
                Button(onClick = { app.repository.refresh() }) { Text("Retry") }
            }
            else -> {
                state.error?.let {
                    Text(it, color = MaterialTheme.colorScheme.error, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(state.cards, key = { it.id }) { card ->
                        DashboardRow(
                            card = card,
                            cardAlpha = cardAlpha,
                            expanded = selectedId == card.id,
                            onToggle = { selectedId = if (selectedId == card.id) null else card.id },
                            onPopOut = { onPopOut(card.id) },
                            onOpenLink = { openDeepLink(context, card.deepLink) },
                            actionSlot = {
                                ActionButtons(
                                    card = card,
                                    runningId = runningId,
                                    runError = if (runningId != null) null else runError,
                                    onRun = { action ->
                                        scope.launch {
                                            runningId = action.id
                                            runError = null
                                            val result = app.repository.runAction(action.id, card.id)
                                            runningId = null
                                            runError = result.exceptionOrNull()?.message?.take(200)
                                        }
                                    },
                                )
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun DashboardRow(
    card: DashboardCard,
    cardAlpha: Float,
    expanded: Boolean,
    onToggle: () -> Unit,
    onPopOut: () -> Unit,
    onOpenLink: () -> Unit,
    actionSlot: @Composable () -> Unit,
) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = cardAlpha),
            // Explicit: an alpha-modified container no longer matches any
            // theme color, so contentColorFor() can't derive this and text
            // falls back to ambient black. See ChartColors.kt note.
            contentColor = MaterialTheme.colorScheme.onSurface,
        ),
        modifier = Modifier.fillMaxWidth().clickable(onClick = onToggle),
    ) {
        Column(Modifier.padding(14.dp)) {
            CardHeadline(card)
            card.subtitle?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (isStale(card.updatedAt, card.staleAfter)) {
                Text("stale", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error)
            }
            if (expanded) {
                Spacer(Modifier.height(8.dp))
                CardTemplateBody(card)
                actionSlot()
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = onPopOut) { Text("Pop out panel") }
                    card.deepLink?.let {
                        OutlinedButton(onClick = onOpenLink) { Text("Open link") }
                    }
                }
            }
        }
    }
}

/**
 * Single-card detail surface, hosted by CardDetailActivity — one activity
 * instance per popped-out card, i.e. one shell panel per card.
 */
@Composable
fun CardDetailPanel(
    app: ZeroZeroWidgetApp,
    cardId: String,
    onClose: () -> Unit,
    onOpenLink: (String?) -> Unit,
) {
    val state by app.repository.state.collectAsStateWithLifecycle()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    var runningId by remember { mutableStateOf<String?>(null) }
    var runError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val card = state.cards.firstOrNull { it.id == cardId }

    Column(Modifier.fillMaxSize().padding(20.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                card?.title ?: "Card",
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            TextButton(onClick = onClose) { Text("Close") }
        }
        Spacer(Modifier.height(8.dp))
        if (card == null) {
            Text(
                "This card is no longer on the dashboard. Close this panel.",
                style = MaterialTheme.typography.bodyMedium,
            )
        } else {
            DetailCard(card, cardAlpha)
            Spacer(Modifier.height(10.dp))
            ActionButtons(
                card = card,
                runningId = runningId,
                runError = runError,
                onRun = { action ->
                    scope.launch {
                        runningId = action.id
                        runError = null
                        val result = app.repository.runAction(action.id, card.id)
                        runningId = null
                        runError = result.exceptionOrNull()?.message?.take(200)
                    }
                },
            )
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                card.deepLink?.let {
                    OutlinedButton(onClick = { onOpenLink(card.deepLink) }) { Text("Open link") }
                }
                OutlinedButton(onClick = { app.repository.refresh() }) { Text("Refresh") }
            }
            card.deadline?.let { deadline ->
                Spacer(Modifier.height(6.dp))
                Text(
                    "Due ${relativeTime(deadline) ?: deadline}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
