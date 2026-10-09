package today.cypherpunk.emanator.ui.screens.accounts

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.AccountDetail
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.ui.LocalContainer
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.AlarmBlock
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Legend
import today.cypherpunk.emanator.ui.components.LoadableContent
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.Readout
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.rememberSnackbar
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type

/**
 * What Emanator itself keeps about an account (web: accounts/edit): the AI
 * writing personality and the Blossom media server. The Nostr profile is shown
 * read-only — it lives on relays and is changed in the profile editor.
 */
@Composable
fun AccountEditScreen(nav: NavHostController, id: Long) {
    val container = LocalContainer.current
    val scope = rememberCoroutineScope()
    val snackbar = rememberSnackbar()
    val vm = appViewModel("account-$id") { c -> LoadVm(c.cache, "account/$id", AccountDetail.serializer()) { c.api.account(id) } }
    val state by vm.state.collectAsState()
    LaunchedEffect(id) { if (state.data == null) vm.load() }

    var maxPersonality by remember { mutableIntStateOf(8000) }
    LaunchedEffect(Unit) { runCatching { container.api.meta() }.getOrNull()?.let { maxPersonality = it.limits.personalityMaxLength } }

    var personality by rememberSaveable { mutableStateOf<String?>(null) }
    var blossom by rememberSaveable { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    ConsoleScaffold(stringResource(R.string.acc_edit_title), onBack = { nav.popBackStack() }, snackbar = snackbar) { padding ->
        LoadableContent(state, onRefresh = vm::load, modifier = Modifier.padding(padding)) { detail ->
            val account = detail.account
            val c = LocalConsole.current
            val text = personality ?: account.personality.orEmpty()
            val server = blossom ?: account.blossomServerOverride.orEmpty()

            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(Gutter),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Legend(stringResource(R.string.acc_profile_info))
                Text(stringResource(R.string.acc_profile_info_help), style = Type.small, color = c.muted)
                Readout(stringResource(R.string.acc_display_name), account.displayName?.ifBlank { null } ?: stringResource(R.string.acc_not_set))
                Readout(stringResource(R.string.acc_username), account.username?.ifBlank { null }?.let { "@$it" } ?: stringResource(R.string.acc_not_set))
                account.npub?.let { Readout("npub", it, mono = true) }
                account.about?.takeIf { it.isNotBlank() }?.let { Readout(stringResource(R.string.acc_about), it) }
                Rule()

                Row {
                    Legend(stringResource(R.string.acc_personality), Modifier.weight(1f))
                    Text(stringResource(R.string.acc_markdown).uppercase(), style = Type.slug, color = c.muted)
                }
                Text(stringResource(R.string.acc_personality_help), style = Type.small, color = c.muted)
                Field(
                    stringResource(R.string.acc_personality), text, { personality = it },
                    placeholder = stringResource(R.string.acc_personality_placeholder),
                    singleLine = false, minLines = 8, isError = text.length > maxPersonality,
                )
                Text(
                    stringResource(R.string.acc_char_count, text.length, maxPersonality),
                    style = Type.mono, color = if (text.length > maxPersonality) c.redText else c.muted,
                )
                Rule()

                Field(
                    stringResource(R.string.acc_blossom_label), server, { blossom = it },
                    help = stringResource(R.string.acc_blossom_help, account.defaultBlossomServer ?: "—"),
                    placeholder = account.defaultBlossomServer, keyboardType = KeyboardType.Uri,
                )

                error?.let { AlarmBlock(it) }
                PrimaryButton(
                    stringResource(R.string.acc_save),
                    {
                        saving = true
                        error = null
                        scope.launch {
                            try {
                                val result = container.api.updateAccount(id, mapOf("personality" to text, "blossom_server" to server.trim()))
                                // The account page re-reads on return; this
                                // keeps the phone's copy right meanwhile.
                                vm.set(detail.copy(account = result.account))
                                nav.popBackStack()
                            } catch (e: ApiException) {
                                error = e.message
                            } finally {
                                saving = false
                            }
                        }
                    },
                    Modifier.fillMaxWidth(),
                    enabled = text.length <= maxPersonality,
                    busy = saving,
                )
            }
        }
    }
}
