package com.example.zerozerowidget.hzos.ui.options

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.example.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.example.zerozerowidget.hzos.ui.cards.GlassCard
import kotlinx.coroutines.launch

/**
 * Additional options panel: panel look today (transparent windows, card
 * glass). Reached by tapping the version row in Connection — the iOS
 * pattern of hiding developer-adjacent switches behind the version tap.
 */
@Composable
fun OptionsPanel(app: ZeroZeroWidgetApp, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsStateWithLifecycle(
        initialValue = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    val transparent by app.panelPrefs.transparent.collectAsState(initial = true)
    var sliderAlpha by remember(cardAlpha) { mutableStateOf(cardAlpha) }

    Column(Modifier.fillMaxSize().padding(20.dp)) {
        Text("Options", style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(10.dp))
        GlassCard(cardAlpha = cardAlpha) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
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
                Text(
                    "Version ${com.example.zerozerowidget.hzos.BuildConfig.VERSION_NAME} " +
                        "(${com.example.zerozerowidget.hzos.BuildConfig.VERSION_CODE})",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            FilledTonalButton(onClick = onClose) {
                Text("Done")
            }
        }
    }
}
