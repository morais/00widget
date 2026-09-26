package com.example.zerozerowidget.hzos.data

import com.example.zerozerowidget.hzos.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

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

/**
 * Polling repository over [ZeroWidgetApi]. Widgets on iOS reload on a
 * rationed budget; a headset panel has no such budget, but the server's rate
 * limits still apply — so poll slowly (60s) and refresh on demand (user tap,
 * panel open). Never poll faster than ~once a minute unless the value
 * actually needs it.
 */
class DashboardRepository(
    private val store: ConnectionStore,
    private val apiFactory: (baseUrl: String, apiKey: String) -> ZeroWidgetApi,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _state = MutableStateFlow(DashboardState(isLoading = true))
    val state: StateFlow<DashboardState> = _state.asStateFlow()

    private var pollJob: Job? = null

    fun start() {
        if (pollJob != null) return
        pollJob = scope.launch {
            store.connection.collectLatest { connection ->
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

    private suspend fun writeOp(op: suspend (ZeroWidgetApi, ConnectionStore.Connection) -> Unit): Result<Unit> {
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
        return BuildConfig.DEFAULT_BASE_URL.trim().trimEnd('/').ifEmpty { null }
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
        _state.value = DashboardState(isLoading = false, isConfigured = false)
    }

    private suspend fun refreshNow(connection: ConnectionStore.Connection) {
        // Callers guarantee resolvability; re-check defensively since the
        // stored values can change between guard and call.
        val base = effectiveBaseUrl(connection) ?: return
        _state.value = _state.value.copy(isLoading = true, error = null)
        try {
            val api = apiFactory(base, connection.apiKey)
            val dashboard = api.fetchDashboard()
            _state.value = DashboardState(
                cards = dashboard.cards,
                activities = dashboard.activities,
                isLoading = false,
                error = null,
                lastSyncEpochMs = System.currentTimeMillis(),
                isConfigured = true,
            )
        } catch (e: ZeroWidgetApi.ApiException) {
            _state.value = _state.value.copy(
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
            _state.value = _state.value.copy(
                isLoading = false,
                error = (e.message ?: e.javaClass.simpleName).take(200),
            )
        }
    }

    companion object {
        private const val POLL_MS = 60_000L
    }
}
