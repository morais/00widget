package com.zerozerowidget.hzos.auth

import android.util.Log
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.data.ConnectionStore
import com.zerozerowidget.hzos.data.DeviceAuthApi
import com.zerozerowidget.hzos.data.HorizonOutcome
import com.zerozerowidget.hzos.data.ZeroWidgetApi
import com.zerozerowidget.hzos.data.awaitDeviceToken
import com.zerozerowidget.hzos.data.horizonSignInBody
import com.zerozerowidget.hzos.data.runHorizonSignIn
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class HorizonPhase { IDLE, PROVING, CHOICE, WAITING }

/**
 * Horizon sign-in, owned by the app rather than by the Settings panel
 * (audit C7). Joining an existing account polls for the phone's approval
 * for up to ten minutes; run in the panel's composition scope, closing
 * Settings cancelled the poll, and the approval the phone then granted
 * minted a token nobody collected. The flow now runs in the app scope and
 * saves the token itself; Settings only renders [state].
 */
class HorizonSignInController(private val app: ZeroZeroWidgetApp) {
    data class State(
        val phase: HorizonPhase = HorizonPhase.IDLE,
        val userCode: String = "",
        val verifyUri: String = "",
        val linkSent: Boolean? = null,
        val error: String? = null
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    private var job: Job? = null

    fun cancel() {
        job?.cancel()
        job = null
        _state.update { it.copy(phase = HorizonPhase.IDLE) }
    }

    /**
     * Proves the headset's Meta identity to the Worker, then signs in, asks
     * for a create/join [choice], or — for a join — delivers the device code
     * through [sendAuthUrl] and polls until the phone approves.
     */
    fun begin(choice: String?, sendAuthUrl: (authUrl: String, onSent: (Boolean) -> Unit) -> Unit) {
        val phase = _state.value.phase
        if (phase != HorizonPhase.IDLE && phase != HorizonPhase.CHOICE) return
        _state.update { it.copy(phase = HorizonPhase.PROVING, error = null) }
        job = app.appScope.launch {
            try {
                run(choice, sendAuthUrl)
            } catch (e: CancellationException) {
                _state.update { it.copy(phase = HorizonPhase.IDLE) }
                throw e
            } catch (
                // Any failure must land as a message: this runs in the app
                // scope, where an uncaught exception crashes the app.
                @Suppress("TooGenericExceptionCaught") e: Exception
            ) {
                Log.e(TAG, "sign-in failed: ${e.javaClass.simpleName}: ${e.message}")
                fail((e.message ?: e.javaClass.simpleName).take(200))
            }
        }
    }

    private suspend fun run(choice: String?, sendAuthUrl: (String, (Boolean) -> Unit) -> Unit) {
        val base = ConnectionStore.effectiveBaseUrl(app.connectionStore.current().baseUrl)
            ?: return fail("No Worker URL configured (Developer screen).")
        // Pre-credential: the horizon call sends no Authorization header.
        val unauthed = ZeroWidgetApi(app.http, base, "")
        // The Meta id the latest attempt proved, saved with the token.
        var attemptUserId = ""
        val outcome = runHorizonSignIn(
            identity = { app.horizonAuth.getMetaIdentity() },
            request = { userId, proof, ch ->
                attemptUserId = userId
                unauthed.postHorizonSignIn(horizonSignInBody(userId, proof, ch))
            },
            choice = choice
        )
        when (outcome) {
            is HorizonOutcome.SignedIn -> signedIn(base, outcome.token, outcome.userId)

            HorizonOutcome.NeedChoice -> _state.update { it.copy(phase = HorizonPhase.CHOICE) }

            is HorizonOutcome.Failed -> fail(outcome.message)

            is HorizonOutcome.JoinCode -> {
                val code = outcome.code
                _state.update {
                    it.copy(
                        phase = HorizonPhase.WAITING,
                        userCode = code.userCode,
                        verifyUri = code.verificationUri,
                        linkSent = null
                    )
                }
                sendAuthUrl(code.completeUri) { sent -> _state.update { it.copy(linkSent = sent) } }
                val deadline = System.currentTimeMillis() + minOf(code.expiresInSeconds * 1000L, MAX_WAIT_MS)
                val token = awaitDeviceToken(DeviceAuthApi(app.http, base), code.deviceCode, code.intervalSeconds, deadline)
                signedIn(base, token, attemptUserId)
            }
        }
    }

    private suspend fun signedIn(base: String, token: String, metaUserId: String) {
        app.connectionStore.save(base, token, metaUserId)
        app.repository.refresh()
        _state.value = State()
    }

    private fun fail(message: String) {
        _state.update { it.copy(phase = HorizonPhase.IDLE, error = message) }
    }

    private companion object {
        const val TAG = "HorizonAuth"
        const val MAX_WAIT_MS = 600_000L
    }
}
