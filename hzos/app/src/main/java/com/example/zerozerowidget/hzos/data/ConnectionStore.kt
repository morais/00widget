package com.example.zerozerowidget.hzos.data

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.connectionDataStore by preferencesDataStore(name = "connection")

/**
 * Where the Worker URL + API key live until real login exists. The URL is
 * edited on the developer screen (Options panel); the key arrives only
 * through the device flow.
 *
 * AUTH TODO (do not grow this file into a login system — replace it):
 * Horizon OS has no Sign in with Apple equivalent to reuse, and the Worker's
 * `/login` web flow expects an Apple identity the headset cannot mint. The
 * likely shape is a device-code / pairing flow: the headset shows a short
 * code, the operator approves it in the iOS app or `/admin`, the Worker
 * returns a tenant API token, and that token lands in these same two keys.
 * Delivery of the approval URL uses the platform `send_auth_url` Login API
 * when a Platform app ID is configured (see auth/HorizonAuth) — the manual
 * code display remains as the fallback for older OS versions.
 * Until then: paste a tenant API token with the `device` preset
 * (`/admin` → tenant → device) into the settings panel.
 * The key is stored in DataStore (app-private); never log it, never put it
 * in a panel title, and never send it anywhere but the configured base URL.
 */
class ConnectionStore(private val context: Context) {

    data class Connection(val baseUrl: String, val apiKey: String) {
        val isConfigured: Boolean get() = baseUrl.isNotBlank() && apiKey.isNotBlank()
    }

    companion object {
        private val BASE_URL = stringPreferencesKey("base_url")
        private val API_KEY = stringPreferencesKey("api_key")

        /** http:// is dev-only (emulator/host tunnel); release builds require https://. */
        fun normalizeBaseUrl(raw: String): String? {
            val trimmed = raw.trim().trimEnd('/')
            if (trimmed.isEmpty()) return null
            val withScheme = if ("://" in trimmed) trimmed else "https://$trimmed"
            val scheme = withScheme.substringBefore("://").lowercase()
            val host = withScheme.substringAfter("://").substringBefore('/').substringBefore(':')
            if (host.isEmpty()) return null
            if (scheme == "https") return withScheme
            if (scheme == "http" && isLocalHost(host)) return withScheme
            return null
        }

        private fun isLocalHost(host: String): Boolean {
            val h = host.lowercase()
            return h == "localhost" || h == "127.0.0.1" || h == "10.0.2.2" || h.endsWith(".localhost")
        }
    }

    val connection: Flow<Connection> =
        context.connectionDataStore.data.map { prefs ->
            Connection(
                baseUrl = prefs[BASE_URL].orEmpty(),
                apiKey = prefs[API_KEY].orEmpty(),
            )
        }

    suspend fun current(): Connection = connection.first()

    suspend fun save(baseUrl: String, apiKey: String) {
        context.connectionDataStore.edit { prefs ->
            prefs[BASE_URL] = baseUrl.trim().trimEnd('/')
            prefs[API_KEY] = apiKey.trim()
        }
    }

    suspend fun clear() {
        context.connectionDataStore.edit { prefs ->
            prefs.remove(BASE_URL)
            prefs.remove(API_KEY)
        }
    }
}
