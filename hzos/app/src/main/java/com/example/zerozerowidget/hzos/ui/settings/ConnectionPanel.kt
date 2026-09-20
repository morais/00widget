package com.example.zerozerowidget.hzos.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.example.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.example.zerozerowidget.hzos.data.ConnectionStore
import com.example.zerozerowidget.hzos.ui.cards.GlassCard
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
@Composable
fun ConnectionPanel(
    app: ZeroZeroWidgetApp,
    onClose: () -> Unit,
    onSendAuthUrl: (authUrl: String, onSent: (Boolean) -> Unit) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var baseUrl by remember { mutableStateOf("") }
    var apiKey by remember { mutableStateOf("") }
    var loaded by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var testing by remember { mutableStateOf(false) }
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )

    LaunchedEffect(Unit) {
        val current = app.connectionStore.current()
        // Fresh install: pre-fill from the build defaults (defaults.properties,
        // gitignored). A saved value always wins.
        baseUrl = current.baseUrl.ifBlank { com.example.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL }
        apiKey = current.apiKey.ifBlank { com.example.zerozerowidget.hzos.BuildConfig.DEVICE_TOKEN }
        loaded = true
    }

    Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Connection", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
            FilledTonalButton(onClick = onClose) { Text("Close") }
        }

        if (!loaded) {
            Text("Loading…")
            return@Column
        }

        GlassCard(cardAlpha = cardAlpha) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        PhoneSignInSection(
            app = app,
            baseUrl = baseUrl,
            onSendAuthUrl = onSendAuthUrl,
            onSignedIn = { token ->
                scope.launch {
                    val normalized = ConnectionStore.normalizeBaseUrl(baseUrl) ?: return@launch
                    app.connectionStore.save(normalized, token)
                    val current = app.connectionStore.current()
                    apiKey = current.apiKey
                    app.repository.refresh()
                    message = "Connected — dashboard is refreshing."
                }
            },
        )

        OutlinedTextField(
            value = baseUrl,
            onValueChange = { baseUrl = it; message = null },
            label = { Text("Worker URL (https://…)") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = apiKey,
            onValueChange = { apiKey = it; message = null },
            label = { Text("API key") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            modifier = Modifier.fillMaxWidth(),
        )

        message?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodySmall,
                color = if (it.startsWith("Connected")) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.error,
            )
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                onClick = {
                    scope.launch {
                        val normalized = ConnectionStore.normalizeBaseUrl(baseUrl)
                        if (normalized == null) {
                            message = "URL must be https (http only for localhost)."
                            return@launch
                        }
                        if (apiKey.isBlank()) {
                            message = "Paste an API key from /admin."
                            return@launch
                        }
                        testing = true
                        try {
                            app.connectionStore.save(normalized, apiKey.trim())
                            app.repository.refresh()
                            message = "Connected — dashboard is refreshing."
                        } finally {
                            testing = false
                        }
                    }
                },
                enabled = !testing,
            ) { Text(if (testing) "Saving…" else "Save + connect") }
            FilledTonalButton(
                onClick = {
                    scope.launch {
                        app.connectionStore.clear()
                        baseUrl = ""
                        apiKey = ""
                        message = "Cleared. Panels will show the not-connected state."
                    }
                },
            ) { Text("Sign out") }
        }

        Spacer(Modifier.height(4.dp))
        Text(
            "Manual paste always works and is the fallback when phone sign-in " +
                "is unavailable. Prefer a `device`-preset token from /admin — see README.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        LookSection(app)
            }
        }
    }
}

/**
 * Panel look: opaque black windows or transparent ones with passthrough
 * showing through. Applies to every open panel immediately, no restart.
 * Cards stay opaque dark surfaces either way, which is what keeps light
 * text readable over a bright room.
 */
@Composable
private fun LookSection(app: ZeroZeroWidgetApp) {
    val scope = rememberCoroutineScope()
    val transparent by app.panelPrefs.transparent.collectAsState(initial = false)
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    var sliderAlpha by remember(cardAlpha) { mutableStateOf(cardAlpha) }
    Spacer(Modifier.height(8.dp))
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
    Spacer(Modifier.height(4.dp))
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text("Card opacity", style = MaterialTheme.typography.bodyMedium)
            Text(
                "How solid cards are over passthrough: ${(sliderAlpha * 100).toInt()}%.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
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
    baseUrl: String,
    onSendAuthUrl: (authUrl: String, onSent: (Boolean) -> Unit) -> Unit,
    onSignedIn: (String) -> Unit,
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
                            val normalized = ConnectionStore.normalizeBaseUrl(baseUrl)
                                ?: throw IllegalArgumentException("Enter a valid Worker URL first.")
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
                            onSignedIn(token)
                            phase = SignInPhase.IDLE
                        } catch (e: CancellationException) {
                            phase = SignInPhase.IDLE
                            throw e
                        } catch (e: Exception) {
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
                    true -> "Approval sent to your Horizon mobile app — tap the notification."
                    else -> "Couldn't reach the Horizon app. Enter the code at:"
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
