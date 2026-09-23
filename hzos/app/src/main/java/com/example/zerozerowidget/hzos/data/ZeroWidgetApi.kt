package com.example.zerozerowidget.hzos.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.net.URLEncoder

/**
 * Minimal HTTP client for the 00Widget Worker API. No SDK, no codegen — one
 * `fetch` per endpoint, mirroring `APIClient.swift`.
 *
 * Auth: `Authorization: Bearer <API_KEY>` on everything but `/health`.
 * Read-only by default: this client only calls `read`-scoped routes plus
 * safe action runs. Publishing cards from the headset is out of scope.
 */
class ZeroWidgetApi(
    private val http: OkHttpClient,
    baseUrl: String,
    private val apiKey: String,
) {
    private val base = baseUrl.trimEnd('/')
    val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        explicitNulls = false
    }

    class ApiException(val status: Int, message: String) : IOException(message)

    suspend fun health(): Boolean {
        val code = getRaw("/health").use { it.code }
        return code == 200
    }

    suspend fun fetchDashboard(): DashboardResponse =
        get("/v1/dashboard")

    suspend fun fetchCards(): List<DashboardCard> =
        get<CardsListResponse>("/v1/cards").cards

    suspend fun fetchLiveActivities(): List<LiveActivitySession> =
        get<LiveActivitiesListResponse>("/v1/live-activities").activities

    /**
     * Runs one action button press. Callers must check
     * [ActionDefinition.isSafeFromPanel] first — the server also enforces it,
     * and a 403 naming the required scope means this credential cannot run it.
     */
    suspend fun runAction(actionId: String, cardId: String?) {
        val body = json.encodeToString(
            ActionRunBody.serializer(),
            ActionRunBody(ActionRunContext(cardId)),
        )
        postEmpty("/v1/actions/${pathSegment(actionId)}/run", body)
    }

    /**
     * Deletes a card / ends an activity. Both routes require the `publish`
     * scope, which a device-preset token does NOT have — callers surface
     * the 403 honestly instead of hiding the button's limits.
     */
    suspend fun deleteCard(id: String) {
        delete("/v1/cards/${pathSegment(id)}")
    }

    suspend fun endActivity(externalActivityId: String) {
        val body = "{\"externalActivityId\":${json.encodeToString(externalActivityId)}}"
        postEmpty("/v1/live-activities/end", body)
    }

    /**
     * Active MCP grants: lifecycle/display metadata only, never tokens.
     * Mirrors APIClient.listMCPConnections / disconnectMCPConnection.
     * Main-safe (IO-dispatched) so panels can call straight from compose
     * scopes — blocking OkHttp on Main throws NetworkOnMainThreadException.
     */
    suspend fun listMCPConnections(): List<MCPConnectionSummary> =
        withContext(Dispatchers.IO) {
            get<MCPConnectionsListResponse>("/v1/account/mcp-connections").connections
        }

    suspend fun disconnectMCPConnection(id: String) {
        withContext(Dispatchers.IO) {
            delete("/v1/account/mcp-connections/${pathSegment(id)}")
        }
    }

    /**
     * Replaces every publisher token the account's agents publish with with
     * one fresh token. Mirrors iOS rotateAgentToken. Safe to call on the
     * device credential: the server only revokes `publisher`/`agent`
     * purpose keys, so this headset stays signed in. The replacement is
     * shown once — callers must surface it, there is no second read.
     */
    suspend fun rotateAgentToken(): AgentTokenRotation =
        withContext(Dispatchers.IO) {
            post("/v1/auth/agent-token/rotate")
        }

    /**
     * Who this device is signed in as. App-credential only, which the
     * Horizon device token is — agent publisher tokens cannot read it.
     * Mirrors iOS refreshAccount.
     */
    suspend fun fetchAccount(): AccountInfo =
        withContext(Dispatchers.IO) {
            get<AccountResponse>("/v1/account").account
        }

    /**
     * Subscription status for the Settings row. Null when the server has
     * subscriptions switched off (404) or cannot answer — the row hides
     * itself rather than erroring.
     */
    suspend fun fetchSubscription(): SubscriptionState? =
        withContext(Dispatchers.IO) {
            try {
                get<SubscriptionResponse>("/v1/subscription").subscription
            } catch (e: ApiException) {
                null
            }
        }

    /**
     * Hands a completed Meta purchase to the Worker for verification.
     *
     * Proposed client→server contract (server implements
     * `POST /v1/meta/subscription/sync`):
     * - Request `{ "userId", "sku" }`: the *app-scoped* Meta user id (stable
     *   for this app, meaningless outside it) plus the purchased SKU verbatim,
     *   subscription terms included (`…:SUBSCRIPTION__MONTHLY`).
     * - Response is the same [SubscriptionResponse] shape as
     *   `GET /v1/subscription`; the Worker verifies via Meta S2S
     *   (`viewer_purchases`/`verify_entitlement`) and answers with the merged
     *   entitlement. Unknown fields are ignored, so the server may extend it.
     * - 404 while the endpoint does not exist yet surfaces as [ApiException];
     *   callers map that to "update the Worker", not to a purchase failure.
     */
    suspend fun syncMetaSubscription(userId: String, sku: String): SubscriptionState =
        withContext(Dispatchers.IO) {
            val body = json.encodeToString(
                MetaSubscriptionSyncRequest.serializer(),
                MetaSubscriptionSyncRequest(userId, sku),
            )
            post<SubscriptionResponse>("/v1/meta/subscription/sync", body).subscription
        }

    /**
     * One `POST /v1/auth/horizon` attempt, raw. Returns (status, body) for
     * [classifyHorizonSignIn], which owns retries and mapping — this layer
     * throws only on transport failure. The body comes from
     * [horizonSignInBody]; a null choice is omitted, never sent null.
     */
    suspend fun postHorizonSignIn(body: String): Pair<Int, String> =
        withContext(Dispatchers.IO) {
            // Pre-credential by definition: no Authorization header at all,
            // not an empty Bearer one.
            postRaw("/v1/auth/horizon", body, withAuth = false)
        }

    /**
     * Answers a browser sign-in code (`POST
     * /v1/auth/horizon/browser/approve`) on the app credential. Returns raw
     * (status, body) for [describeBrowserApproval]. [decision] is "approve"
     * or "deny".
     */
    suspend fun approveBrowserSignIn(code: String, decision: String): Pair<Int, String> =
        withContext(Dispatchers.IO) {
            val body = "{\"code\":${json.encodeToString(code)},\"decision\":${json.encodeToString(decision)}}"
            postRaw("/v1/auth/horizon/browser/approve", body)
        }

    /**
     * Deletes the whole tenant (`DELETE /v1/account`) on the app
     * credential. Irreversible by design; the caller confirms first and
     * clears the local store after, since the token dies with the account.
     */
    suspend fun deleteAccount() =
        withContext(Dispatchers.IO) {
            delete("/v1/account")
        }

    /**
     * Detaches the Horizon identity (`DELETE /v1/account/horizon`) on the
     * app credential, for accounts that also sign in elsewhere. Returns raw
     * (status, body): 404 while the endpoint does not exist yet, 409 when
     * Horizon is the only identity (delete instead), and success otherwise.
     * The caller clears the local store after, since the session dies with
     * the link.
     */
    suspend fun unlinkHorizonAccount(): Pair<Int, String> =
        withContext(Dispatchers.IO) {
            deleteRaw("/v1/account/horizon")
        }

    // --- internals ---

    private inline fun <reified T> parse(raw: String): T =
        json.decodeFromString(raw)

    private fun authed(path: String): Request.Builder =
        Request.Builder()
            .url(base + path)
            .header("Authorization", "Bearer $apiKey")
            .header("Accept", "application/json")

    private fun getRaw(path: String): okhttp3.Response {
        val req = authed(path).get().build()
        val resp = http.newCall(req).execute()
        if (resp.code !in 200..299) {
            val msg = resp.body?.string().orEmpty()
            resp.close()
            throw ApiException(resp.code, msg.ifEmpty { "HTTP ${resp.code}" })
        }
        return resp
    }

    private inline fun <reified T> get(path: String): T {
        getRaw(path).use { resp ->
            return parse(resp.body?.string().orEmpty())
        }
    }

    private inline fun <reified T> post(path: String, jsonBody: String = "{}"): T {
        val req = authed(path)
            .post(jsonBody.toRequestBody("application/json".toMediaType()))
            .build()
        http.newCall(req).execute().use { resp ->
            if (resp.code !in 200..299) {
                val msg = resp.body?.string().orEmpty()
                throw ApiException(resp.code, msg.ifEmpty { "HTTP ${resp.code}" })
            }
            return parse(resp.body?.string().orEmpty())
        }
    }

    /** Raw POST: status plus body, throwing only when nothing answered. */
    private fun postRaw(path: String, jsonBody: String, withAuth: Boolean = true): Pair<Int, String> {
        val builder = Request.Builder()
            .url(base + path)
            .header("Accept", "application/json")
        if (withAuth) builder.header("Authorization", "Bearer $apiKey")
        val req = builder
            .post(jsonBody.toRequestBody("application/json".toMediaType()))
            .build()
        http.newCall(req).execute().use { resp ->
            return resp.code to resp.body?.string().orEmpty()
        }
    }

    /** Raw DELETE: status plus body, throwing only when nothing answered. */
    private fun deleteRaw(path: String): Pair<Int, String> {
        val req = authed(path).delete().build()
        http.newCall(req).execute().use { resp ->
            return resp.code to resp.body?.string().orEmpty()
        }
    }
    private fun postEmpty(path: String, jsonBody: String) {
        val req = authed(path)
            .post(jsonBody.toRequestBody("application/json".toMediaType()))
            .build()
        http.newCall(req).execute().use { resp ->
            if (resp.code !in 200..299) {
                val msg = resp.body?.string().orEmpty()
                throw ApiException(resp.code, msg.ifEmpty { "HTTP ${resp.code}" })
            }
        }
    }

    private fun delete(path: String) {
        val req = authed(path).delete().build()
        http.newCall(req).execute().use { resp ->
            if (resp.code !in 200..299) {
                val msg = resp.body?.string().orEmpty()
                throw ApiException(resp.code, msg.ifEmpty { "HTTP ${resp.code}" })
            }
        }
    }

    companion object {
        /** Mirrors APIClient.pathSegment: one escaped path segment. */
        fun pathSegment(value: String): String =
            URLEncoder.encode(value, Charsets.UTF_8.name()).replace("+", "%20")
    }
}

/** Answer to POST /v1/auth/agent-token/rotate. Unknown fields ignored. */
@Serializable
data class AgentTokenRotation(
    val token: String = "",
    val revokedAgentTokens: Int = 0,
)

/** Answer to GET /v1/account. Mirrors the server's account shape. */
@Serializable
data class AccountResponse(
    val account: AccountInfo = AccountInfo(),
)

@Serializable
data class AccountInfo(
    val tenantId: String = "",
    val ownerEmail: String? = null,
    val displayName: String? = null,
    val isReviewTenant: Boolean = false,
    /**
     * Linked login identities. Absent on Workers predating the field —
     * callers must offer neither delete nor unlink then, since the case
     * cannot be determined.
     */
    val identities: List<AccountIdentity> = emptyList(),
)

@Serializable
data class AccountIdentity(
    val provider: String = "",
)

/** Answer to GET /v1/subscription. Mirrors SubscriptionState server-side. */
@Serializable
data class SubscriptionResponse(
    val subscription: SubscriptionState = SubscriptionState(),
    val required: Boolean = false,
)

/** Body of POST /v1/meta/subscription/sync. See [ZeroWidgetApi.syncMetaSubscription]. */
@Serializable
data class MetaSubscriptionSyncRequest(
    val userId: String,
    val sku: String,
)

@Serializable
data class SubscriptionState(
    val status: String = "none",
    val active: Boolean = false,
    val productId: String? = null,
    val expiresAt: String? = null,
    val autoRenew: Boolean? = null,
    val environment: String? = null,
) {
    /**
     * One label for the Settings row. Ports iOS displayLabel: five
     * statuses do not collapse into active/not, which told lapsed
     * subscribers they had never subscribed. Unknown reads as none.
     */
    val displayLabel: String
        get() = when (status) {
            "active" -> "Active"
            "trial" -> "Free trial"
            "grace" -> "Payment issue"
            "expired" -> "Expired"
            "revoked" -> "Refunded"
            else -> "Not subscribed"
        }

    /** Grace, expiry and refund are worth flagging; the rest are not. */
    val needsAttention: Boolean
        get() = status == "grace" || status == "expired" || status == "revoked"
}
