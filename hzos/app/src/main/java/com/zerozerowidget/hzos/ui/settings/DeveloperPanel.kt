package com.zerozerowidget.hzos.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.ui.text.input.KeyboardType
import com.zerozerowidget.hzos.BuildConfig
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.data.ConnectionStore
import com.zerozerowidget.hzos.ui.PanelPrefs
import com.zerozerowidget.hzos.ui.cardAlphaState
import com.zerozerowidget.hzos.ui.cards.GlassCard
import com.zerozerowidget.hzos.ui.hideSampleIndicatorsState
import com.zerozerowidget.hzos.ui.showDummyAccountDataState
import com.zerozerowidget.hzos.ui.theme.spacing
import com.zerozerowidget.hzos.ui.uiset.UiSetPrimaryButton
import com.zerozerowidget.hzos.ui.uiset.UiSetSlider
import com.zerozerowidget.hzos.ui.uiset.UiSetSwitch
import com.zerozerowidget.hzos.ui.uiset.UiSetTextField
import com.zerozerowidget.hzos.ui.uiset.uiSetAccent
import kotlinx.coroutines.launch
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalContentColors
import metavrx.uiset.compose.theme.LocalTypography

/**
 * Developer destination: Worker URL, sample-indicator visibility, and panel
 * look. No "provided by the build" note — a readonly field already says
 * it can't be changed.
 */
@Composable
internal fun DeveloperPanel(app: ZeroZeroWidgetApp) {
    val scope = rememberCoroutineScope()
    val cardAlpha by app.panelPrefs.cardAlphaState()
    val hideIndicators by app.panelPrefs.hideSampleIndicatorsState()
    val showDummyAccountData by app.panelPrefs.showDummyAccountDataState()
    var sliderAlpha by remember(cardAlpha) { mutableStateOf(cardAlpha) }
    val locked = BuildConfig.DEFAULT_BASE_URL.isNotBlank()
    var serverUrl by remember { mutableStateOf("") }
    var savedNote by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        serverUrl = app.connectionStore.current().baseUrl
    }

    GlassCard(cardAlpha = cardAlpha) {
        Column(verticalArrangement = Arrangement.spacedBy(spacing.medium)) {
            Text("Server", style = LocalTypography.current.title)
            if (locked) {
                // No label, no field: the section already says Server, so
                // the URL sits under it as plain text. A disabled field
                // here was chrome around a value nobody can change.
                Text(
                    BuildConfig.DEFAULT_BASE_URL,
                    style = LocalTypography.current.body,
                    color = LocalContentColors.current.secondary
                )
            } else {
                UiSetTextField(
                    value = serverUrl,
                    label = "",
                    placeholder = "https://…",
                    onValueChange = {
                        serverUrl = it
                        savedNote = null
                    },
                    modifier = Modifier.fillMaxWidth(),
                    keyboardType = KeyboardType.Uri
                )
            }
            if (!locked) {
                savedNote?.let {
                    Text(
                        it,
                        style = LocalTypography.current.body,
                        color = uiSetAccent()
                    )
                }
                UiSetPrimaryButton(
                    label = "Save server",
                    onClick = {
                        scope.launch {
                            val normalized = ConnectionStore.normalizeBaseUrl(serverUrl)
                            if (normalized == null) {
                                savedNote = "URL must be https."
                                return@launch
                            }
                            // A token never follows the URL to another server.
                            val signedOut = app.connectionStore.changeServer(normalized)
                            if (signedOut) {
                                app.repository.clearServerData()
                                savedNote = "Saved. That is a different server, so this " +
                                    "headset signed out — sign in to it in Settings."
                            } else {
                                app.repository.refresh()
                                savedNote = "Saved — dashboard is refreshing."
                            }
                        }
                    }
                )
            }
            Text("Screenshots and recordings", style = LocalTypography.current.title)
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Show dummy account data", style = LocalTypography.current.body)
                    Text(
                        "A visibly fake token on the Settings screen instead of your own.",
                        style = LocalTypography.current.body,
                        color = LocalContentColors.current.secondary
                    )
                }
                UiSetSwitch(
                    checked = showDummyAccountData,
                    onCheckedChange = { checked ->
                        scope.launch { app.panelPrefs.setShowDummyAccountData(checked) }
                    },
                    contentDescription = "Show dummy account data"
                )
            }
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Hide sample indicators", style = LocalTypography.current.body)
                    Text(
                        "Demo data stays; badges and notice go away.",
                        style = LocalTypography.current.body,
                        color = LocalContentColors.current.secondary
                    )
                }
                UiSetSwitch(
                    checked = hideIndicators,
                    onCheckedChange = { checked ->
                        scope.launch { app.panelPrefs.setHideSampleIndicators(checked) }
                    },
                    contentDescription = "Hide sample indicators"
                )
            }
            Text(
                "Dummy account data shows a visibly fake token in Agent config instead of " +
                    "your own. The real token still authorizes every request, and Copy " +
                    "agent config copies what is on screen — so turn this off before " +
                    "handing the token to an agent.",
                style = LocalTypography.current.body,
                color = LocalContentColors.current.secondary
            )
            Text("Look", style = LocalTypography.current.title)
            Column(Modifier.fillMaxWidth()) {
                Text("Card opacity", style = LocalTypography.current.body)
                Text(
                    "How solid cards are over passthrough: ${(sliderAlpha * 100).toInt()}%.",
                    style = LocalTypography.current.body,
                    color = LocalContentColors.current.secondary
                )
            }
            UiSetSlider(
                value = sliderAlpha,
                onValueChange = { sliderAlpha = it },
                onValueChangeFinished = {
                    scope.launch { app.panelPrefs.setCardAlpha(sliderAlpha) }
                },
                valueRange = 0.5f..1f,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}
