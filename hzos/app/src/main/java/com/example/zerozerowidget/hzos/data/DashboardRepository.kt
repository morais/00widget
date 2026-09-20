package com.example.zerozerowidget.hzos.data

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
                if (!connection.isConfigured) {
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
            if (connection.isConfigured) refreshNow(connection)
        }
    }

    suspend fun runAction(actionId: String, cardId: String?): Result<Unit> {
        val connection = store.current()
        if (!connection.isConfigured) return Result.failure(IllegalStateException("Not connected"))
        return try {
            apiFactory(connection.baseUrl, connection.apiKey).runAction(actionId, cardId)
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
        if (!connection.isConfigured) return Result.failure(IllegalStateException("Not connected"))
        return try {
            op(apiFactory(connection.baseUrl, connection.apiKey), connection)
            refreshNow(connection)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun cardById(id: String): DashboardCard? = _state.value.cards.firstOrNull { it.id == id }

    private suspend fun refreshNow(connection: ConnectionStore.Connection) {
        _state.value = _state.value.copy(isLoading = true, error = null)
        try {
            val api = apiFactory(connection.baseUrl, connection.apiKey)
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
