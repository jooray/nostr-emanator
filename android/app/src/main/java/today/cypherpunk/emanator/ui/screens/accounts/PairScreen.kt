package today.cypherpunk.emanator.ui.screens.accounts

import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.navigation.NavHostController
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.Account
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.ConnectState
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Legend
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.components.SignerConnect
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links

/**
 * Pairing a signer: a new account (accountId null) or re-pairing an existing
 * one. Same NIP-46 sessions and completion as the web pages; the app keeps the
 * session id the web keeps in its cookie.
 */
class PairViewModel(private val container: AppContainer, private val accountId: Long?) : ViewModel() {
    val state = MutableStateFlow<ConnectState>(ConnectState.Idle)
    /** The free plan's account limit was hit: offer the billing page. */
    val overLimit = MutableStateFlow(false)
    val paired = MutableStateFlow<Account?>(null)
    private var poller: Job? = null

    fun start(open: (String) -> Unit) {
        poller?.cancel()
        overLimit.value = false
        state.value = ConnectState.Starting
        poller = viewModelScope.launch {
            try {
                val session = container.api.startPairing(accountId)
                state.value = ConnectState.Waiting(session.uri)
                session.uri?.let(open)
                poll(session.sessionId, session.uri)
            } catch (e: ApiException) {
                overLimit.value = e.code == "account_limit"
                state.value = ConnectState.Failed(e.message)
            }
        }
    }

    private suspend fun poll(sessionId: String, uri: String?) {
        while (true) {
            delay(1500)
            val result = try {
                container.api.pairingStatus(sessionId, accountId)
            } catch (e: ApiException) {
                if (e.isNetwork) continue
                state.value = ConnectState.Failed(e.message)
                return
            }
            when (result.status) {
                "paired" -> { paired.value = result.account; return }
                "expired" -> { state.value = ConnectState.Expired; return }
                "over_limit" -> {
                    overLimit.value = true
                    state.value = ConnectState.Failed(result.error.orEmpty())
                    return
                }
                "failed" -> { state.value = ConnectState.Failed(result.error.orEmpty()); return }
                else -> state.value = ConnectState.Waiting(uri, result.authUrl)
            }
        }
    }
}

@Composable
fun PairScreen(nav: NavHostController, accountId: Long?, reason: String?) {
    val context = LocalContext.current
    val vm = appViewModel("pair-${accountId ?: 0}-${reason.orEmpty()}") { PairViewModel(it, accountId) }
    val state by vm.state.collectAsState()
    val overLimit by vm.overLimit.collectAsState()
    val paired by vm.paired.collectAsState()
    val c = LocalConsole.current
    val messaging = reason == "messaging"

    // The session is minted at once so the signer button is ready, but Amber
    // only opens when the user taps it.
    LaunchedEffect(Unit) { if (state == ConnectState.Idle) vm.start { } }

    val pairedText = stringResource(if (accountId == null) R.string.acc_paired else R.string.acc_re_paired)
    LaunchedEffect(paired) {
        val account = paired ?: return@LaunchedEffect
        Toast.makeText(context, pairedText, Toast.LENGTH_LONG).show()
        if (accountId != null) {
            nav.popBackStack()
        } else {
            nav.navigate(Routes.account(account.id)) { popUpTo(Routes.PAIR) { inclusive = true } }
        }
    }

    val title = when {
        accountId == null -> stringResource(R.string.acc_pair_title)
        messaging -> stringResource(R.string.acc_repair_title_messaging)
        else -> stringResource(R.string.acc_repair_title_reconnect)
    }

    ConsoleScaffold(title, onBack = { nav.popBackStack() }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(Gutter),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                when {
                    accountId == null -> stringResource(R.string.acc_pair_intro)
                    messaging -> stringResource(R.string.acc_repair_intro_messaging)
                    else -> stringResource(R.string.acc_repair_intro_reconnect)
                },
                style = Type.body, color = c.legend,
            )

            if (messaging) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(R.string.acc_repair_step_decrypt, R.string.acc_repair_step_relay_auth).forEachIndexed { i, step ->
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Text("${i + 1}", style = Type.readout, color = c.amberText)
                            Text(stringResource(step), style = Type.small, color = c.text)
                        }
                    }
                }
            }

            SignerConnect(state, pairing = true, onStart = { vm.start { uri -> Links.openSigner(context, uri) } })
            if (overLimit) {
                SecondaryButton(stringResource(R.string.acc_see_plans), { nav.navigate(Routes.BILLING) }, Modifier.fillMaxWidth())
            }

            Rule()
            Text(stringResource(R.string.acc_key_stays), style = Type.small, color = c.muted)
            if (accountId == null) NoAccountHelp()
        }
    }
}

@Composable
private fun NoAccountHelp() {
    val c = LocalConsole.current
    var open by rememberSaveable { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Legend(stringResource(R.string.acc_no_account_summary), Modifier.clickable { open = !open })
        if (open) Text(stringResource(R.string.acc_no_account_body), style = Type.small, color = c.legend)
    }
}
