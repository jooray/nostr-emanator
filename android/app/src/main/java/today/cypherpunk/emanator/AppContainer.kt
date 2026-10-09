package today.cypherpunk.emanator

import android.content.Context
import coil3.ImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import okhttp3.OkHttpClient
import today.cypherpunk.emanator.data.ApiClient
import today.cypherpunk.emanator.data.ApiEvents
import today.cypherpunk.emanator.data.AppPrefs
import today.cypherpunk.emanator.data.EmanatorApi
import today.cypherpunk.emanator.data.Me
import today.cypherpunk.emanator.data.ReleaseInfo
import today.cypherpunk.emanator.data.ResponseCache
import today.cypherpunk.emanator.data.SecureStore
import today.cypherpunk.emanator.data.Session
import today.cypherpunk.emanator.util.AppLocale
import java.io.File
import java.time.Duration

/** The app's singletons, built once in [EmanatorApplication]. */
class AppContainer(val context: Context) {
    val prefs = AppPrefs(context)
    val session = Session(SecureStore(context))
    val cache = ResponseCache(File(context.filesDir, "api-cache"))

    private val _upgrade = MutableStateFlow<ReleaseInfo?>(null)
    /** Set when the server said this build is too old; the UI blocks on it. */
    val upgrade: StateFlow<ReleaseInfo?> = _upgrade.asStateFlow()

    private val _me = MutableStateFlow<Me?>(null)
    /** The signed-in user and badge counts, refreshed as screens load. */
    val me: StateFlow<Me?> = _me.asStateFlow()

    val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(Duration.ofSeconds(15))
        .readTimeout(Duration.ofSeconds(60))
        .writeTimeout(Duration.ofSeconds(120))
        .build()

    val api = EmanatorApi(
        ApiClient(
            http = http,
            baseUrl = { prefs.serverUrl },
            token = { session.token.value },
            language = { AppLocale.current(context) },
            versionCode = BuildConfig.VERSION_CODE,
            events = object : ApiEvents {
                override fun onUnauthorized() = signOutLocally()
                override fun onUpgradeRequired(info: ReleaseInfo) { _upgrade.value = info }
            },
            networkErrorMessage = { context.getString(R.string.error_network) },
            unexpectedResponseMessage = { context.getString(R.string.error_unexpected_response) },
        )
    )

    // Images (avatars, media previews) never carry the device token.
    val imageLoader: ImageLoader = ImageLoader.Builder(context)
        .components { add(OkHttpNetworkFetcherFactory(callFactory = { http.newBuilder().build() })) }
        .build()

    /** Text/files shared into the app, waiting for the composer to pick them up. */
    val shared = MutableStateFlow<today.cypherpunk.emanator.ui.SharedContent?>(null)

    /** An emanator://<host> link to open (e.g. "billing" after paying). */
    val deepLink = MutableStateFlow<String?>(null)

    fun setMe(me: Me?) { _me.value = me }

    fun requireUpgrade(info: ReleaseInfo) { _upgrade.value = info }

    /** Forget everything this user left on the phone. */
    fun signOutLocally() {
        session.signOut()
        cache.clear()
        // Unsent composer drafts are the user's words too.
        context.getSharedPreferences("compose_drafts", Context.MODE_PRIVATE).edit().clear().apply()
        prefs.clearUserState()
        _me.value = null
        File(context.cacheDir, "uploads").deleteRecursively()
    }
}
