package com.example.zerozerowidget.hzos.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
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
