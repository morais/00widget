package com.zerozerowidget.hzos.data

import com.zerozerowidget.hzos.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** What the panels render. One state object, every panel reads from it. */
data class DashboardState(
    val cards: List<DashboardCard> = emptyList(),
    val activities: List<LiveActivitySession> = emptyList(),
    val isLoading: Boolean = false,
    /** Last error, human-readable. Null when the last fetch succeeded. */
    val error: String? = null,
    val lastSyncEpochMs: Long? = null,
    val isConfigured: Boolean = false,
)

/** What the repository reads credentials from; [ConnectionStore] in the app. */
interface ConnectionSource {
    val connection: Flow<ConnectionStore.Connection>
    suspend fun current(): ConnectionStore.Connection
}

/** The Worker calls the repository makes; [ZeroWidgetApi] in the app. */
interface DashboardApi {
    suspend fun fetchDashboard(): DashboardResponse
    suspend fun runAction(actionId: String, cardId: String?)
    suspend fun deleteCard(id: String)
    suspend fun endActivity(externalActivityId: String)
}

/**
 * Polling repository over [ZeroWidgetApi]. Widgets on iOS reload on a
 * rationed budget; a headset panel has no such budget, but the server's rate
 * limits still apply — so poll slowly (60s) and refresh on demand (user tap,
 * panel open). Never poll faster than ~once a minute unless the value
 * actually needs it.
 *
 * Refreshes are serialised and fenced. The poll, a manual refresh, and the
 * refresh after an action or delete used to run side by side, so a slow,
 * older response could land last and win; and a manual refresh is not tied
 * to the credential collector, so one in flight across a sign-out painted
 * the old account's cards back onto the signed-out dashboard. Now one
 * [refreshMutex] orders them, and a result is published only if neither
 * [generation] nor the stored key moved while it was in flight.
 */
class DashboardRepository(
    private val store: ConnectionSource,
    private val apiFactory: (baseUrl: String, apiKey: String) -> DashboardApi,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val defaultBaseUrl: String = BuildConfig.DEFAULT_BASE_URL,
) {
    private val _state = MutableStateFlow(DashboardState(isLoading = true))
    val state: StateFlow<DashboardState> = _state.asStateFlow()

    private var pollJob: Job? = null
    private val refreshMutex = Mutex()

    /** Bumped on every credential change and sign-out; stale results check it. */
    @Volatile
    private var generation = 0L

    fun start() {
        if (pollJob != null) return
        pollJob = scope.launch {
            store.connection.collectLatest { connection ->
                generation++
                if (effectiveBaseUrl(connection) == null || connection.apiKey.isBlank()) {
                    _state.value = DashboardState(isLoading = false, isConfigured = false)
                    return@collectLatest
                }
                _state.value = _state.value.copy(isConfigured = true)
                refreshNow(connection)
                // Slow poll while configured. Cancelled + restarted on every
                // credential change by collectLatest.
                while (true) {
                    delay(POLL_MS)
                    refreshNow(connection)
                }
            }
        }
    }

    fun refresh() {
        scope.launch {
            val connection = store.current()
            if (effectiveBaseUrl(connection) != null && connection.apiKey.isNotBlank()) {
                refreshNow(connection)
            }
        }
    }

    suspend fun runAction(actionId: String, cardId: String?): Result<Unit> {
        val connection = store.current()
        val base = effectiveBaseUrl(connection)
        if (base == null || connection.apiKey.isBlank()) {
            return Result.failure(IllegalStateException("Not connected"))
        }
        return try {
            apiFactory(base, connection.apiKey).runAction(actionId, cardId)
            refreshNow(connection)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun deleteCard(id: String): Result<Unit> = writeOp { api, _ -> api.deleteCard(id) }

    suspend fun endActivity(externalActivityId: String): Result<Unit> =
        writeOp { api, _ -> api.endActivity(externalActivityId) }

    private suspend fun writeOp(op: suspend (DashboardApi, ConnectionStore.Connection) -> Unit): Result<Unit> {
        val connection = store.current()
        val base = effectiveBaseUrl(connection)
        if (base == null || connection.apiKey.isBlank()) {
            return Result.failure(IllegalStateException("Not connected"))
        }
        return try {
            op(apiFactory(base, connection.apiKey), connection)
            refreshNow(connection)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Saved Worker URL first, build default second. A key is still required
     * — the URL alone authenticates nothing — so `isConfigured` now means
     * "has a key and a resolvable URL", wherever the URL came from.
     */
    private fun effectiveBaseUrl(connection: ConnectionStore.Connection): String? {
        val stored = connection.baseUrl.trim().trimEnd('/')
        if (stored.isNotEmpty()) return stored
        return defaultBaseUrl.trim().trimEnd('/').ifEmpty { null }
    }

    fun cardById(id: String): DashboardCard? = _state.value.cards.firstOrNull { it.id == id }

    /**
     * Drops every server card and activity immediately. Sign-out calls this
     * alongside clearing the credential: the connection flow reset covers
     * the steady state, but an in-flight poll finishing late must never
     * repaint signed-out panels — and neither may a swallowed cancellation
     * (see below).
     */
    fun clearServerData() {
        generation++
        _state.value = DashboardState(isLoading = false, isConfigured = false)
    }

    private suspend fun refreshNow(connection: ConnectionStore.Connection) = refreshMutex.withLock {
        // Callers guarantee resolvability; re-check defensively since the
        // stored values can change between guard and call.
        val base = effectiveBaseUrl(connection) ?: return@withLock
        val startedAt = generation
        // Queued behind another refresh while the credential changed: the
        // collector already owns the new one, so this one has nothing to say.
        if (!stillCurrent(connection, startedAt)) return@withLock
        _state.value = _state.value.copy(isLoading = true, error = null)
        val next: DashboardState = try {
            val dashboard = apiFactory(base, connection.apiKey).fetchDashboard()
            DashboardState(
                cards = dashboard.cards,
                activities = dashboard.activities,
                isLoading = false,
                error = null,
                lastSyncEpochMs = System.currentTimeMillis(),
                isConfigured = true,
            )
        } catch (e: ZeroWidgetApi.ApiException) {
            _state.value.copy(
                isLoading = false,
                error = if (e.status == 401) {
                    "Invalid or expired API key — check Connection settings."
                } else {
                    "HTTP ${e.status}: ${e.message?.take(160)}"
                },
            )
        } catch (e: CancellationException) {
            // A cancelled poll (sign-out mid-flight, credential change) is
            // not a failure: die quietly so the fresher state — usually the
            // signed-out reset — stands uncontradicted.
            throw e
        } catch (e: Exception) {
            _state.value.copy(
                isLoading = false,
                error = (e.message ?: e.javaClass.simpleName).take(200),
            )
        }
        // Signed out or switched accounts while this was in flight: the
        // answer belongs to a credential that no longer applies.
        if (!stillCurrent(connection, startedAt)) return@withLock
        _state.value = next
    }

    private suspend fun stillCurrent(connection: ConnectionStore.Connection, startedAt: Long): Boolean =
        generation == startedAt && store.current().apiKey == connection.apiKey

    companion object {
        private const val POLL_MS = 60_000L
    }
}
