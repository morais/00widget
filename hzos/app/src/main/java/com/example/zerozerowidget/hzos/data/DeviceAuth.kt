package com.example.zerozerowidget.hzos.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException

/**
 * RFC 8628 (OAuth Device Authorization Grant) client against the 00Widget
 * Worker — the server half of the `send_auth_url` login flow.
 *
 * Server contract (NOT IMPLEMENTED YET — see hzos/README.md "Login"):
 * - `POST /v1/auth/device/code` (no auth) → [DeviceCodeResponse]
 * - `POST /v1/auth/device/token` (no auth, {device_code}) → [DeviceTokenResponse]
 *   with `error: "authorization_pending" | "slow_down" | "expired" | "denied"`,
 *   or `token` (a `device`-preset API key) once approved.
 *
 * Until the server implements it, requesting a code fails (404) and the UI
 * falls back to manual paste. Nothing here depends on Meta APIs; the
 * `send_auth_url` delivery call lives in [com.example.zerozerowidget.hzos.auth.HorizonAuth].
 */
@Serializable
data class DeviceCodeResponse(
    @SerialName("device_code") val deviceCode: String,
    @SerialName("user_code") val userCode: String,
    @SerialName("verification_uri") val verificationUri: String,
    // Pre-filled URI (RFC 8628 verification_uri_complete). This is what goes
    // to send_auth_url. Falls back to verification_uri + user_code display.
    @SerialName("verification_uri_complete") val verificationUriComplete: String? = null,
    @SerialName("expires_in") val expiresInSeconds: Int = 600,
    @SerialName("interval") val intervalSeconds: Int = 5,
) {
    val completeUri: String
        get() = verificationUriComplete ?: "$verificationUri?code=$userCode"
}

@Serializable
private data class DeviceTokenRequest(
    @SerialName("device_code") val deviceCode: String,
)

@Serializable
data class DeviceTokenResponse(
    // Present once approved: the API token to store in ConnectionStore.
    val token: String? = null,
    // RFC 8628 errors while pending: authorization_pending | slow_down |
    // expired | denied. Absent (with a token) means approved.
    val error: String? = null,
)

class DeviceFlowUnsupportedException(message: String) : IOException(message)
class DeviceFlowDeniedException : IOException("Sign-in was denied on the other device.")
class DeviceFlowExpiredException : IOException("The sign-in code expired. Request a new one.")

class DeviceAuthApi(http: OkHttpClient, baseUrl: String) {
    private val http: OkHttpClient = http
    private val base: String = baseUrl.trimEnd('/')
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun requestCode(): DeviceCodeResponse =
        post("/v1/auth/device/code", "{}")

    suspend fun pollToken(deviceCode: String): DeviceTokenResponse =
        post("/v1/auth/device/token", json.encodeToString(DeviceTokenRequest.serializer(), DeviceTokenRequest(deviceCode)))

    private suspend inline fun <reified T> post(path: String, body: String): T =
        withContext(Dispatchers.IO) {
            val req = Request.Builder()
                .url(base + path)
                .header("Accept", "application/json")
                .post(body.toRequestBody("application/json".toMediaType()))
                .build()
            http.newCall(req).execute().use { resp ->
                val raw = resp.body?.string().orEmpty()
                if (resp.code == 404) {
                    throw DeviceFlowUnsupportedException(
                        "This server doesn't implement the device flow yet (404). Paste a token manually.",
                    )
                }
                if (resp.code !in 200..299) {
                    throw IOException("HTTP ${resp.code}: ${raw.take(160)}")
                }
                json.decodeFromString(raw)
            }
        }
}

/**
 * Polls until approval, denial, expiry, or [deadlineMs]. Follows the
 * server-advised interval and backs off on `slow_down`, per RFC 8628 §3.5.
 * Returns the API token. Throws [DeviceFlowDeniedException],
 * [DeviceFlowExpiredException], or the underlying [IOException].
 */
suspend fun awaitDeviceToken(
    api: DeviceAuthApi,
    deviceCode: String,
    intervalSeconds: Int,
    deadlineMs: Long,
    onTick: () -> Unit = {},
): String {
    var intervalMs = (intervalSeconds.coerceAtLeast(1)) * 1000L
    while (System.currentTimeMillis() < deadlineMs) {
        delay(intervalMs)
        onTick()
        val resp = api.pollToken(deviceCode)
        resp.token?.takeIf { it.isNotBlank() }?.let { return it }
        when (resp.error) {
            null, "authorization_pending" -> { /* keep waiting */ }
            "slow_down" -> intervalMs += 5000L
            "denied" -> throw DeviceFlowDeniedException()
            "expired" -> throw DeviceFlowExpiredException()
            else -> throw IOException("Sign-in failed: ${resp.error}")
        }
    }
    throw DeviceFlowExpiredException()
}
