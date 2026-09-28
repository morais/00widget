package com.zerozerowidget.hzos.ui.dashboard

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.ui.cards.GlassPrimaryCard
import com.zerozerowidget.hzos.ui.cards.InspectableChart
import com.zerozerowidget.hzos.ui.cards.ProgressBar
import com.zerozerowidget.hzos.ui.cards.SampleAwareDeleteRow
import com.zerozerowidget.hzos.ui.cards.SampleBadge
import com.zerozerowidget.hzos.ui.cards.StatusDot
import com.zerozerowidget.hzos.ui.cards.activityTint
import com.zerozerowidget.hzos.ui.describeDeleteError
import com.zerozerowidget.hzos.ui.isStale
import com.zerozerowidget.hzos.ui.relativeTime
import com.zerozerowidget.hzos.ui.uiset.UiSetIconButton
import com.zerozerowidget.hzos.ui.uiset.UiSetPrimaryButton
import com.zerozerowidget.hzos.ui.uiset.uiSetAccent
import kotlinx.coroutines.launch
import metavrx.uiset.compose.Icon
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.icons.Icons
import metavrx.uiset.compose.theme.LocalColorScheme
import metavrx.uiset.compose.theme.LocalContentColors
import com.zerozerowidget.hzos.ui.theme.panelBackground
import metavrx.uiset.compose.theme.LocalTypography

/**
 * Full activity detail, hosted by CardDetailActivity alongside cards: every
 * item (not the dashboard's first four), the chart with hover inspection,
 * countdown, and link. One activity instance per popped-out activity, i.e.
 * one shell panel each — same pop-out story as cards.
 */
@Composable
fun ActivityDetailPanel(
    app: ZeroZeroWidgetApp,
    externalActivityId: String,
    isSample: Boolean,
    onOpenLink: (String?) -> Unit,
    onDeleted: () -> Unit,
) {
    val state by app.repository.state.collectAsStateWithLifecycle()
    val samples by app.sampleStore.activities.collectAsState()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    // Look in the store the panel was opened for, never both: a server
    // activity and a local sample may share an id.
    val session = (if (isSample) samples else state.activities)
        .firstOrNull { it.externalActivityId == externalActivityId }
    var ending by remember { mutableStateOf(false) }
    var endError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val hideIndicators by app.panelPrefs.hideSampleIndicators.collectAsState(initial = false)
    val dark = androidx.compose.foundation.isSystemInDarkTheme()

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
                session?.title ?: "Activity",
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
        if (session == null) {
            Text(
                "This activity has ended.",
                style = LocalTypography.current.body,
            )
        } else {
            // Same glass container as widget details, so activity panels
            // read as the same object family rather than naked text.
            // Overlay badge, not layout — see DashboardRow.
            Box(Modifier.fillMaxWidth()) {
            GlassPrimaryCard(cardAlpha = cardAlpha, contentPadding = 16.dp) {
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
                        Text(session.state, style = LocalTypography.current.title)
                        session.subtitle?.let {
                            Text(
                                it,
                                style = LocalTypography.current.bodySmall,
                                color = LocalContentColors.current.secondary,
                            )
                        }
                    }
                }
                session.value?.let {
                    Text(
                        it + (session.unit?.let { u -> " $u" } ?: ""),
                        style = LocalTypography.current.display,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
                session.progress?.let {
                    Spacer(Modifier.height(6.dp))
                    ProgressBar(
                        fraction = it.toFloat(),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                session.chart?.let { chart ->
                    Spacer(Modifier.height(8.dp))
                    InspectableChart(
                        chart = chart,
                        unit = session.unit,
                        baseTint = activityTint(
                            session.kind,
                            session.signal,
                            uiSetAccent(),
                            dark,
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                session.items.orEmpty().forEach { item ->
                    Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        StatusDot(item.status, Modifier.padding(end = 6.dp))
                        Column(Modifier.weight(1f)) {
                            Text(item.title, style = LocalTypography.current.body)
                            item.subtitle?.let {
                                Text(
                                    it,
                                    style = LocalTypography.current.bodySmall,
                                    color = LocalContentColors.current.secondary,
                                )
                            }
                        }
                        item.value?.let { v ->
                            Text(
                                v + (item.unit?.let { u -> " $u" } ?: ""),
                                style = LocalTypography.current.body,
                                color = LocalContentColors.current.secondary,
                            )
                        }
                    }
                    item.progress?.let { p ->
                        ProgressBar(
                            fraction = p.toFloat(),
                            modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
                        )
                    }
                }
                Spacer(Modifier.height(8.dp))
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    session.endsAt?.let { endsAt ->
                        Text(
                            "Ends ${relativeTime(endsAt) ?: endsAt}",
                            style = LocalTypography.current.bodySmall,
                            color = LocalContentColors.current.secondary,
                            modifier = Modifier.weight(1f),
                        )
                    } ?: Spacer(Modifier.weight(1f))
                    if (isStale(session.updatedAt, session.staleAt)) {
                        Text("stale", style = LocalTypography.current.caption, color = LocalColorScheme.current.negative.content)
                    }
                }
                Spacer(Modifier.height(8.dp))
                SampleAwareDeleteRow(
                    isSample = isSample,
                    serverLabel = "End activity",
                    confirmTitle = if (isSample) "Remove this sample?" else "End this activity?",
                    confirmText = if (isSample) {
                        "It only exists on this headset and can be generated again."
                    } else {
                        "It ends everywhere it is shown, not just here."
                    },
                    busy = ending,
                    error = endError,
                    onDelete = {
                        scope.launch {
                            ending = true
                            endError = null
                            val ok = if (isSample) {
                                app.sampleStore.removeActivity(externalActivityId)
                                true
                            } else {
                                val result = app.repository.endActivity(externalActivityId)
                                endError = result.exceptionOrNull()?.let(::describeDeleteError)
                                result.isSuccess
                            }
                            ending = false
                            if (ok) onDeleted()
                        }
                    },
                    leading = {
                        session.deepLink?.let {
                            UiSetPrimaryButton("Open link", onClick = { onOpenLink(session.deepLink) })
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
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
    }
    }
}
