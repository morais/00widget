package com.zerozerowidget.hzos

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.zerozerowidget.hzos.auth.HorizonAuth
import com.zerozerowidget.hzos.auth.HorizonIap
import com.zerozerowidget.hzos.auth.HorizonSignInController
import com.zerozerowidget.hzos.auth.checkMetaUser
import com.zerozerowidget.hzos.data.ConnectionStore
import com.zerozerowidget.hzos.data.DashboardRepository
import com.zerozerowidget.hzos.data.MetaUserCheck
import com.zerozerowidget.hzos.data.SampleStore
import com.zerozerowidget.hzos.data.ZeroWidgetApi
import com.zerozerowidget.hzos.ui.PanelPrefs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient

/**
 * Process-wide composition root. The app is a read-mostly panel client over
 * the existing 00Widget Worker API, so there is no DI framework — one graph
 * built here and read from each panel activity.
 */
class ZeroZeroWidgetApp : Application() {
    lateinit var connectionStore: ConnectionStore
        private set
    lateinit var repository: DashboardRepository
        private set
    lateinit var http: OkHttpClient
        private set
    lateinit var horizonAuth: HorizonAuth
        private set
    lateinit var horizonIap: HorizonIap
        private set
    lateinit var panelPrefs: PanelPrefs
        private set
    lateinit var sampleStore: SampleStore
        private set
    lateinit var horizonSignIn: HorizonSignInController
        private set

    /**
     * A client on the stored credential and effective Worker URL, or null
     * when signed out or no URL resolves. Every screen that calls the
     * Worker directly goes through this.
     */
    suspend fun authedApi(): ZeroWidgetApi? {
        val connection = connectionStore.current()
        if (connection.apiKey.isBlank()) return null
        val base = ConnectionStore.effectiveBaseUrl(connection.baseUrl) ?: return null
        return apiFor(base, connection.apiKey)
    }

    /** The client for the current connection, built once per connection (audit P4). */
    @Volatile
    private var cachedApi: Triple<String, String, ZeroWidgetApi>? = null

    fun apiFor(baseUrl: String, apiKey: String): ZeroWidgetApi {
        cachedApi?.let { (base, key, api) -> if (base == baseUrl && key == apiKey) return api }
        return ZeroWidgetApi(http, baseUrl, apiKey).also { cachedApi = Triple(baseUrl, apiKey, it) }
    }

    /** Process-wide scope for work that outlives any one panel. */
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onCreate() {
        super.onCreate()
        connectionStore = ConnectionStore(this)
        panelPrefs = PanelPrefs(this)
        sampleStore = SampleStore(this)
        http = OkHttpClient.Builder().build()
        // The API client resolves base URL + key per call from the store, so
        // editing them in the settings panel takes effect without a restart.
        repository = DashboardRepository(connectionStore, ::apiFor)
        horizonAuth = HorizonAuth(this, appScope, BuildConfig.PLATFORM_APP_ID)
        horizonAuth.connect()
        horizonIap = HorizonIap(appScope, BuildConfig.PLATFORM_APP_ID)
        horizonSignIn = HorizonSignInController(this)
        // No poll before the first Meta account check (see verifyMetaUser).
        repository.holdForIdentityCheck()
        // An older build stored the key in plaintext: encrypt it, then start
        // polling, so the repository never reads the key mid-move.
        appScope.launch {
            connectionStore.migrate()
            repository.start()
        }
        // Poll only while some panel is on screen (STARTED); see
        // DashboardRepository.setActive.
        ProcessLifecycleOwner.get().lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) {
                    // A Meta account switch doesn't restart panels: re-check
                    // whenever any panel comes to the foreground — a detail
                    // panel alone included — so a stranger's token never
                    // survives one (audit S8). Polling waits for the answer.
                    verifyMetaUser()
                    repository.setActive(true)
                }

                override fun onStop(owner: LifecycleOwner) = repository.setActive(false)
            }
        )
    }

    private var metaUserJob: Job? = null

    /**
     * Confirms the Meta user wearing the headset owns the stored session
     * before the dashboard polls again, and keeps trying while it can't be
     * read: the Platform SDK connects asynchronously, so an early check can
     * find no user yet. Until then server data is withheld, and the token is
     * kept so a confirmed check resumes without a sign-in.
     */
    fun verifyMetaUser() {
        repository.holdForIdentityCheck()
        metaUserJob?.cancel()
        metaUserJob = appScope.launch {
            var wait = META_RETRY_FIRST_MS
            while (checkMetaUser(this@ZeroZeroWidgetApp) == MetaUserCheck.UNKNOWN) {
                repository.identityUnconfirmed()
                delay(wait)
                wait = (wait * 2).coerceAtMost(META_RETRY_MAX_MS)
            }
            repository.identityConfirmed()
        }
    }
}

/** Retry spacing while the Meta user can't be read: 1s, doubling to 30s. */
private const val META_RETRY_FIRST_MS = 1_000L
private const val META_RETRY_MAX_MS = 30_000L
