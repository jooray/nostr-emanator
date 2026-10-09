package today.cypherpunk.emanator

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.content.IntentCompat
import today.cypherpunk.emanator.ui.EmanatorRoot
import today.cypherpunk.emanator.ui.SharedContent
import today.cypherpunk.emanator.util.AppLocale

class MainActivity : ComponentActivity() {
    private val container get() = (application as EmanatorApplication).container

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppLocale.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (savedInstanceState == null) handleIntent(intent)
        setContent { EmanatorRoot(container) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    /** Shares into Emanator become a new post; emanator:// links open a screen. */
    private fun handleIntent(intent: Intent?) {
        intent ?: return
        // Debug builds only: `adb shell am start … --es debug_server URL --es
        // debug_token emd_…` signs the app in against a local dev server, for
        // testing without a signer. Compiled out of release builds.
        if (BuildConfig.DEBUG) {
            intent.getStringExtra("debug_server")?.let { container.prefs.serverUrl = it }
            intent.getStringExtra("debug_token")?.let { container.session.signIn(it) }
        }
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                val stream = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                container.shared.value = SharedContent(text, listOfNotNull(stream))
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val streams = IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
                container.shared.value = SharedContent(intent.getStringExtra(Intent.EXTRA_TEXT), streams)
            }
            Intent.ACTION_VIEW -> intent.data?.takeIf { it.scheme == "emanator" }?.let { container.deepLink.value = it.host }
        }
    }
}
