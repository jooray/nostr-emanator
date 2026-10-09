package today.cypherpunk.emanator.ui.screens

import android.os.Build
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.BuildConfig
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.Me
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.AlarmBlock
import today.cypherpunk.emanator.ui.components.ConnectState
import today.cypherpunk.emanator.ui.components.Legend
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.components.SignerConnect
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links

/**
 * Login through the server's NIP-46 sessions (the same ones the web uses). The
 * app opens the nostrconnect:// link in Amber directly, shows it as a QR for a
 * signer elsewhere, or takes a bunker:// link — then polls until approved and
 * stores the device token it receives.
 */
class LoginViewModel(private val container: AppContainer) : ViewModel() {
    val state = MutableStateFlow<ConnectState>(ConnectState.Idle)
    private var poller: Job? = null

    fun start(openSigner: (String) -> Unit) {
        poller?.cancel()
        state.value = ConnectState.Starting
        poller = viewModelScope.launch {
            try {
                val session = container.api.startLogin()
                state.value = ConnectState.Waiting(session.uri)
                session.uri?.let(openSigner)
                poll(session.sessionId, session.uri)
            } catch (e: ApiException) {
                state.value = ConnectState.Failed(e.message)
            }
        }
    }

    fun startBunker(uri: String) {
        poller?.cancel()
        state.value = ConnectState.Starting
        poller = viewModelScope.launch {
            try {
                val session = container.api.startBunkerLogin(uri.trim())
                state.value = ConnectState.Waiting(null)
                poll(session.sessionId, null)
            } catch (e: ApiException) {
                state.value = ConnectState.Failed(e.message)
            }
        }
    }

    private suspend fun poll(sessionId: String, uri: String?) {
        val device = listOf(Build.MANUFACTURER.replaceFirstChar { it.uppercase() }, Build.MODEL).distinct().joinToString(" ")
        while (true) {
            delay(1500)
            val result = try {
                container.api.pollLogin(sessionId, device, BuildConfig.VERSION_CODE.toString())
            } catch (e: ApiException) {
                if (e.isNetwork) continue else { state.value = ConnectState.Failed(e.message); return }
            }
            when (result.status) {
                "authenticated" -> {
                    val token = result.token ?: return
                    container.session.signIn(token)
                    result.user?.let { container.setMe(Me(user = it)) }
                    return
                }
                "expired" -> { state.value = ConnectState.Expired; return }
                else -> state.value = ConnectState.Waiting(uri, result.authUrl)
            }
        }
    }
}

@Composable
fun LoginScreen() {
    val context = LocalContext.current
    val vm = appViewModel { LoginViewModel(it) }
    val state by vm.state.collectAsState()
    val container = today.cypherpunk.emanator.ui.LocalContainer.current
    val c = LocalConsole.current
    var bunker by rememberSaveable { mutableStateOf("") }
    var server by rememberSaveable { mutableStateOf(container.prefs.serverUrl) }
    var showServer by rememberSaveable { mutableStateOf(false) }

    Surface(color = c.chassis, modifier = Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.height(24.dp))
            Text("EMANATOR", style = Type.display, color = c.text)
            Text(stringResource(R.string.login_tagline), style = Type.body, color = c.legend)
            Text(stringResource(R.string.login_no_account), style = Type.small, color = c.muted)
            Rule()

            Legend(stringResource(R.string.login_signer_heading))
            SignerConnect(state, pairing = false, onStart = { vm.start { uri -> Links.openSigner(context, uri) } })

            Rule()
            Legend(stringResource(R.string.login_bunker_heading))
            Text(stringResource(R.string.login_bunker_help), style = Type.small, color = c.muted)
            OutlinedTextField(
                bunker, { bunker = it },
                label = { Text(stringResource(R.string.login_bunker_label)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )
            SecondaryButton(stringResource(R.string.login_connect), { vm.startBunker(bunker) }, Modifier.fillMaxWidth(), enabled = bunker.startsWith("bunker://"))

            Rule()
            Text(stringResource(R.string.login_explainer), style = Type.small, color = c.muted)
            SlugButton(stringResource(R.string.login_get_amber), { Links.openUrl(context, "https://github.com/greenart7c3/Amber") })

            SlugButton(stringResource(R.string.login_server_toggle), { showServer = !showServer })
            if (showServer) {
                Text(stringResource(R.string.login_server_help), style = Type.small, color = c.muted)
                OutlinedTextField(
                    server, { server = it },
                    label = { Text(stringResource(R.string.login_server_label)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.fillMaxWidth(),
                )
                SecondaryButton(stringResource(R.string.action_save), {
                    container.prefs.serverUrl = server.ifBlank { BuildConfig.DEFAULT_SERVER }
                    server = container.prefs.serverUrl
                    showServer = false
                }, enabled = server.startsWith("https://") || server.startsWith("http://"))
                if (!server.startsWith("https://") && server.isNotBlank()) AlarmBlock(stringResource(R.string.login_server_insecure))
            }
            Text("v${BuildConfig.VERSION_NAME} · ${container.prefs.serverUrl.removePrefix("https://")}", style = Type.mono, color = Palette.neutral500)
        }
    }
}
