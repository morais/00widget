package com.zerozerowidget.hzos.ui.dashboard

import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.zerozerowidget.hzos.R
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.data.DashboardCard
import com.zerozerowidget.hzos.data.DashboardStatus
import com.zerozerowidget.hzos.data.LiveActivitySession
import com.zerozerowidget.hzos.data.SampleData
import com.zerozerowidget.hzos.ui.LocalHideSampleIndicators
import com.zerozerowidget.hzos.ui.LocalNow
import com.zerozerowidget.hzos.ui.PanelBreakpoints
import com.zerozerowidget.hzos.ui.PanelPrefs
import com.zerozerowidget.hzos.ui.cardAlphaState
import com.zerozerowidget.hzos.ui.cards.ActionButtons
import com.zerozerowidget.hzos.ui.cards.CardHeadline
import com.zerozerowidget.hzos.ui.cards.CardTemplateBody
import com.zerozerowidget.hzos.ui.cards.DeleteButton
import com.zerozerowidget.hzos.ui.cards.DeleteConfirmDialog
import com.zerozerowidget.hzos.ui.cards.DetailCard
import com.zerozerowidget.hzos.ui.cards.GlassPrimaryCard
import com.zerozerowidget.hzos.ui.cards.LinkIconButton
import com.zerozerowidget.hzos.ui.cards.PopOutIconButton
import com.zerozerowidget.hzos.ui.cards.ProgressBar
import com.zerozerowidget.hzos.ui.cards.SampleBadge
import com.zerozerowidget.hzos.ui.cards.SampleNoticeBanner
import com.zerozerowidget.hzos.ui.cards.Sparkline
import com.zerozerowidget.hzos.ui.cards.StatusDot
import com.zerozerowidget.hzos.ui.cards.activityTint
import com.zerozerowidget.hzos.ui.describeDeleteError
import com.zerozerowidget.hzos.ui.describeRunError
import com.zerozerowidget.hzos.ui.hideSampleIndicatorsState
import com.zerozerowidget.hzos.ui.isStale
import com.zerozerowidget.hzos.ui.openDeepLink
import com.zerozerowidget.hzos.ui.openSettingsPanelAndSignIn
import com.zerozerowidget.hzos.ui.relativeTime
import com.zerozerowidget.hzos.ui.theme.panelBackground
import com.zerozerowidget.hzos.ui.theme.spacing
import com.zerozerowidget.hzos.ui.uiset.UiSetConfirmDialog
import com.zerozerowidget.hzos.ui.uiset.UiSetIconButton
import com.zerozerowidget.hzos.ui.uiset.UiSetPrimaryButton
import com.zerozerowidget.hzos.ui.uiset.UiSetSecondaryButton
import com.zerozerowidget.hzos.ui.uiset.uiSetAccent
import kotlinx.coroutines.launch
import metavrx.uiset.compose.Icon
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalColorScheme
import metavrx.uiset.compose.theme.LocalContentColors
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
    onPopOut: (cardId: String, isSample: Boolean) -> Unit,
    onPopOutActivity: (externalActivityId: String, isSample: Boolean) -> Unit
) {
    val context = LocalContext.current
    val state by app.repository.state.collectAsStateWithLifecycle()
    val samples by app.sampleStore.cards.collectAsStateWithLifecycle()
    val sampleActivities by app.sampleStore.activities.collectAsStateWithLifecycle()
    val cardAlpha by app.panelPrefs.cardAlphaState()
    val hideIndicators by app.panelPrefs.hideSampleIndicatorsState()
    var selectedId by remember { mutableStateOf<String?>(null) }
    // Per card, keyed by Sourced.key: a running action disables only its
    // own card's buttons, and a failure shows under the card that failed.
    val runningIds = remember { mutableStateMapOf<String, String>() }
    val runErrors = remember { mutableStateMapOf<String, String>() }
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize().panelBackground().padding(spacing.twoXLarge)) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(spacing.small)
        ) {
            Text(
                "Dashboard",
                style = LocalTypography.current.headline,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            state.lastSyncEpochMs?.let {
                Text(
                    "synced ${relativeTime(java.time.Instant.ofEpochMilli(it).toString(), LocalNow.current) ?: ""}",
                    style = LocalTypography.current.caption,
                    color = LocalContentColors.current.secondary,
                    modifier = Modifier.padding(end = spacing.xSmall)
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
        CompositionLocalProvider(
            LocalHideSampleIndicators provides hideIndicators
        ) {
            if ((samples.isNotEmpty() || sampleActivities.isNotEmpty()) && !hideIndicators) {
                SampleNoticeBanner(onRemoveAll = { app.sampleStore.clearSamples() })
                Spacer(Modifier.height(spacing.xSmall))
            }

            // Server cards first, local samples after — never mixed, never sent.
            // Origin travels with each entry: ids cannot tell the two apart, since
            // the server accepts any id, including one a sample already uses.
            val visible = state.cards.map { Sourced(it, isSample = false) } +
                samples.map { Sourced(it, isSample = true) }
            val visibleActivities = state.activities.map { Sourced(it, isSample = false) } +
                sampleActivities.map { Sourced(it, isSample = true) }
            val nothingToShow = visible.isEmpty() && visibleActivities.isEmpty()
            when {
                !state.isConfigured && nothingToShow -> {
                    WelcomePanel(
                        onSignIn = { context.openSettingsPanelAndSignIn() },
                        onTryDemo = { app.sampleStore.generateCards() }
                    )
                }

                state.error != null && nothingToShow -> {
                    Text(state.error!!, color = LocalColorScheme.current.negative.content)
                    Spacer(Modifier.height(spacing.small))
                    Row(horizontalArrangement = Arrangement.spacedBy(spacing.small)) {
                        UiSetPrimaryButton("Retry", onClick = { app.repository.refresh() })
                        UiSetSecondaryButton("Generate samples", onClick = { app.sampleStore.generateCards() })
                    }
                }

                nothingToShow -> {
                    WelcomePanel(
                        onSignIn = null,
                        onTryDemo = { app.sampleStore.generateCards() }
                    )
                }

                else -> {
                    state.error?.let {
                        Text(it, color = LocalColorScheme.current.negative.content, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                    val cardRow: @Composable (Sourced<DashboardCard>) -> Unit = { entry ->
                        val card = entry.item
                        val isSample = entry.isSample
                        DashboardRow(
                            card = card,
                            cardAlpha = cardAlpha,
                            isSample = isSample,
                            expanded = selectedId == entry.key,
                            onToggle = { selectedId = if (selectedId == entry.key) null else entry.key },
                            onPopOut = { onPopOut(card.id, isSample) },
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
                                            color = LocalContentColors.current.secondary
                                        )
                                    }
                                } else {
                                    val key = entry.key
                                    ActionButtons(
                                        card = card,
                                        runningId = runningIds[key],
                                        runError = runErrors[key],
                                        onRun = { action ->
                                            scope.launch {
                                                runningIds[key] = action.id
                                                runErrors.remove(key)
                                                val result = app.repository.runAction(action.id, card.id)
                                                runningIds.remove(key)
                                                result.exceptionOrNull()?.let { runErrors[key] = describeRunError(it) }
                                            }
                                        }
                                    )
                                }
                            }
                        )
                    }
                    // Width-driven columns, mirroring iOS DashboardView: one
                    // column below 728dp, exactly two above — never three. iOS
                    // counts a Duo hinge as a column boundary; Quest has no
                    // hinge, so the width rule is the whole story. One scroll
                    // for both sections: the grid is chunked into rows because
                    // a lazy grid cannot live inside a lazy list.
                    BoxWithConstraints(Modifier.fillMaxWidth().weight(1f)) {
                        val twoCol = maxWidth >= PanelBreakpoints.DashboardTwoColumns
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
                            verticalArrangement = Arrangement.spacedBy(spacing.medium),
                            // Bottom breathing room: without it the last card
                            // ends flush against the window edge when the list
                            // is scrolled to the end.
                            contentPadding = PaddingValues(bottom = spacing.medium)
                        ) {
                            if (visibleActivities.isNotEmpty()) {
                                item(key = "activities-title") {
                                    SectionTitle("Ongoing Activities")
                                }
                                items(
                                    visibleActivities,
                                    key = { "act-" + it.key }
                                ) { entry ->
                                    ActivityRow(
                                        session = entry.item,
                                        isSample = entry.isSample,
                                        cardAlpha = cardAlpha,
                                        onPopOut = { onPopOutActivity(entry.item.externalActivityId, entry.isSample) },
                                        onOpenDetail = { onPopOutActivity(entry.item.externalActivityId, entry.isSample) }
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
                                        onClick = { app.sampleStore.generateCards() }
                                    )
                                }
                            } else if (twoCol) {
                                items(
                                    visible.chunked(2),
                                    key = { row -> "row-" + row.first().key }
                                ) { row ->
                                    Row(horizontalArrangement = Arrangement.spacedBy(spacing.medium)) {
                                        Box(Modifier.weight(1f)) { cardRow(row[0]) }
                                        if (row.size > 1) {
                                            Box(Modifier.weight(1f)) { cardRow(row[1]) }
                                        } else {
                                            Spacer(Modifier.weight(1f))
                                        }
                                    }
                                }
                            } else {
                                items(visible, key = { it.key }) { entry -> cardRow(entry) }
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
    actionSlot: @Composable () -> Unit
) {
    // Overlay badge, not layout: the Box is exactly the card's size and the
    // pill draws over the bottom-right corner without moving anything.
    Box(Modifier.fillMaxWidth()) {
        // Expanding is the headline's job, not the whole card's: with the
        // card as one target, a pinch landing just off the link or pop-out
        // icon toggled it instead (readiness #18).
        GlassPrimaryCard(cardAlpha = cardAlpha, contentPadding = spacing.large) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CardHeadline(
                    card,
                    Modifier
                        .weight(1f)
                        .clickable(
                            role = Role.Button,
                            onClickLabel = if (expanded) "Collapse" else "Expand",
                            onClick = onToggle
                        )
                )
                card.deepLink?.let {
                    LinkIconButton(onOpenLink = onOpenLink)
                    Spacer(Modifier.width(spacing.medium))
                }
                PopOutIconButton(onPopOut)
            }
            card.subtitle?.let {
                Text(
                    it,
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            if (isStale(card.updatedAt, card.staleAfter, LocalNow.current)) {
                Text("stale", style = LocalTypography.current.caption, color = LocalColorScheme.current.negative.content)
            }
            if (expanded) {
                Spacer(Modifier.height(spacing.small))
                CardTemplateBody(card)
                actionSlot()
            }
        }
        if (isSample) {
            SampleBadge(
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(spacing.small)
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
    isSample: Boolean,
    onOpenLink: (String?) -> Unit,
    onDeleted: () -> Unit
) {
    val state by app.repository.state.collectAsStateWithLifecycle()
    val samples by app.sampleStore.cards.collectAsStateWithLifecycle()
    val cardAlpha by app.panelPrefs.cardAlphaState()
    val hideIndicators by app.panelPrefs.hideSampleIndicatorsState()
    var runningId by remember { mutableStateOf<String?>(null) }
    var runError by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf(false) }
    var deleteError by remember { mutableStateOf<String?>(null) }
    var confirmingDelete by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    // Look in the store the panel was opened for, never both: a server card
    // and a local sample may share an id.
    val card = (if (isSample) samples else state.cards).firstOrNull { it.id == cardId }

    // Shell panels have one fixed window height each; tall content (long
    // briefings, full item lists, inspection panels) scrolls inside it.
    // The OS cannot size a panel to its content, so scroll is the whole
    // answer — sizing the window to content is not an API that exists.
    CompositionLocalProvider(
        LocalHideSampleIndicators provides hideIndicators
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .panelBackground()
                .verticalScroll(rememberScrollState())
                .padding(spacing.twoXLarge)
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    card?.title ?: "Card",
                    style = LocalTypography.current.headline,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                UiSetIconButton(onClick = { app.repository.refresh() }, contentDescription = "Refresh") {
                    Icon(Icons.Regular.Refresh, contentDescription = null)
                }
            }
            Spacer(Modifier.height(spacing.small))
            if (card == null) {
                Text(
                    "This card is no longer on the dashboard.",
                    style = LocalTypography.current.body
                )
            } else {
                DetailCard(card, cardAlpha, isSample = isSample, interactiveCharts = true)
                Spacer(Modifier.height(spacing.medium))
                // Actions, link and delete sit together on the right — but
                // only while all three fit. Rows neither wrap nor clip, and
                // three pills need roughly 400dp; below that they would spill
                // off the window edge, so narrow stacks the actions above the
                // link/delete row instead, still right-aligned. The actions
                // column is only as wide as its widest button (a weight slot
                // only recenters them, because UiSet caps button width inside
                // oversized slots); a spacer does the pushing. Samples keep
                // their demo notice in the actions slot.
                val deleteLabel = if (isSample && !hideIndicators) "Remove sample" else "Delete"
                fun fireDelete() {
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
                }

                @Composable
                fun actionSlot() {
                    if (isSample && !hideIndicators) {
                        if (!card.actions.isNullOrEmpty()) {
                            Text(
                                "Demo card — buttons don't run on samples.",
                                style = LocalTypography.current.bodySmall,
                                color = LocalContentColors.current.secondary
                            )
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
                            modifier = Modifier.width(IntrinsicSize.Max)
                        )
                    }
                }

                // Plain text fills and wraps; buttons size to content, so the
                // spacer takes the weight and pushes them right.
                @Composable
                fun wideActions() {
                    if (isSample && !hideIndicators && !card.actions.isNullOrEmpty()) {
                        Text(
                            "Demo card — buttons don't run on samples.",
                            style = LocalTypography.current.bodySmall,
                            color = LocalContentColors.current.secondary,
                            modifier = Modifier.weight(1f)
                        )
                    } else if (isSample && !hideIndicators) {
                        Spacer(Modifier.weight(1f))
                    } else {
                        Spacer(Modifier.weight(1f))
                        actionSlot()
                    }
                }
                BoxWithConstraints(Modifier.fillMaxWidth()) {
                    if (maxWidth >= PanelBreakpoints.DetailInlineActions) {
                        Row(
                            Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(spacing.small)
                        ) {
                            wideActions()
                            card.deepLink?.let {
                                UiSetPrimaryButton("Open link", onClick = { onOpenLink(card.deepLink) })
                            }
                            DeleteButton(
                                label = deleteLabel,
                                busy = deleting,
                                onClick = { confirmingDelete = true }
                            )
                        }
                    } else {
                        Column(
                            Modifier.fillMaxWidth(),
                            verticalArrangement = Arrangement.spacedBy(spacing.small),
                            horizontalAlignment = Alignment.End
                        ) {
                            actionSlot()
                            Row(
                                Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(spacing.small)
                            ) {
                                Spacer(Modifier.weight(1f))
                                card.deepLink?.let {
                                    UiSetPrimaryButton("Open link", onClick = { onOpenLink(card.deepLink) })
                                }
                                DeleteButton(
                                    label = deleteLabel,
                                    busy = deleting,
                                    onClick = { confirmingDelete = true }
                                )
                            }
                        }
                    }
                }
                if (confirmingDelete) {
                    DeleteConfirmDialog(
                        title = if (isSample) "Remove this sample?" else "Delete this card?",
                        text = if (isSample) {
                            "It only exists on this headset and can be generated again."
                        } else {
                            "It is removed from your account, not just this headset. " +
                                "The agent that published it can publish it again."
                        },
                        confirmLabel = deleteLabel,
                        onConfirm = {
                            confirmingDelete = false
                            fireDelete()
                        },
                        onDismiss = { confirmingDelete = false }
                    )
                }
                deleteError?.let {
                    Spacer(Modifier.height(spacing.xSmall))
                    Text(it, style = LocalTypography.current.bodySmall, color = LocalColorScheme.current.negative.content)
                }
                card.deadline?.let { deadline ->
                    Spacer(Modifier.height(spacing.small))
                    Text(
                        "Due ${relativeTime(deadline, LocalNow.current) ?: deadline}",
                        style = LocalTypography.current.bodySmall,
                        color = LocalContentColors.current.secondary
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
        Modifier.fillMaxSize().padding(vertical = spacing.twoXLarge),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // Brand mark, same transparent master the launcher icon is
        // generated from. nodpi bucket: sized here, never by density.
        Image(
            painter = painterResource(id = R.drawable.zw_mark),
            contentDescription = "00Widget",
            modifier = Modifier.size(192.dp)
        )
        Spacer(Modifier.height(spacing.medium))
        Text(
            "00Widget",
            style = LocalTypography.current.display,
            textAlign = TextAlign.Center
        )
        Spacer(Modifier.height(spacing.xSmall))
        Text(
            "Widgets for all your agents.",
            style = LocalTypography.current.title,
            color = uiSetAccent(),
            textAlign = TextAlign.Center
        )
        Spacer(Modifier.height(spacing.medium))
        Text(
            "Your agents publish cards and activities here — builds, " +
                "deploys, balances, queues — floating around you while you work.",
            style = LocalTypography.current.body,
            color = LocalContentColors.current.secondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(0.85f)
        )
        Spacer(Modifier.height(spacing.twoXLarge))
        onSignIn?.let { signIn ->
            UiSetPrimaryButton("Sign in", onClick = signIn)
            Spacer(Modifier.height(spacing.small))
        }
        UiSetSecondaryButton("Try demo data", onClick = onTryDemo)
        Spacer(Modifier.height(spacing.medium))
        Text(
            if (onSignIn != null) {
                "Demo data never leaves this device. No account needed to look around."
            } else {
                "Demo data never leaves this device."
            },
            style = LocalTypography.current.bodySmall,
            color = LocalContentColors.current.secondary,
            textAlign = TextAlign.Center
        )
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        style = LocalTypography.current.title,
        modifier = Modifier.semantics { heading() }
    )
}

@Composable
private fun ActivityRow(
    session: LiveActivitySession,
    isSample: Boolean,
    cardAlpha: Float,
    onPopOut: () -> Unit,
    onOpenDetail: () -> Unit
) {
    val dark = isSystemInDarkTheme()
    // Overlay badge, not layout — see DashboardRow.
    Box(Modifier.fillMaxWidth()) {
        GlassPrimaryCard(cardAlpha = cardAlpha, onClick = onOpenDetail, contentPadding = spacing.large) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                session.progress?.let {
                    Text(
                        "${(it * 100).toInt()}%",
                        style = LocalTypography.current.label,
                        modifier = Modifier.padding(end = spacing.small)
                    )
                } ?: StatusDot(
                    DashboardStatus.UNKNOWN,
                    Modifier.padding(end = spacing.small)
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
                    modifier = Modifier.padding(top = spacing.xSmall)
                )
            }
            session.progress?.let {
                Spacer(Modifier.height(spacing.small))
                ProgressBar(
                    fraction = it.toFloat(),
                    modifier = Modifier.fillMaxWidth()
                )
            }
            session.chart?.let {
                Spacer(Modifier.height(spacing.small))
                Sparkline(
                    it,
                    activityTint(
                        session.kind,
                        session.signal,
                        uiSetAccent(),
                        dark
                    ),
                    Modifier.fillMaxWidth().height(64.dp)
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
            Row(Modifier.fillMaxWidth().padding(top = spacing.small)) {
                session.endsAt?.let { endsAt ->
                    Text(
                        "Ends ${relativeTime(endsAt, LocalNow.current) ?: endsAt}",
                        style = LocalTypography.current.caption,
                        color = LocalContentColors.current.secondary,
                        modifier = Modifier.weight(1f)
                    )
                } ?: Spacer(Modifier.weight(1f))
                if (isStale(session.updatedAt, session.staleAt, LocalNow.current)) {
                    Text("stale", style = LocalTypography.current.caption, color = LocalColorScheme.current.negative.content)
                }
            }
        }
        if (isSample) {
            SampleBadge(
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(spacing.small)
            )
        }
    }
}
