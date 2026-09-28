package com.zerozerowidget.hzos.ui.dashboard

import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.data.DashboardCard
import com.zerozerowidget.hzos.data.LiveActivitySession
import com.zerozerowidget.hzos.data.SampleData
import com.zerozerowidget.hzos.data.isSample
import com.zerozerowidget.hzos.ui.cards.ActionButtons
import com.zerozerowidget.hzos.ui.cards.CardHeadline
import com.zerozerowidget.hzos.ui.cards.CardTemplateBody
import com.zerozerowidget.hzos.ui.cards.DeleteButton
import com.zerozerowidget.hzos.ui.cards.DetailCard
import com.zerozerowidget.hzos.ui.cards.LinkIconButton
import com.zerozerowidget.hzos.ui.cards.PopOutIconButton
import com.zerozerowidget.hzos.ui.cards.ProgressBar
import com.zerozerowidget.hzos.ui.cards.SampleBadge
import com.zerozerowidget.hzos.ui.cards.SampleNoticeBanner
import com.zerozerowidget.hzos.ui.describeDeleteError
import com.zerozerowidget.hzos.ui.describeRunError
import com.zerozerowidget.hzos.ui.cards.Sparkline
import com.zerozerowidget.hzos.ui.cards.StatusDot
import com.zerozerowidget.hzos.ui.cards.activityTint
import com.zerozerowidget.hzos.ui.isStale
import com.zerozerowidget.hzos.ui.openDeepLink
import com.zerozerowidget.hzos.ui.openSettingsPanelAndSignIn
import com.zerozerowidget.hzos.ui.relativeTime
import com.zerozerowidget.hzos.ui.uiset.UiSetIconButton
import com.zerozerowidget.hzos.ui.uiset.UiSetPrimaryButton
import com.zerozerowidget.hzos.ui.uiset.UiSetSecondaryButton
import com.zerozerowidget.hzos.ui.uiset.uiSetAccent
import kotlinx.coroutines.launch
import metavrx.uiset.compose.Icon
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalColorScheme
import metavrx.uiset.compose.theme.LocalContentColors
import com.zerozerowidget.hzos.ui.theme.panelBackground
import metavrx.uiset.compose.theme.LocalTypography
import metavrx.uiset.compose.theme.icons.Icons

/**
 * Main dashboard panel, mirroring the Apple TV layout: an "Ongoing
 * Activities" section above the "Widgets" grid, one scroll. Tapping a card
 * expands it in place; "Pop out" opens it in its own shell panel (a
 * separate activity instance — pop out twice and you get two panels).
 */
@Composable
fun DashboardPanel(
    app: ZeroZeroWidgetApp,
    onOpenSettings: () -> Unit,
    onPopOut: (cardId: String) -> Unit,
    onPopOutActivity: (externalActivityId: String) -> Unit,
) {
    val context = LocalContext.current
    val state by app.repository.state.collectAsStateWithLifecycle()
    val samples by app.sampleStore.cards.collectAsState()
    val sampleActivities by app.sampleStore.activities.collectAsState()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    val hideIndicators by app.panelPrefs.hideSampleIndicators.collectAsState(initial = false)
    var selectedId by remember { mutableStateOf<String?>(null) }
    var runningId by remember { mutableStateOf<String?>(null) }
    var runError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize().panelBackground().padding(20.dp)) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                "Dashboard",
                style = LocalTypography.current.headline,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            state.lastSyncEpochMs?.let {
                Text(
                    "synced ${relativeTime(java.time.Instant.ofEpochMilli(it).toString()) ?: ""}",
                    style = LocalTypography.current.caption,
                    color = LocalContentColors.current.secondary,
                    modifier = Modifier.padding(end = 4.dp),
                )
            }
            // Refresh only signs in states: logged out there is nothing to
            // refetch, and the button suggests otherwise.
            if (state.isConfigured) {
                UiSetIconButton(onClick = { app.repository.refresh() }, contentDescription = "Refresh") {
                    Icon(Icons.Regular.Refresh, contentDescription = null)
                }
            }
            UiSetIconButton(onClick = onOpenSettings, contentDescription = "Settings") {
                Icon(Icons.Regular.Settings, contentDescription = null)
            }
        }
        androidx.compose.runtime.CompositionLocalProvider(
            com.zerozerowidget.hzos.ui.LocalHideSampleIndicators provides hideIndicators,
        ) {
        if ((samples.isNotEmpty() || sampleActivities.isNotEmpty()) && !hideIndicators) {
            SampleNoticeBanner(onRemoveAll = { app.sampleStore.clearSamples() })
            Spacer(Modifier.height(4.dp))
        }

        // Server cards first, local samples after — never mixed, never sent.
        val visible = state.cards + samples
        val visibleActivities = state.activities + sampleActivities
        val nothingToShow = visible.isEmpty() && visibleActivities.isEmpty()
        when {
            !state.isConfigured && nothingToShow -> {
                WelcomePanel(
                    onSignIn = { context.openSettingsPanelAndSignIn() },
                    onTryDemo = { app.sampleStore.generateCards() },
                )
            }
            state.error != null && nothingToShow -> {
                Text(state.error!!, color = LocalColorScheme.current.negative.content)
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    UiSetPrimaryButton("Retry", onClick = { app.repository.refresh() })
                    UiSetSecondaryButton("Generate samples", onClick = { app.sampleStore.generateCards() })
                }
            }
            nothingToShow -> {
                WelcomePanel(
                    onSignIn = null,
                    onTryDemo = { app.sampleStore.generateCards() },
                )
            }
            else -> {
                state.error?.let {
                    Text(it, color = LocalColorScheme.current.negative.content, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                val cardRow: @Composable (DashboardCard) -> Unit = { card ->
                    val isSample = card.isSample()
                    DashboardRow(
                        card = card,
                        cardAlpha = cardAlpha,
                        isSample = isSample,
                        expanded = selectedId == card.id,
                        onToggle = { selectedId = if (selectedId == card.id) null else card.id },
                        onPopOut = { onPopOut(card.id) },
                        onOpenLink = { openDeepLink(context, card.deepLink) },
                            actionSlot = {
                                // Sample cards are local demos: their buttons
                                // address nothing, so they don't run — but
                                // only say so when buttons exist at all. With
                                // indicators hidden the card plays real: real
                                // buttons that fail honestly server-side.
                                if (isSample && !hideIndicators) {
                                    if (!card.actions.isNullOrEmpty()) {
                                        Text(
                                            "Demo card — buttons don't run on samples.",
                                            style = LocalTypography.current.bodySmall,
                                            color = LocalContentColors.current.secondary,
                                        )
                                    }
                                } else {
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
                                            runError = result.exceptionOrNull()?.let(::describeRunError)
                                        }
                                    },
                                )
                            }
                        },
                    )
                }
                // Width-driven columns, mirroring iOS DashboardView: one
                // column below 728dp, exactly two above — never three. iOS
                // counts a Duo hinge as a column boundary; Quest has no
                // hinge, so the width rule is the whole story. One scroll
                // for both sections: the grid is chunked into rows because
                // a lazy grid cannot live inside a lazy list.
                BoxWithConstraints(Modifier.fillMaxWidth().weight(1f)) {
                    val twoCol = maxWidth >= 728.dp
                    val listState = rememberLazyListState()
                    // Row keys change shape across the breakpoint (row ids
                    // vs card ids), and a retained scroll index can point
                    // past the new list and show blank. Reset on crossing
                    // rather than risking an empty window after a resize.
                    LaunchedEffect(twoCol) {
                        listState.scrollToItem(0)
                    }
                    LazyColumn(
                        state = listState,
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        // Bottom breathing room: without it the last card
                        // ends flush against the window edge when the list
                        // is scrolled to the end.
                        contentPadding = PaddingValues(bottom = 10.dp),
                    ) {
                        if (visibleActivities.isNotEmpty()) {
                            item(key = "activities-title") {
                                SectionTitle("Ongoing Activities")
                            }
                            items(
                                visibleActivities,
                                key = { "act-" + it.externalActivityId },
                            ) { session ->
                                ActivityRow(
                                    session = session,
                                    cardAlpha = cardAlpha,
                                    onPopOut = { onPopOutActivity(session.externalActivityId) },
                                    onOpenDetail = { onPopOutActivity(session.externalActivityId) },
                                )
                            }
                        }
                        item(key = "widgets-title") {
                            SectionTitle("Widgets")
                        }
                        if (visible.isEmpty()) {
                            // No widgets: like the activities section, the
                            // Widgets section becomes its own demo picker.
                            item(key = "demo-widgets") {
                                UiSetSecondaryButton(
                                    "Generate samples",
                                    onClick = { app.sampleStore.generateCards() },
                                )
                            }
                        } else if (twoCol) {
                                items(
                                    visible.chunked(2),
                                    key = { row -> "row-" + row.first().id },
                                ) { row ->
                                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                        Box(Modifier.weight(1f)) { cardRow(row[0]) }
                                        if (row.size > 1) {
                                            Box(Modifier.weight(1f)) { cardRow(row[1]) }
                                        } else {
                                            Spacer(Modifier.weight(1f))
                                        }
                                    }
                                }
                            } else {
                                items(visible, key = { it.id }) { card -> cardRow(card) }
                            }
                    }
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
    isSample: Boolean,
    expanded: Boolean,
    onToggle: () -> Unit,
    onPopOut: () -> Unit,
    onOpenLink: () -> Unit,
    actionSlot: @Composable () -> Unit,
) {
    // Overlay badge, not layout: the Box is exactly the card's size and the
    // pill draws over the bottom-right corner without moving anything.
    Box(Modifier.fillMaxWidth()) {
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
            Row(verticalAlignment = Alignment.CenterVertically) {
                CardHeadline(card, Modifier.weight(1f))
                card.deepLink?.let {
                    LinkIconButton(onOpenLink = onOpenLink)
                }
                PopOutIconButton(onPopOut)
            }
            card.subtitle?.let {
                Text(
                    it,
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (isStale(card.updatedAt, card.staleAfter)) {
                Text("stale", style = LocalTypography.current.caption, color = LocalColorScheme.current.negative.content)
            }
            if (expanded) {
                Spacer(Modifier.height(8.dp))
                CardTemplateBody(card)
                actionSlot()
            }
        }
        }
        if (isSample) {
            SampleBadge(
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(8.dp),
            )
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
    onOpenLink: (String?) -> Unit,
    onDeleted: () -> Unit,
) {
    val state by app.repository.state.collectAsStateWithLifecycle()
    val samples by app.sampleStore.cards.collectAsState()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    val hideIndicators by app.panelPrefs.hideSampleIndicators.collectAsState(initial = false)
    var runningId by remember { mutableStateOf<String?>(null) }
    var runError by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf(false) }
    var deleteError by remember { mutableStateOf<String?>(null) }
    var deleteArmed by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val card = state.cards.firstOrNull { it.id == cardId }
        ?: samples.firstOrNull { it.id == cardId }
    val isSample = card?.isSample() == true

    // Shell panels have one fixed window height each; tall content (long
    // briefings, full item lists, inspection panels) scrolls inside it.
    // The OS cannot size a panel to its content, so scroll is the whole
    // answer — sizing the window to content is not an API that exists.
    androidx.compose.runtime.CompositionLocalProvider(
        com.zerozerowidget.hzos.ui.LocalHideSampleIndicators provides hideIndicators,
    ) {
    Column(
        Modifier
            .fillMaxSize()
            .panelBackground()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                card?.title ?: "Card",
                style = LocalTypography.current.headline,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
                        UiSetIconButton(onClick = { app.repository.refresh() }, contentDescription = "Refresh") {
                Icon(Icons.Regular.Refresh, contentDescription = null)
            }
        }
        Spacer(Modifier.height(8.dp))
        if (card == null) {            Text(
                "This card is no longer on the dashboard.",
                style = LocalTypography.current.body,
            )
        } else {
            DetailCard(card, cardAlpha, interactiveCharts = true)
            Spacer(Modifier.height(10.dp))
            // Actions hug the left, link and delete sit right with fixed
            // gaps. The buttons size themselves (UiSet caps their width
            // and centers a capped button in a wider slot, so no weight
            // slot — a spacer does the pushing). Samples keep their demo
            // notice, which does take the weight since plain text fills.
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (isSample && !hideIndicators) {
                    if (!card.actions.isNullOrEmpty()) {
                        Text(
                            "Demo card — buttons don't run on samples.",
                            style = LocalTypography.current.bodySmall,
                            color = LocalContentColors.current.secondary,
                            modifier = Modifier.weight(1f),
                        )
                    } else {
                        Spacer(Modifier.weight(1f))
                    }
                } else {
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
                                runError = result.exceptionOrNull()?.let(::describeRunError)
                            }
                        },
                    )
                    Spacer(Modifier.weight(1f))
                }
                card.deepLink?.let {
                    UiSetPrimaryButton("Open link", onClick = { onOpenLink(card.deepLink) })
                }
                DeleteButton(
                    label = if (isSample && !hideIndicators) "Remove sample" else "Delete",
                    busy = deleting,
                    armed = deleteArmed,
                    onClick = {
                        if (deleteArmed) {
                            deleteArmed = false
                            scope.launch {
                                deleting = true
                                deleteError = null
                                val ok = if (isSample) {
                                    app.sampleStore.removeCard(cardId)
                                    true
                                } else {
                                    val result = app.repository.deleteCard(cardId)
                                    deleteError = result.exceptionOrNull()?.let(::describeDeleteError)
                                    result.isSuccess
                                }
                                deleting = false
                                if (ok) onDeleted()
                            }
                        } else {
                            deleteArmed = true
                        }
                    },
                )
            }
            deleteError?.let {
                Spacer(Modifier.height(4.dp))
                Text(it, style = LocalTypography.current.bodySmall, color = LocalColorScheme.current.negative.content)
            }
            card.deadline?.let { deadline ->
                Spacer(Modifier.height(6.dp))
                Text(
                    "Due ${relativeTime(deadline) ?: deadline}",
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary,
                )
            }
        }
    }
    }
}

/**
 * First-run face of the app: signed out with nothing cached, the panel is
 * an empty window, so say what 00Widget is and offer the two ways in —
 * sign in, or look around with on-device demo data. Fills the panel so
 * the empty state reads as a screen, not a gap.
 */
@Composable
private fun WelcomePanel(onSignIn: (() -> Unit)?, onTryDemo: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(vertical = 24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // Brand mark, same transparent master the launcher icon is
        // generated from. nodpi bucket: sized here, never by density.
        Image(
            painter = painterResource(id = com.zerozerowidget.hzos.R.drawable.zw_mark),
            contentDescription = "00Widget",
            modifier = Modifier.size(192.dp),
        )
        Spacer(Modifier.height(12.dp))
        Text(
            "00Widget",
            style = LocalTypography.current.display,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            "Widgets for all your agents.",
            style = LocalTypography.current.title,
            color = uiSetAccent(),
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            "Your agents publish cards and activities here — builds, " +
                "deploys, balances, queues — floating around you while you work.",
            style = LocalTypography.current.body,
            color = LocalContentColors.current.secondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(0.85f),
        )
        Spacer(Modifier.height(20.dp))
        onSignIn?.let { signIn ->
            UiSetPrimaryButton("Sign in", onClick = signIn)
            Spacer(Modifier.height(8.dp))
        }
        UiSetSecondaryButton("Try demo data", onClick = onTryDemo)
        Spacer(Modifier.height(12.dp))
        Text(
            if (onSignIn != null) {
                "Demo data never leaves this device. No account needed to look around."
            } else {
                "Demo data never leaves this device."
            },
            style = LocalTypography.current.bodySmall,
            color = LocalContentColors.current.secondary,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun SectionTitle(text: String) {    Text(
        text,
        style = LocalTypography.current.title,
    )
}

@Composable
private fun ActivityRow(session: LiveActivitySession, cardAlpha: Float, onPopOut: () -> Unit, onOpenDetail: () -> Unit) {
    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    // Overlay badge, not layout — see DashboardRow.
    Box(Modifier.fillMaxWidth()) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = cardAlpha),
            // Explicit: see DashboardRow — alpha breaks contentColorFor().
            contentColor = MaterialTheme.colorScheme.onSurface,
        ),
        modifier = Modifier.fillMaxWidth().clickable(onClick = onOpenDetail),
    ) {
        Column(Modifier.padding(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                session.progress?.let {
                    Text(
                        "${(it * 100).toInt()}%",
                        style = LocalTypography.current.label,
                        modifier = Modifier.padding(end = 8.dp),
                    )
                } ?: StatusDot(
                    com.zerozerowidget.hzos.data.DashboardStatus.UNKNOWN,
                    Modifier.padding(end = 8.dp),
                )
                Column(Modifier.weight(1f)) {
                    Text(session.title, style = LocalTypography.current.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(session.state, style = LocalTypography.current.body, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                PopOutIconButton(onPopOut)
            }
            session.subtitle?.let {
                Text(it, style = LocalTypography.current.bodySmall, color = LocalContentColors.current.secondary)
            }
            session.value?.let {
                Text(
                    it + (session.unit?.let { u -> " $u" } ?: ""),
                    style = LocalTypography.current.headline,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
            session.progress?.let {
                Spacer(Modifier.height(6.dp))
                ProgressBar(
                    fraction = it.toFloat(),
                    color = uiSetAccent(),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            session.chart?.let {
                Spacer(Modifier.height(6.dp))
                Sparkline(
                    it,
                    activityTint(
                        session.kind,
                        session.signal,
                        uiSetAccent(),
                        dark,
                    ),
                    Modifier.fillMaxWidth().height(64.dp),
                )
            }
            session.items.orEmpty().take(4).forEach { item ->
                Row(Modifier.fillMaxWidth().padding(top = 2.dp)) {
                    Text(item.title, style = LocalTypography.current.bodySmall, modifier = Modifier.weight(1f))
                    item.value?.let { v ->
                        Text(v, style = LocalTypography.current.bodySmall, color = LocalContentColors.current.secondary)
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 6.dp)) {
                session.endsAt?.let { endsAt ->
                    Text(
                        "Ends ${relativeTime(endsAt) ?: endsAt}",
                        style = LocalTypography.current.caption,
                        color = LocalContentColors.current.secondary,
                        modifier = Modifier.weight(1f),
                    )
                } ?: Spacer(Modifier.weight(1f))
                if (isStale(session.updatedAt, session.staleAt)) {
                    Text("stale", style = LocalTypography.current.caption, color = LocalColorScheme.current.negative.content)
                }
            }
        }
        }
        if (session.isSample()) {
            SampleBadge(
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(8.dp),
            )
        }
    }
}
