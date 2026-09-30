package com.zerozerowidget.hzos.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.zerozerowidget.hzos.BuildConfig
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.connectionDataStore by preferencesDataStore(name = "connection")

/**
 * Where the Worker URL, API key, and Meta user id live. The Meta id is
 * saved alongside the token at sign-in so a later Meta account switch is
 * detectable: same headset, different operator, old token must go.
 *
 * The key is stored in DataStore encrypted by [cipher] (a Keystore key by
 * default, audit S2); never log it, never put it in a panel title, and
 * never send it anywhere but the configured base URL.
 * The Meta user id is an opaque identity string, not a secret, but it is
 * still only ever sent to the configured base URL.
 */
class ConnectionStore(
    private val dataStore: DataStore<Preferences>,
    private val cipher: SecretCipher = KeystoreSecretCipher()
) : ConnectionSource {
    constructor(context: Context) : this(context.connectionDataStore)

    /**
     * [apiKey] is this headset's own credential, never shown or copied: it is
     * an app credential, which can delete the account. [agentKey] is the
     * separate publisher token Agent config hands to agents (read, publish,
     * webhooks), blank until the Worker issues one at sign-in or a rotation
     * creates one.
     */
    data class Connection(
        val baseUrl: String,
        val apiKey: String,
        val metaUserId: String = "",
        val agentKey: String = ""
    ) {
        val isConfigured: Boolean get() = baseUrl.isNotBlank() && apiKey.isNotBlank()
    }

    companion object {
        private val BASE_URL = stringPreferencesKey("base_url")

        private val API_KEY_ENCRYPTED = stringPreferencesKey("api_key_enc")
        private val META_USER_ID = stringPreferencesKey("meta_user_id")
        private val AGENT_KEY_ENCRYPTED = stringPreferencesKey("agent_key_enc")

        /**
         * The Worker URL as stored: trimmed, https assumed when no scheme is
         * given, and https only. Cleartext is blocked at runtime anyway
         * (targetSdk 34, no network security config), so an http URL would
         * save and then fail on every request.
         */
        fun normalizeBaseUrl(raw: String): String? {
            val trimmed = raw.trim().trimEnd('/')
            if (trimmed.isEmpty()) return null
            val withScheme = if ("://" in trimmed) trimmed else "https://$trimmed"
            val scheme = withScheme.substringBefore("://").lowercase()
            val host = withScheme.substringAfter("://").substringBefore('/').substringBefore(':')
            if (host.isEmpty()) return null
            return withScheme.takeIf { scheme == "https" }
        }

        /**
         * The Worker URL requests go to: the saved one, else the build's
         * default, normalised either way. Null when neither resolves. The
         * one place this rule lives — seven hand copies of it had drifted.
         */
        fun effectiveBaseUrl(
            stored: String,
            default: String = BuildConfig.DEFAULT_BASE_URL
        ): String? = normalizeBaseUrl(stored.ifBlank { default })
    }

    override val connection: Flow<Connection> =
        dataStore.data.map { prefs ->
            Connection(
                baseUrl = prefs[BASE_URL].orEmpty(),
                // Undecryptable (the Keystore key is gone): signed out.
                apiKey = prefs[API_KEY_ENCRYPTED]?.let(cipher::decrypt).orEmpty(),
                metaUserId = prefs[META_USER_ID].orEmpty(),
                agentKey = prefs[AGENT_KEY_ENCRYPTED]?.let(cipher::decrypt).orEmpty()
            )
        }

    override suspend fun current(): Connection = connection.first()

    suspend fun save(baseUrl: String, apiKey: String, metaUserId: String = "", agentKey: String = "") {
        dataStore.edit { prefs ->
            prefs[BASE_URL] = baseUrl.trim().trimEnd('/')
            if (apiKey.isNotBlank()) {
                prefs[API_KEY_ENCRYPTED] = cipher.encrypt(apiKey.trim())
            } else {
                prefs.remove(API_KEY_ENCRYPTED)
            }
            if (metaUserId.isNotBlank()) {
                prefs[META_USER_ID] = metaUserId.trim()
            } else {
                prefs.remove(META_USER_ID)
            }
            if (agentKey.isNotBlank()) {
                prefs[AGENT_KEY_ENCRYPTED] = cipher.encrypt(agentKey.trim())
            } else {
                prefs.remove(AGENT_KEY_ENCRYPTED)
            }
        }
    }

    /** Stores the agent token a rotation just created (see [Connection.agentKey]). */
    suspend fun saveAgentKey(agentKey: String) {
        dataStore.edit { prefs ->
            if (agentKey.isNotBlank()) {
                prefs[AGENT_KEY_ENCRYPTED] = cipher.encrypt(agentKey.trim())
            } else {
                prefs.remove(AGENT_KEY_ENCRYPTED)
            }
        }
    }

    suspend fun clear() {
        dataStore.edit { prefs ->
            prefs.remove(BASE_URL)
            prefs.remove(API_KEY_ENCRYPTED)
            prefs.remove(META_USER_ID)
            prefs.remove(AGENT_KEY_ENCRYPTED)
        }
    }

    /**
     * Points the app at [newBaseUrl] (already normalised). A credential is
     * only ever sent to the server that issued it, so a change of origin —
     * host or port — signs out, dropping the key and its Meta id; the same
     * origin with another path keeps the session (audit S4). Returns true
     * when it signed out. [defaultBaseUrl] is what an unset URL resolves to.
     */
    suspend fun changeServer(
        newBaseUrl: String,
        defaultBaseUrl: String = BuildConfig.DEFAULT_BASE_URL
    ): Boolean {
        val current = current()
        val oldOrigin = effectiveBaseUrl(current.baseUrl, defaultBaseUrl)?.let(::originOf)
        val keep = current.apiKey.isNotBlank() && oldOrigin == originOf(newBaseUrl)
        if (keep) save(newBaseUrl, current.apiKey, current.metaUserId, current.agentKey) else save(newBaseUrl, "", "")
        return !keep && current.apiKey.isNotBlank()
    }

    private fun originOf(url: String): String? = runCatching {
        val uri = java.net.URI(url)
        "${uri.scheme?.lowercase()}://${uri.host?.lowercase()}:${uri.port}"
    }.getOrNull()
}
