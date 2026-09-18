package com.example.zerozerowidget.hzos

import android.app.Application
import com.example.zerozerowidget.hzos.auth.HorizonAuth
import com.example.zerozerowidget.hzos.data.ConnectionStore
import com.example.zerozerowidget.hzos.data.DashboardRepository
import com.example.zerozerowidget.hzos.data.ZeroWidgetApi
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

    /** Process-wide scope for work that outlives any one panel. */
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onCreate() {
        super.onCreate()
        connectionStore = ConnectionStore(this)
        http = OkHttpClient.Builder().build()
        // The API client resolves base URL + key per call from the store, so
        // editing them in the settings panel takes effect without a restart.
        val apiFactory = { baseUrl: String, apiKey: String ->
            ZeroWidgetApi(http, baseUrl, apiKey)
        }
        repository = DashboardRepository(connectionStore, apiFactory)
        horizonAuth = HorizonAuth(this, appScope, BuildConfig.PLATFORM_APP_ID)
        horizonAuth.connect()
        repository.start()
    }
}
