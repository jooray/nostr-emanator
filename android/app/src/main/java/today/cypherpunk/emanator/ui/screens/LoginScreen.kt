package today.cypherpunk.emanator.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.BuildConfig
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.EmanatorSignInBackend
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.AlarmBlock
import today.cypherpunk.emanator.ui.components.ConnectState
import today.cypherpunk.emanator.ui.components.Legend
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.components.SignerConnect
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links
import today.cypherpunk.nostrsignin.AndroidSignerGateway
import today.cypherpunk.nostrsignin.Nip55
import today.cypherpunk.nostrsignin.SignInController
import today.cypherpunk.nostrsignin.SignInFailure
import today.cypherpunk.nostrsignin.SignInMethod
import today.cypherpunk.nostrsignin.SignInState
import today.cypherpunk.nostrsignin.SignerActivityBridge

/**
 * Sign-in, through the shared nostr-signin module (the same flow as Lievik's):
 *
 *  - a signer on this phone (NIP-55): one tap, no relays. The account it
 *    brings has no posting connection yet, so it is paired once afterwards,
 *    like a NIP-07 login on the web;
 *  - nostrconnect:// (NIP-46): opened in the signer, or shown as a QR. Signs
 *    in and connects posting in one go;
 *  - a pasted bunker:// link.
 *
 * The backend stores the device token, which flips the root to the app.
 */
class LoginViewModel(container: AppContainer) : ViewModel() {
    val gateway = AndroidSignerGateway(container.context)
    val signIn = SignInController(EmanatorSignInBackend(container), gateway, viewModelScope)
}

@Composable
fun LoginScreen() {
    val context = LocalContext.current
    val vm = appViewModel { LoginViewModel(it) }
    SignerActivityBridge(vm.gateway)
    val state by vm.signIn.state.collectAsState()
    val signers = remember { Nip55.signers(context) }
    val container = today.cypherpunk.emanator.ui.LocalContainer.current
    val c = LocalConsole.current
    var bunker by rememberSaveable { mutableStateOf("") }
    var server by rememberSaveable { mutableStateOf(container.prefs.serverUrl) }
    var showServer by rememberSaveable { mutableStateOf(false) }
    val startConnect = { vm.signIn.startNostrConnect { uri -> Links.openSigner(context, uri) } }

    Surface(color = c.chassis, modifier = Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.height(24.dp))
            Text("EMANATOR", style = Type.display, color = c.text)
            Text(stringResource(R.string.login_tagline), style = Type.body, color = c.legend)
            Text(stringResource(R.string.login_no_account), style = Type.small, color = c.muted)

            if (signers.isNotEmpty()) {
                Rule()
                Legend(stringResource(R.string.login_signer_app_heading))
                val working = state is SignInState.Working && (state as SignInState.Working).method == SignInMethod.Signer
                signers.forEach { signer ->
                    PrimaryButton(
                        stringResource(R.string.login_sign_in_with, signer.label),
                        { vm.signIn.signInWithSigner(signer.packageName) },
                        Modifier.fillMaxWidth(),
                        busy = working,
                    )
                }
                Text(stringResource(R.string.login_signer_app_hint), style = Type.small, color = c.muted)
                failureFor(state, SignInMethod.Signer)?.let { AlarmBlock(it) }
            }

            Rule()
            Legend(stringResource(R.string.login_signer_heading))
            Text(stringResource(R.string.login_connect_hint), style = Type.small, color = c.muted)
            SignerConnect(connectState(state), pairing = false, onStart = startConnect)

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
            val bunkerState = state
            if (bunkerState is SignInState.Waiting && bunkerState.method == SignInMethod.Bunker) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    CircularProgressIndicator(Modifier.size(18.dp), color = Palette.amber, strokeWidth = 2.dp)
                    Text(stringResource(R.string.signer_waiting), style = Type.bodyDense, color = c.text)
                }
                bunkerState.authUrl?.let { url ->
                    SlugButton(stringResource(R.string.signer_open_approval), { Links.openUrl(context, url) })
                }
            }
            if (bunkerState is SignInState.Expired && bunkerState.method == SignInMethod.Bunker) {
                AlarmBlock(stringResource(R.string.signer_expired))
            }
            failureFor(state, SignInMethod.Bunker)?.let { AlarmBlock(it) }
            SecondaryButton(
                stringResource(R.string.login_connect), { vm.signIn.startBunker(bunker) }, Modifier.fillMaxWidth(),
                enabled = bunker.trim().startsWith("bunker://") &&
                    !(state is SignInState.Working && (state as SignInState.Working).method == SignInMethod.Bunker),
            )

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

/** The nostrconnect section's view of the shared state. */
@Composable
private fun connectState(state: SignInState): ConnectState = when {
    state is SignInState.Working && state.method == SignInMethod.NostrConnect -> ConnectState.Starting
    state is SignInState.Waiting && state.method == SignInMethod.NostrConnect -> ConnectState.Waiting(state.uri, state.authUrl)
    state is SignInState.Expired && state.method == SignInMethod.NostrConnect -> ConnectState.Expired
    state is SignInState.Failed && state.method == SignInMethod.NostrConnect ->
        ConnectState.Failed(failureFor(state, SignInMethod.NostrConnect).orEmpty())
    else -> ConnectState.Idle
}

/** The message for a failed attempt by [method], or null. Server errors carry their own (localized) text. */
@Composable
private fun failureFor(state: SignInState, method: SignInMethod): String? {
    if (state !is SignInState.Failed || state.method != method) return null
    return when (state.failure) {
        SignInFailure.SignerRejected -> stringResource(R.string.login_failed_rejected)
        SignInFailure.SignerEmpty -> stringResource(R.string.login_failed_empty)
        SignInFailure.SignerMissing -> stringResource(R.string.login_failed_missing)
        SignInFailure.InvalidBunkerLink -> stringResource(R.string.login_failed_bunker)
        SignInFailure.Server -> state.cause?.message?.takeIf { it.isNotBlank() } ?: stringResource(R.string.error_generic)
    }
}
