package com.zerozerowidget.hzos.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.auth.HorizonPhase
import com.zerozerowidget.hzos.data.ConnectionStore
import com.zerozerowidget.hzos.data.DeviceAuthApi
import com.zerozerowidget.hzos.data.HorizonOutcome
import com.zerozerowidget.hzos.data.ZeroWidgetApi
import com.zerozerowidget.hzos.data.awaitDeviceToken
import com.zerozerowidget.hzos.data.horizonSignInBody
import com.zerozerowidget.hzos.data.runHorizonSignIn
import com.zerozerowidget.hzos.ui.theme.spacing
import com.zerozerowidget.hzos.ui.uiset.UiSetPrimaryButton
import com.zerozerowidget.hzos.ui.uiset.UiSetSecondaryButton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.dialog.BasicDialog
import metavrx.uiset.compose.dialog.DialogAction
import metavrx.uiset.compose.dialog.DialogProgress
import metavrx.uiset.compose.theme.LocalColorScheme
import metavrx.uiset.compose.theme.LocalContentColors
import metavrx.uiset.compose.theme.LocalTypography

/**
 * Horizon sign-in: one button proving the headset's Meta identity to the
 * Worker (`POST /v1/auth/horizon`), then either done, an explicit
 * create/join choice, or iPhone approval polling for a join. The flow
 * itself is HorizonSignInController, which saves the token with the Meta
 * id it was issued for, so a later account switch is detectable. Every failure names its cause; the
 * join fallback (manual code entry) doubles as the path where
 * `send_auth_url` is unavailable.
 */
@Composable
internal fun HorizonSignInSection(
    app: ZeroZeroWidgetApp,
    onSendAuthUrl: (authUrl: String, onSent: (Boolean) -> Unit) -> Unit,
    signInRequest: Int = 0,
    onSignInRequestConsumed: () -> Unit = {}
) {
    // The flow lives in the app, not this panel, so closing Settings while
    // the phone approves does not abandon it (audit C7).
    val signIn = app.horizonSignIn
    val state by signIn.state.collectAsStateWithLifecycle()
    val phase = state.phase
    val userCode = state.userCode
    val verifyUri = state.verifyUri
    val linkSent = state.linkSent
    val error = state.error

    fun begin(choice: String?) = signIn.begin(choice, onSendAuthUrl)

    fun cancel() = signIn.cancel()

    if (!app.horizonAuth.isAvailable) {
        Text(
            "Sign-in needs a Horizon Platform app ID " +
                "(`platformAppId` in hzos/local.properties).",
            style = LocalTypography.current.bodySmall,
            color = LocalContentColors.current.secondary
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
                Text(
                    it,
                    style = LocalTypography.current.bodySmall,
                    color = LocalColorScheme.current.negative.content
                )
            }
            UiSetPrimaryButton("Sign in", onClick = { begin(null) })
        }

        HorizonPhase.PROVING -> {
            Text("Signing in…", style = LocalTypography.current.body)
            UiSetSecondaryButton("Cancel", onClick = ::cancel)
        }

        HorizonPhase.CHOICE -> {
            // Said here rather than by choosing silently: a new account and
            // someone else's existing one are different tenants, and only
            // the operator knows which this headset should join.
            Text(
                "This headset isn't linked to an account yet.",
                style = LocalTypography.current.body
            )
            Text(
                "Creating an account uses this headset's own Meta identity — " +
                    "nothing to approve on your phone.",
                style = LocalTypography.current.bodySmall,
                color = LocalContentColors.current.secondary
            )
            UiSetPrimaryButton(
                "Create a new account",
                onClick = { begin("create") },
                modifier = Modifier.fillMaxWidth()
            )
            Text(
                "Already have an account? Join it here — you'll approve the link on your iPhone.",
                style = LocalTypography.current.bodySmall,
                color = LocalContentColors.current.secondary
            )
            // UiSet labels are plain strings, so the bold brand phrase
            // becomes its own text: a wrapping row that reads as one
            // sentence and taps like the doors elsewhere in Settings.
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable(role = Role.Button, onClick = { begin("join_apple") })
                    .heightIn(min = MIN_ROW_HEIGHT)
                    .padding(vertical = spacing.medium),
                verticalAlignment = Alignment.CenterVertically
            ) {
                FlowRow(Modifier.weight(1f)) {
                    Text(
                        "Use an existing ",
                        style = LocalTypography.current.body
                    )
                    Text(
                        "Sign in with Apple",
                        style = LocalTypography.current.body.copy(
                            fontWeight = FontWeight.Bold
                        )
                    )
                    Text(
                        " account",
                        style = LocalTypography.current.body
                    )
                }
                Text(
                    ">",
                    style = LocalTypography.current.body,
                    color = LocalContentColors.current.secondary,
                    modifier = Modifier.padding(start = spacing.small)
                )
            }
            UiSetSecondaryButton("Cancel", onClick = ::cancel)
        }

        HorizonPhase.WAITING -> {
            // A UI Set dialog rather than inline text: it sits centred, where
            // gaze targeting is most reliable, with one large Cancel — Meta's
            // eyes guidance asks for an explicit dismiss, so tapping outside
            // does nothing. The two steps are sending to the phone, then
            // waiting for the approval there.
            val status = when (linkSent) {
                null -> "Sending to your phone…"
                true -> "Approval sent to your Horizon mobile app — tap the notification."
                false -> "Phone request wasn't sent. Enter the code at $verifyUri."
            }
            Text("Waiting for approval…", style = LocalTypography.current.body)
            BasicDialog(
                title = "Approve on your phone",
                description = "$status\n\nCode: $userCode",
                primaryAction = DialogAction(label = "Cancel", onClick = ::cancel),
                onDismissRequest = {},
                progress = DialogProgress(
                    currentStep = if (linkSent ==
                        true
                    ) {
                        2
                    } else {
                        1
                    },
                    totalSteps = 2
                )
            )
        }
    }
}
