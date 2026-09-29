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
    val isConfigured: Boolean = false
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
    private val defaultBaseUrl: String = BuildConfig.DEFAULT_BASE_URL
) {
    private val _state = MutableStateFlow(DashboardState(isLoading = true))
    val state: StateFlow<DashboardState> = _state.asStateFlow()

    private var pollJob: Job? = null
    private val refreshMutex = Mutex()

    /**
     * Whether any panel is on screen. Polling runs only while it is: a
     * process with every panel closed or backgrounded has nobody to show a
     * refresh to, and on Meta VR Glasses battery is the product. The app
     * drives this from ProcessLifecycleOwner; true by default so a
     * repository nobody drives behaves as it always did.
     */
    private val active = MutableStateFlow(true)

    fun setActive(isActive: Boolean) {
        active.value = isActive
    }

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
                // Slow poll while configured and visible. Cancelled and
                // restarted on every credential change and every time a
                // panel comes back, which also refreshes immediately so a
                // returning panel never shows a minutes-old dashboard.
                active.collectLatest { isActive ->
                    if (!isActive) return@collectLatest
                    refreshNow(connection, background = true)
                    while (true) {
                        delay(POLL_MS)
                        refreshNow(connection, background = true)
                    }
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

    suspend fun endActivity(externalActivityId: String): Result<Unit> = writeOp { api, _ -> api.endActivity(externalActivityId) }

    private suspend fun writeOp(
        op: suspend (DashboardApi, ConnectionStore.Connection) -> Unit
    ): Result<Unit> {
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
    private fun effectiveBaseUrl(connection: ConnectionStore.Connection): String? = ConnectionStore.effectiveBaseUrl(connection.baseUrl, defaultBaseUrl)

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

    /**
     * [background] polls leave isLoading alone and emit once, with the result;
     * a user-triggered refresh (button, after an action or delete) shows it.
     * Either way, an unchanged card or activity keeps its previous instance
     * (see [reuseUnchanged]), so Compose skips it — a poll that changed
     * nothing recomposes only what reads lastSyncEpochMs (audit P3).
     */
    private suspend fun refreshNow(
        connection: ConnectionStore.Connection,
        background: Boolean = false
    ) = refreshMutex.withLock {
        // Callers guarantee resolvability; re-check defensively since the
        // stored values can change between guard and call.
        val base = effectiveBaseUrl(connection) ?: return@withLock
        val startedAt = generation
        // Queued behind another refresh while the credential changed: the
        // collector already owns the new one, so this one has nothing to say.
        if (!stillCurrent(connection, startedAt)) return@withLock
        if (!background) _state.value = _state.value.copy(isLoading = true, error = null)
        val next: DashboardState = try {
            val dashboard = apiFactory(base, connection.apiKey).fetchDashboard()
            val current = _state.value
            DashboardState(
                cards = reuseUnchanged(current.cards, dashboard.cards),
                activities = reuseUnchanged(current.activities, dashboard.activities),
                isLoading = false,
                error = null,
                lastSyncEpochMs = System.currentTimeMillis(),
                isConfigured = true
            )
        } catch (e: ZeroWidgetApi.ApiException) {
            _state.value.copy(
                isLoading = false,
                error = if (e.status == 401) {
                    "Invalid or expired API key — check Connection settings."
                } else {
                    e.message ?: "Request failed (HTTP ${e.status})."
                }
            )
        } catch (e: CancellationException) {
            // A cancelled poll (sign-out mid-flight, credential change) is
            // not a failure: die quietly so the fresher state — usually the
            // signed-out reset — stands uncontradicted.
            throw e
        } catch (e: Exception) {
            _state.value.copy(
                isLoading = false,
                error = (e.message ?: e.javaClass.simpleName).take(200)
            )
        }
        // Signed out or switched accounts while this was in flight: the
        // answer belongs to a credential that no longer applies.
        if (!stillCurrent(connection, startedAt)) return@withLock
        _state.value = next
    }

    private suspend fun stillCurrent(
        connection: ConnectionStore.Connection,
        startedAt: Long
    ): Boolean = generation == startedAt && store.current().apiKey == connection.apiKey

    companion object {
        /**
         * [fresh] with every element equal to one in [old] replaced by that
         * old instance, and [old] itself when the lists are equal. Decoding
         * builds new objects every poll, and Compose compares these
         * parameters by instance, so without this every card recomposes
         * every minute whether or not it changed.
         */
        internal fun <T> reuseUnchanged(old: List<T>, fresh: List<T>): List<T> = when {
            old == fresh -> old
            old.isEmpty() -> fresh
            else -> old.associateBy { it }.let { byValue -> fresh.map { byValue[it] ?: it } }
        }

        private const val POLL_MS = 60_000L
    }
}
