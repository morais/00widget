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

    data class Connection(val baseUrl: String, val apiKey: String, val metaUserId: String = "") {
        val isConfigured: Boolean get() = baseUrl.isNotBlank() && apiKey.isNotBlank()
    }

    companion object {
        private val BASE_URL = stringPreferencesKey("base_url")

        /** Legacy plaintext key; read once by [migrate], then removed. */
        private val API_KEY = stringPreferencesKey("api_key")
        private val API_KEY_ENCRYPTED = stringPreferencesKey("api_key_enc")
        private val META_USER_ID = stringPreferencesKey("meta_user_id")

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
                metaUserId = prefs[META_USER_ID].orEmpty()
            )
        }

    override suspend fun current(): Connection = connection.first()

    suspend fun save(baseUrl: String, apiKey: String, metaUserId: String = "") {
        dataStore.edit { prefs ->
            prefs[BASE_URL] = baseUrl.trim().trimEnd('/')
            if (apiKey.isNotBlank()) {
                prefs[API_KEY_ENCRYPTED] = cipher.encrypt(apiKey.trim())
            } else {
                prefs.remove(API_KEY_ENCRYPTED)
            }
            prefs.remove(API_KEY)
            if (metaUserId.isNotBlank()) {
                prefs[META_USER_ID] = metaUserId.trim()
            } else {
                prefs.remove(META_USER_ID)
            }
        }
    }

    suspend fun clear() {
        dataStore.edit { prefs ->
            prefs.remove(BASE_URL)
            prefs.remove(API_KEY)
            prefs.remove(API_KEY_ENCRYPTED)
            prefs.remove(META_USER_ID)
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
        if (keep) save(newBaseUrl, current.apiKey, current.metaUserId) else save(newBaseUrl, "", "")
        return !keep && current.apiKey.isNotBlank()
    }

    private fun originOf(url: String): String? = runCatching {
        val uri = java.net.URI(url)
        "${uri.scheme?.lowercase()}://${uri.host?.lowercase()}:${uri.port}"
    }.getOrNull()

    /**
     * Moves a plaintext key written by an older build into encrypted
     * storage. Run once at startup; a no-op when there is nothing to move.
     */
    suspend fun migrate() {
        dataStore.edit { prefs ->
            val plain = prefs[API_KEY] ?: return@edit
            if (plain.isNotBlank()) prefs[API_KEY_ENCRYPTED] = cipher.encrypt(plain)
            prefs.remove(API_KEY)
        }
    }
}
