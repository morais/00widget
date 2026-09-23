package com.example.zerozerowidget.hzos.data

import com.example.zerozerowidget.hzos.auth.MetaIdentity
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Pure decision logic for Horizon-identity sign-in (`POST /v1/auth/horizon`)
 * and browser-approval (`POST /v1/auth/horizon/browser/approve`).
 *
 * Deliberately free of Android, Platform SDK, and network types so the
 * whole matrix — returning user, create, join, proof retry, account
 * switch, browser approval — runs as plain JVM unit tests. The UI and the
 * HTTP layer only supply lambdas and render outcomes.
 */
@Serializable
data class HorizonSignInRequest(
    @SerialName("userId") val userId: String,
    @SerialName("userProof") val userProof: String,
    @SerialName("choice") val choice: String? = null,
)

private val horizonJson = Json {
    ignoreUnknownKeys = true
    // A null choice must be OMISSION, not JSON null: the server reads an
    // explicit null as an invalid choice rather than as "no choice yet".
    explicitNulls = false
}

/** Encodes the sign-in body. A null [choice] is omitted, never sent null. */
fun horizonSignInBody(userId: String, userProof: String, choice: String?): String =
    horizonJson.encodeToString(
        HorizonSignInRequest.serializer(),
        HorizonSignInRequest(userId, userProof, choice),
    )

sealed interface HorizonOutcome {
    /** Verified and credentialed: store the token against [userId]. */
    data class SignedIn(val token: String, val userId: String) : HorizonOutcome

    /** Unknown Meta id: the user must pick create or join_apple. */
    data object NeedChoice : HorizonOutcome

    /** join_apple answered with a device code: deliver + poll it. */
    data class JoinCode(val code: DeviceCodeResponse) : HorizonOutcome

    /** Terminal, with text the UI shows as-is. */
    data class Failed(val message: String) : HorizonOutcome
}

sealed interface HorizonStep {
    data class Done(val outcome: HorizonOutcome) : HorizonStep

    /** The proof was single-use and got burned: retry once with a fresh one. */
    data object RetryWithFreshProof : HorizonStep
}

/**
 * Maps one `POST /v1/auth/horizon` answer onto the next step.
 * [proofAttempt] is 0-based; only the first attempt may retry, so a
 * persistently replayed proof fails instead of looping forever.
 */
fun classifyHorizonSignIn(
    userId: String,
    httpCode: Int,
    body: String,
    proofAttempt: Int,
): HorizonStep {
    if (httpCode == 201) {
        val token = stringField(body, "token")
        if (stringField(body, "status") == "signed_in" && !token.isNullOrBlank()) {
            return HorizonStep.Done(HorizonOutcome.SignedIn(token, userId))
        }
        try {
            val code = horizonJson.decodeFromString<DeviceCodeResponse>(body)
            if (code.deviceCode.isNotBlank() && code.userCode.isNotBlank()) {
                return HorizonStep.Done(HorizonOutcome.JoinCode(code))
            }
        } catch (_: Exception) {
            // Falls through to the unexpected-answer failure below.
        }
        return HorizonStep.Done(
            HorizonOutcome.Failed("The server's answer wasn't a sign-in. Update the Worker."),
        )
    }
    if (httpCode == 200 && stringField(body, "status") == "choice_required") {
        return HorizonStep.Done(HorizonOutcome.NeedChoice)
    }
    if (httpCode == 409 && proofAttempt == 0 && body.contains("already been used")) {
        return HorizonStep.RetryWithFreshProof
    }
    val message = when (httpCode) {
        404 -> "This Worker is too old for Horizon sign-in — update it."
        401 -> "Meta could not verify this headset user."
        409 -> "That proof was already used — sign in again."
        429 -> "Rate limited — try again shortly."
        503 -> "Horizon sign-in isn't configured on this server."
        else -> serverError(body) ?: "Sign-in failed (HTTP $httpCode)."
    }
    return HorizonStep.Done(HorizonOutcome.Failed(message))
}

/**
 * Runs the sign-in attempt loop: fresh [MetaIdentity] per attempt (Meta
 * nonces are single-use), at most one proof retry. [request] performs the
 * HTTP call and returns raw (status, body).
 */
suspend fun runHorizonSignIn(
    identity: suspend () -> MetaIdentity?,
    request: suspend (userId: String, userProof: String, choice: String?) -> Pair<Int, String>,
    choice: String? = null,
): HorizonOutcome {
    repeat(2) { attempt ->
        val id = identity()
            ?: return HorizonOutcome.Failed(
                "Couldn't read this headset's Meta user. Check the Platform app ID.",
            )
        val (code, body) = request(id.userId, id.userProof, choice)
        when (val step = classifyHorizonSignIn(id.userId, code, body, attempt)) {
            is HorizonStep.Done -> return step.outcome
            HorizonStep.RetryWithFreshProof -> { /* loop fetches a fresh identity */ }
        }
    }
    return HorizonOutcome.Failed("Sign-in failed — try again.")
}

/**
 * True when the stored session belongs to a different Meta user than the
 * one wearing the headset now. Blank stored ids (legacy sessions) and
 * unreadable current ids never count — only a present-and-different pair
 * clears a token.
 */
fun isMetaUserSwitch(storedUserId: String, currentUserId: String?): Boolean =
    storedUserId.isNotBlank() && !currentUserId.isNullOrBlank() && storedUserId != currentUserId

/** What Settings may offer for the account's login identities. */
enum class AccountIdAction { NONE, DELETE, UNLINK }

/**
 * Delete when Horizon is the only way in; unlink when another identity
 * survives the removal (Apple or anything else — the rule is about what
 * remains, not its name). Empty or Horizon-less lists offer nothing: no
 * link, nothing to do; no data (older Workers), case undeterminable.
 */
fun accountIdAction(providers: List<String>): AccountIdAction {
    if (!providers.contains("horizon")) return AccountIdAction.NONE
    return if (providers.any { it != "horizon" }) AccountIdAction.UNLINK else AccountIdAction.DELETE
}

/**
 * Maps one browser-approval answer onto UI text. Success echoes the
 * decision the user made; failures name the cause.
 */
fun describeBrowserApproval(httpCode: Int, body: String, approved: Boolean): String {
    if (httpCode in 200..299) {
        return if (approved) "Browser sign-in approved." else "Browser sign-in denied."
    }
    return when (httpCode) {
        404 -> "That code is invalid or expired."
        409 -> "That code has already been used."
        403 -> "This account isn't linked to a Horizon identity."
        429 -> "Rate limited — try again shortly."
        else -> serverError(body) ?: "Approval failed (HTTP $httpCode)."
    }
}

private fun stringField(body: String, name: String): String? = try {
    horizonJson.parseToJsonElement(body).jsonObject[name]
        ?.jsonPrimitive?.let { if (it.isString) it.content else null }
} catch (_: Exception) {
    null
}

private fun serverError(body: String): String? =
    stringField(body, "error")?.takeIf { it.isNotBlank() }
