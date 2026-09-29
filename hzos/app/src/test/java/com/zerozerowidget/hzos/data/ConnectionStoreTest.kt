package com.zerozerowidget.hzos.data

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The API key at rest (audit S2): encrypted when saved, migrated from an
 * older build's plaintext, and read as signed out when it cannot be
 * decrypted. Plain JVM with a throwaway DataStore file; a reversible fake
 * stands in for the Android Keystore cipher.
 */
class ConnectionStoreTest {
    private val dir: File = createTempDirectory("connection-store").toFile()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val dataStore = PreferenceDataStoreFactory.create(scope = scope) { File(dir, "connection.preferences_pb") }

    private class FakeCipher : SecretCipher {
        override fun encrypt(plain: String) = "enc:" + plain.reversed()
        override fun decrypt(stored: String) = stored.removePrefix("enc:").reversed().takeIf { stored.startsWith("enc:") }
    }

    private class LostKeyCipher : SecretCipher {
        override fun encrypt(plain: String) = "enc:x"
        override fun decrypt(stored: String): String? = null
    }

    private suspend fun raw(name: String): String? = dataStore.data.first()[stringPreferencesKey(name)]

    @After
    fun tearDown() {
        scope.cancel()
        dir.deleteRecursively()
    }

    @Test
    fun theKeyIsEncryptedAtRest() = runBlocking {
        val store = ConnectionStore(dataStore, FakeCipher())
        store.save("https://worker.example", "zwa_secret", "meta-1")
        assertEquals("zwa_secret", store.current().apiKey)
        assertEquals("enc:terces_awz", raw("api_key_enc"))
        assertNull(raw("api_key"))
    }

    @Test
    fun aPlaintextKeyFromAnOlderBuildIsMigrated() = runBlocking {
        dataStore.edit { it[stringPreferencesKey("api_key")] = "zwa_legacy" }
        val store = ConnectionStore(dataStore, FakeCipher())
        store.migrate()
        assertEquals("zwa_legacy", store.current().apiKey)
        assertNull(raw("api_key"))
    }

    @Test
    fun aKeyThatCannotBeDecryptedReadsAsSignedOut() = runBlocking {
        ConnectionStore(dataStore, FakeCipher()).save("https://worker.example", "zwa_secret")
        val connection = ConnectionStore(dataStore, LostKeyCipher()).current()
        assertEquals("", connection.apiKey)
        assertFalse(connection.isConfigured)
    }
}
