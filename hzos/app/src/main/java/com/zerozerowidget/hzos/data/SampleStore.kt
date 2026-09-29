package com.zerozerowidget.hzos.data

import android.content.Context
import androidx.datastore.preferences.core.Preferences
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
import kotlinx.coroutines.flow.updateAndGet
import kotlinx.coroutines.launch
import kotlinx.serialization.KSerializer
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

    // Writes run one at a time, in the order they were made, each carrying
    // the value it was made with — so quick successive removals cannot land
    // on disk out of order (audit C6).
    private val writer = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(1))

    // Set by the first in-memory change. The initial disk load applies only
    // if nothing has changed since the store was built, so a generate or a
    // clear made before the load finishes is never overwritten by it.
    private val lock = Any()
    private var changed = false
    private val json = WireJson

    private val _cards = MutableStateFlow<List<DashboardCard>>(emptyList())
    val cards: StateFlow<List<DashboardCard>> = _cards.asStateFlow()

    private val _activities = MutableStateFlow<List<LiveActivitySession>>(emptyList())
    val activities: StateFlow<List<LiveActivitySession>> = _activities.asStateFlow()

    // False until the saved samples are read (or a change beats the read),
    // so the dashboard can tell "no samples" from "not read yet".
    private val _loaded = MutableStateFlow(false)
    val loaded: StateFlow<Boolean> = _loaded.asStateFlow()

    companion object {
        private val CARDS_JSON = stringPreferencesKey("sample_cards_json")
        private val ACTIVITIES_JSON = stringPreferencesKey("sample_activities_json")
    }

    init {
        scope.launch {
            val cards = readList(CARDS_JSON, DashboardCard.serializer())
            val activities = readList(ACTIVITIES_JSON, LiveActivitySession.serializer())
            synchronized(lock) {
                if (!changed) {
                    _cards.value = cards
                    _activities.value = activities
                }
                _loaded.value = true
            }
        }
    }

    /** Applies one in-memory change, marked so the initial load never undoes it. */
    private inline fun <T> change(block: () -> T): T = synchronized(lock) {
        changed = true
        _loaded.value = true
        block()
    }

    fun generateCards() {
        val samples = SampleData.makeCards()
        change { _cards.value = samples }
        writer.launch { writeList(CARDS_JSON, samples, DashboardCard.serializer()) }
        // Generating samples includes the App launch demo activity, so one
        // tap populates both sections.
        generateSampleActivity()
    }

    /** The one demo activity (generating replaces). */
    fun generateSampleActivity() {
        val sessions = listOf(SampleData.makeSampleActivity())
        change { _activities.value = sessions }
        writer.launch { writeList(ACTIVITIES_JSON, sessions, LiveActivitySession.serializer()) }
    }

    fun clearSamples() {
        change {
            _cards.value = emptyList()
            _activities.value = emptyList()
        }
        writer.launch {
            appContext.sampleDataStore.edit { prefs ->
                prefs.remove(CARDS_JSON)
                prefs.remove(ACTIVITIES_JSON)
            }
        }
    }

    /** Removes one sample card (no server involved, by definition). */
    fun removeCard(id: String) {
        val remaining = change { _cards.updateAndGet { cards -> cards.filterNot { it.id == id } } }
        writer.launch { writeList(CARDS_JSON, remaining, DashboardCard.serializer()) }
    }

    /** Removes one sample activity. */
    fun removeActivity(externalActivityId: String) {
        val remaining = change {
            _activities.updateAndGet { sessions ->
                sessions.filterNot { it.externalActivityId == externalActivityId }
            }
        }
        writer.launch { writeList(ACTIVITIES_JSON, remaining, LiveActivitySession.serializer()) }
    }

    private suspend fun <T> readList(
        key: Preferences.Key<String>,
        serializer: KSerializer<T>
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
        key: Preferences.Key<String>,
        value: List<T>,
        serializer: KSerializer<T>
    ) {
        val raw = json.encodeToString(ListSerializer(serializer), value)
        appContext.sampleDataStore.edit { it[key] = raw }
    }
}
