package today.cypherpunk.emanator.ui.screens.messages

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.navigation.NavHostController
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.Account
import today.cypherpunk.emanator.data.AccountsResponse
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.Mention
import today.cypherpunk.emanator.data.cachedFlow
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.AlarmBlock
import today.cypherpunk.emanator.ui.components.Avatar
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type

data class NewMessageUi(
    val accounts: List<Account> = emptyList(),
    val accountId: Long? = null,
    val query: String = "",
    val suggestions: List<Mention> = emptyList(),
    val searched: Boolean = false,
    val recipient: Mention? = null,
    val draft: String = "",
    val sending: Boolean = false,
    val error: String? = null,
)

/**
 * Starts a private conversation (web: conversations#new). The sending account
 * is always an explicit pick — one inbox spans several identities — and the
 * recipient comes from the same lookup as @mentions, plus people already in
 * the inbox, or a pasted npub.
 */
class NewMessageViewModel(private val container: AppContainer) : ViewModel() {
    private val _ui = MutableStateFlow(NewMessageUi())
    val ui = _ui.asStateFlow()
    private var search: Job? = null

    init {
        viewModelScope.launch {
            cachedFlow(container.cache, "accounts", AccountsResponse.serializer()) { container.api.accounts() }
                .collect { state ->
                    val accounts = state.data?.accounts ?: return@collect
                    _ui.update { ui ->
                        val keep = accounts.firstOrNull { it.id == ui.accountId && it.messagingCapable }
                        ui.copy(accounts = accounts, accountId = (keep ?: accounts.firstOrNull { it.messagingCapable })?.id)
                    }
                }
        }
    }

    fun selectAccount(id: Long) = _ui.update { it.copy(accountId = id, error = null) }

    fun onQuery(query: String) {
        _ui.update { it.copy(query = query, error = null) }
        search?.cancel()
        if (query.isBlank()) {
            _ui.update { it.copy(suggestions = emptyList(), searched = false) }
            return
        }
        search = viewModelScope.launch {
            delay(150)
            val found = runCatching { container.api.recipients(query.trim()).mentions }.getOrDefault(emptyList())
            _ui.update { it.copy(suggestions = found, searched = true) }
        }
    }

    fun pick(person: Mention) {
        search?.cancel()
        _ui.update { it.copy(recipient = person, query = "", suggestions = emptyList(), searched = false, error = null) }
    }

    fun clearRecipient() = _ui.update { it.copy(recipient = null) }

    fun onDraft(text: String) = _ui.update { it.copy(draft = text) }

    fun send(onSent: (Long) -> Unit) {
        val state = _ui.value
        val account = state.accountId ?: return
        val recipient = state.recipient ?: return
        if (state.draft.isBlank() || state.sending) return
        viewModelScope.launch {
            _ui.update { it.copy(sending = true, error = null) }
            try {
                val started = container.api.startConversation(account, recipient.npub, state.draft.trim())
                _ui.update { it.copy(sending = false) }
                onSent(started.conversation.id)
            } catch (e: ApiException) {
                _ui.update { it.copy(sending = false, error = e.message) }
            }
        }
    }
}

@Composable
fun NewMessageScreen(nav: NavHostController) {
    val vm = appViewModel { NewMessageViewModel(it) }
    val ui by vm.ui.collectAsState()
    val c = LocalConsole.current
    val fieldColors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Palette.amber, unfocusedBorderColor = c.rule, cursorColor = Palette.amber)

    ConsoleScaffold(stringResource(R.string.newmsg_title), onBack = { nav.popBackStack() }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(Gutter),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            val capable = ui.accounts.filter { it.messagingCapable }
            if (ui.accounts.isNotEmpty() && capable.isEmpty()) {
                AlarmBlock(stringResource(R.string.newmsg_no_capable_accounts)) {
                    SecondaryButton(stringResource(R.string.newmsg_enable_messaging),
                        { nav.navigate(Routes.pair((ui.accounts.firstOrNull { it.needsMessagingRepair } ?: ui.accounts.first()).id, "messaging")) })
                }
                return@Column
            }

            Text(stringResource(R.string.newmsg_from).uppercase(), style = Type.slug, color = c.muted)
            AccountPills(
                capable.map { it.mini() },
                setOfNotNull(ui.accountId),
                vm::selectAccount,
                allWhenEmpty = false,
            )
            if (capable.size < ui.accounts.size) {
                Text(stringResource(R.string.newmsg_some_unavailable), style = Type.small, color = c.muted)
            }

            Text(stringResource(R.string.newmsg_to).uppercase(), style = Type.slug, color = c.muted)
            val recipient = ui.recipient
            if (recipient != null) {
                Row(
                    Modifier.fillMaxWidth().border(1.dp, Palette.amber).padding(start = 12.dp, top = 6.dp, bottom = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Avatar(recipient.pictureUrl, recipient.label, 32.dp)
                    Column(Modifier.weight(1f)) {
                        Text(recipient.label, style = Type.bodyDense, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(recipient.nip05?.takeIf { it.isNotBlank() } ?: recipient.npub, style = Type.small, color = c.muted,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    IconButton(onClick = vm::clearRecipient) {
                        Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.newmsg_change), tint = c.muted)
                    }
                }
            } else {
                OutlinedTextField(
                    ui.query, vm::onQuery,
                    placeholder = { Text(stringResource(R.string.newmsg_to_placeholder)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    modifier = Modifier.fillMaxWidth(),
                    colors = fieldColors,
                )
                if (ui.suggestions.isNotEmpty()) {
                    Column(Modifier.fillMaxWidth().border(1.dp, c.rule)) {
                        ui.suggestions.forEachIndexed { index, person ->
                            if (index > 0) Rule()
                            Row(
                                Modifier.fillMaxWidth().clickable { vm.pick(person) }.padding(horizontal = 12.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Avatar(person.pictureUrl, person.label, 32.dp)
                                Column(Modifier.weight(1f)) {
                                    Text(person.label, style = Type.bodyDense, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    val sub = when {
                                        person.own -> stringResource(R.string.compose_mention_own)
                                        !person.nip05.isNullOrBlank() -> person.nip05
                                        !person.name.isNullOrBlank() -> "@${person.name}"
                                        else -> person.npub.take(20) + "…"
                                    }
                                    Text(sub, style = Type.small, color = c.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                            }
                        }
                    }
                } else if (ui.searched) {
                    Text(stringResource(R.string.newmsg_no_match), style = Type.small, color = c.muted)
                } else {
                    Text(stringResource(R.string.newmsg_to_hint), style = Type.small, color = c.muted)
                }
            }

            Text(stringResource(R.string.newmsg_message).uppercase(), style = Type.slug, color = c.muted)
            OutlinedTextField(
                ui.draft, vm::onDraft,
                placeholder = { Text(stringResource(R.string.newmsg_message_placeholder)) },
                minLines = 4,
                maxLines = 10,
                modifier = Modifier.fillMaxWidth(),
                colors = fieldColors,
            )
            Text(stringResource(R.string.comp_strong_private).uppercase(), style = Type.slug, color = c.muted)
            ui.error?.let { AlarmBlock(it) }
            PrimaryButton(
                stringResource(R.string.comp_send),
                {
                    vm.send { id ->
                        nav.navigate(Routes.conversation(id)) { popUpTo(Routes.NEW_MESSAGE) { inclusive = true } }
                    }
                },
                Modifier.fillMaxWidth(),
                enabled = ui.accountId != null && ui.recipient != null && ui.draft.isNotBlank(),
                busy = ui.sending,
            )
        }
    }
}
