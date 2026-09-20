package com.example.zerozerowidget.hzos.data

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

private val Context.sampleDataStore by preferencesDataStore(name = "samples")

/**
 * On-device sample deck, mirroring iOS `generateSampleCards()`: generated
 * locally, never published, removable by someone who has never signed in.
 * Persisted as JSON in app-private DataStore so samples survive relaunch;
 * server cards are untouched (samples render alongside, badged SAMPLE).
 */
class SampleStore(context: Context) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }

    private val _cards = MutableStateFlow<List<DashboardCard>>(emptyList())
    val cards: StateFlow<List<DashboardCard>> = _cards.asStateFlow()

    private val _activities = MutableStateFlow<List<LiveActivitySession>>(emptyList())
    val activities: StateFlow<List<LiveActivitySession>> = _activities.asStateFlow()

    companion object {
        private val CARDS_JSON = stringPreferencesKey("sample_cards_json")
        private val ACTIVITIES_JSON = stringPreferencesKey("sample_activities_json")
    }

    init {
        scope.launch {
            _cards.value = readList(CARDS_JSON, DashboardCard.serializer())
            _activities.value = readList(ACTIVITIES_JSON, LiveActivitySession.serializer())
        }
    }

    fun generateCards() {
        val samples = SampleData.makeCards()
        _cards.value = samples
        scope.launch { writeList(CARDS_JSON, samples, DashboardCard.serializer()) }
    }

    /** One sample activity at a time, like iOS (replaces any previous). */
    fun generateActivity(sample: SampleData.LiveActivitySample) {
        val sessions = listOf(SampleData.makeLiveActivitySession(sample))
        _activities.value = sessions
        scope.launch { writeList(ACTIVITIES_JSON, sessions, LiveActivitySession.serializer()) }
    }

    fun clearSamples() {
        _cards.value = emptyList()
        _activities.value = emptyList()
        scope.launch {
            appContext.sampleDataStore.edit { prefs ->
                prefs.remove(CARDS_JSON)
                prefs.remove(ACTIVITIES_JSON)
            }
        }
    }

    /** Removes one sample card (no server involved, by definition). */
    fun removeCard(id: String) {
        _cards.value = _cards.value.filterNot { it.id == id }
        scope.launch { writeList(CARDS_JSON, _cards.value, DashboardCard.serializer()) }
    }

    /** Removes one sample activity. */
    fun removeActivity(externalActivityId: String) {
        _activities.value = _activities.value.filterNot { it.externalActivityId == externalActivityId }
        scope.launch { writeList(ACTIVITIES_JSON, _activities.value, LiveActivitySession.serializer()) }
    }

    private suspend fun <T> readList(
        key: androidx.datastore.preferences.core.Preferences.Key<String>,
        serializer: kotlinx.serialization.KSerializer<T>,
    ): List<T> {
        val raw = appContext.sampleDataStore.data.map { it[key] }.first().orEmpty()
        if (raw.isBlank()) return emptyList()
        return try {
            json.decodeFromString(ListSerializer(serializer), raw)
        } catch (_: Exception) {
            emptyList()
        }
    }

    private suspend fun <T> writeList(
        key: androidx.datastore.preferences.core.Preferences.Key<String>,
        value: List<T>,
        serializer: kotlinx.serialization.KSerializer<T>,
    ) {
        val raw = json.encodeToString(ListSerializer(serializer), value)
        appContext.sampleDataStore.edit { it[key] = raw }
    }
}
