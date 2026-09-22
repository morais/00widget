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
 * Where the Worker URL, API key, and Meta user id live. The Meta id is
 * saved alongside the token at sign-in so a later Meta account switch is
 * detectable: same headset, different operator, old token must go.
 *
 * The key is stored in DataStore (app-private); never log it, never put it
 * in a panel title, and never send it anywhere but the configured base URL.
 * The Meta user id is an opaque identity string, not a secret, but it is
 * still only ever sent to the configured base URL.
 */
class ConnectionStore(private val context: Context) {

    data class Connection(val baseUrl: String, val apiKey: String, val metaUserId: String = "") {
        val isConfigured: Boolean get() = baseUrl.isNotBlank() && apiKey.isNotBlank()
    }

    companion object {
        private val BASE_URL = stringPreferencesKey("base_url")
        private val API_KEY = stringPreferencesKey("api_key")
        private val META_USER_ID = stringPreferencesKey("meta_user_id")

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
                metaUserId = prefs[META_USER_ID].orEmpty(),
            )
        }

    suspend fun current(): Connection = connection.first()

    suspend fun save(baseUrl: String, apiKey: String, metaUserId: String = "") {
        context.connectionDataStore.edit { prefs ->
            prefs[BASE_URL] = baseUrl.trim().trimEnd('/')
            prefs[API_KEY] = apiKey.trim()
            if (metaUserId.isNotBlank()) {
                prefs[META_USER_ID] = metaUserId.trim()
            } else {
                prefs.remove(META_USER_ID)
            }
        }
    }

    suspend fun clear() {
        context.connectionDataStore.edit { prefs ->
            prefs.remove(BASE_URL)
            prefs.remove(API_KEY)
            prefs.remove(META_USER_ID)
        }
    }
}
