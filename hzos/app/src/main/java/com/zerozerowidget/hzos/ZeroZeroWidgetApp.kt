package com.zerozerowidget.hzos

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.zerozerowidget.hzos.auth.HorizonAuth
import com.zerozerowidget.hzos.auth.HorizonIap
import com.zerozerowidget.hzos.data.ConnectionStore
import com.zerozerowidget.hzos.data.DashboardRepository
import com.zerozerowidget.hzos.data.SampleStore
import com.zerozerowidget.hzos.data.ZeroWidgetApi
import com.zerozerowidget.hzos.ui.PanelPrefs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
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

    /**
     * A client on the stored credential and effective Worker URL, or null
     * when signed out or no URL resolves. Every screen that calls the
     * Worker directly goes through this.
     */
    suspend fun authedApi(): ZeroWidgetApi? {
        val connection = connectionStore.current()
        if (connection.apiKey.isBlank()) return null
        val base = ConnectionStore.effectiveBaseUrl(connection.baseUrl) ?: return null
        return ZeroWidgetApi(http, base, connection.apiKey)
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
        val apiFactory = { baseUrl: String, apiKey: String ->
            ZeroWidgetApi(http, baseUrl, apiKey)
        }
        repository = DashboardRepository(connectionStore, apiFactory)
        horizonAuth = HorizonAuth(this, appScope, BuildConfig.PLATFORM_APP_ID)
        horizonAuth.connect()
        horizonIap = HorizonIap(appScope, BuildConfig.PLATFORM_APP_ID)
        repository.start()
        // Poll only while some panel is on screen (STARTED); see
        // DashboardRepository.setActive.
        ProcessLifecycleOwner.get().lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) = repository.setActive(true)
                override fun onStop(owner: LifecycleOwner) = repository.setActive(false)
            }
        )
    }
}
