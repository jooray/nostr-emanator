package today.cypherpunk.emanator.ui.screens.messages

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LifecycleEventEffect
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
import today.cypherpunk.emanator.data.AccountMini
import today.cypherpunk.emanator.data.AccountsResponse
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.Conversation
import today.cypherpunk.emanator.data.Inbox
import today.cypherpunk.emanator.data.cachedFlow
import today.cypherpunk.emanator.ui.LocalContainer
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.Avatar
import today.cypherpunk.emanator.ui.components.Chop
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.EmptyState
import today.cypherpunk.emanator.ui.components.ErrorState
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Lamp
import today.cypherpunk.emanator.ui.components.LampState
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SavedCopyNotice
import today.cypherpunk.emanator.ui.components.Slug
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.SlugTone
import today.cypherpunk.emanator.ui.components.WaitBlock
import today.cypherpunk.emanator.ui.components.rememberSnackbar
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Times

data class InboxUi(
    val tab: String = "known",
    val unreadOnly: Boolean = false,
    val inbox: Inbox? = null,
    val conversations: List<Conversation> = emptyList(),
    val nextPage: Int? = null,
    val loading: Boolean = false,
    val loadingMore: Boolean = false,
    val error: ApiException? = null,
    val fromCache: Boolean = false,
)

/**
 * One inbox across every paired account (web: conversations#index). The
 * account filter lives on the server, shared with the web: a request with no
 * account_ids gets the saved choice back; changing it sends the new set.
 */
class MessagesViewModel(private val container: AppContainer) : ViewModel() {
    private val _ui = MutableStateFlow(InboxUi())
    val ui = _ui.asStateFlow()

    private val _accounts = MutableStateFlow<List<AccountMini>>(emptyList())
    val accounts = _accounts.asStateFlow()

    private var job: Job? = null

    init {
        viewModelScope.launch {
            cachedFlow(container.cache, "accounts", AccountsResponse.serializer()) { container.api.accounts() }
                .collect { state -> state.data?.let { _accounts.value = it.accounts.map { a -> a.mini() } } }
        }
        refresh()
    }

    private fun cacheKey(ui: InboxUi) = "inbox:${ui.tab}:${ui.unreadOnly}"

    /** Page 1 again. `accountIds` non-null changes (and persists) the filter. */
    fun refresh(accountIds: List<Long>? = null, quiet: Boolean = false) {
        job?.cancel()
        val snapshot = _ui.value
        job = viewModelScope.launch {
            if (!quiet) _ui.update { it.copy(loading = true) }
            if (snapshot.inbox == null) {
                container.cache.read(cacheKey(snapshot), Inbox.serializer())?.let { cached ->
                    _ui.update { it.copy(inbox = cached, conversations = cached.conversations, nextPage = cached.pagination.nextPage, fromCache = true) }
                }
            }
            try {
                val inbox = container.api.inbox(snapshot.tab, snapshot.unreadOnly, 1, accountIds)
                container.cache.write(cacheKey(snapshot), Inbox.serializer(), inbox)
                _ui.update {
                    it.copy(inbox = inbox, conversations = inbox.conversations, nextPage = inbox.pagination.nextPage,
                        loading = false, error = null, fromCache = false)
                }
            } catch (e: ApiException) {
                _ui.update { it.copy(loading = false, error = e) }
            }
        }
    }

    fun loadMore() {
        val state = _ui.value
        val page = state.nextPage ?: return
        if (state.loadingMore) return
        viewModelScope.launch {
            _ui.update { it.copy(loadingMore = true) }
            try {
                val inbox = container.api.inbox(state.tab, state.unreadOnly, page)
                _ui.update {
                    it.copy(conversations = (it.conversations + inbox.conversations).distinctBy { c -> c.id },
                        nextPage = inbox.pagination.nextPage, loadingMore = false)
                }
            } catch (e: ApiException) {
                _ui.update { it.copy(loadingMore = false, error = e) }
            }
        }
    }

    fun setTab(tab: String) {
        if (tab == _ui.value.tab) return
        _ui.update { InboxUi(tab = tab, unreadOnly = it.unreadOnly) }
        refresh()
    }

    fun setUnreadOnly(on: Boolean) {
        _ui.update { InboxUi(tab = it.tab, unreadOnly = on) }
        refresh()
    }

    fun toggleAccount(id: Long) {
        val all = _accounts.value.map { it.id }
        val next = toggleAccount(_ui.value.inbox?.accountFilter.orEmpty().toSet(), all, id)
        _ui.update { it.copy(inbox = it.inbox?.copy(accountFilter = next.toList())) }
        refresh(next.toList())
    }

    fun selectAll() {
        _ui.update { it.copy(inbox = it.inbox?.copy(accountFilter = emptyList())) }
        refresh(emptyList())
    }

    fun markAllRead(onDone: (Int) -> Unit) {
        viewModelScope.launch {
            try {
                val result = container.api.markAllRead(_ui.value.tab)
                onDone(result.cleared)
                refresh(quiet = true)
                refreshBadges(container)
            } catch (e: ApiException) {
                _ui.update { it.copy(error = e) }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MessagesScreen(nav: NavHostController) {
    val vm = appViewModel { MessagesViewModel(it) }
    val ui by vm.ui.collectAsState()
    val accounts by vm.accounts.collectAsState()
    val container = LocalContainer.current
    val c = LocalConsole.current
    val snackbar = rememberSnackbar()
    val scope = rememberCoroutineScope()
    val resources = LocalResources.current
    var confirmMarkAll by remember { mutableStateOf(false) }

    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        vm.refresh(quiet = true)
        scope.launch { refreshBadges(container) }
    }
    // New messages arrive in the background; keep the list current while it is on screen.
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle) {
        // Only while on screen; polling in the background just drains the battery.
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) {
                delay(30_000)
                vm.refresh(quiet = true)
            }
        }
    }

    ConsoleScaffold(stringResource(R.string.nav_messages), snackbar = snackbar) { padding ->
        PullToRefreshBox(
            isRefreshing = ui.loading && ui.inbox != null,
            onRefresh = { vm.refresh() },
            modifier = Modifier.fillMaxSize().padding(padding),
        ) {
            LazyColumn(Modifier.fillMaxSize()) {
                item {
                    if (ui.loading) {
                        LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp), color = Palette.amber, trackColor = Color.Transparent)
                    }
                    Text(stringResource(R.string.msg_subtitle).uppercase(), style = Type.slug, color = c.muted,
                        modifier = Modifier.padding(horizontal = Gutter, vertical = 10.dp))
                }

                val inbox = ui.inbox
                if (inbox == null) {
                    item {
                        when {
                            ui.error != null -> ErrorState(ui.error!!) { vm.refresh() }
                            else -> Box(Modifier.fillMaxWidth().padding(48.dp), contentAlignment = Alignment.Center) {
                                CircularProgressIndicator(color = Palette.amber, strokeWidth = 2.dp)
                            }
                        }
                    }
                    return@LazyColumn
                }

                ui.error?.let { error -> if (!error.isUnauthorized) item { SavedCopyNotice(error) } }

                if (accounts.isEmpty() && inbox.counts.known + inbox.counts.requests == 0 && !ui.fromCache) {
                    item {
                        Column(Modifier.padding(Gutter), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            EmptyState(stringResource(R.string.msg_no_accounts))
                            PrimaryButton(stringResource(R.string.msg_add_account), { nav.navigate(Routes.pair()) }, Modifier.fillMaxWidth())
                        }
                    }
                    return@LazyColumn
                }

                if (inbox.accountsNeedingRepair.isNotEmpty()) {
                    item { RepairNotice(inbox.accountsNeedingRepair) { nav.navigate(Routes.pair(it, "messaging")) } }
                }
                if (inbox.accountsRelayAuthBlocked.isNotEmpty()) {
                    item { RelayAuthNotice(inbox) }
                }
                inbox.sync.filter { !it.step.isNullOrBlank() }.takeIf { it.isNotEmpty() }?.let { syncing ->
                    item {
                        Column(Modifier.padding(horizontal = Gutter, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            syncing.forEach { WaitBlock(it.step!!) }
                        }
                    }
                }

                item {
                    Tabs(ui.tab, inbox.counts.known, inbox.counts.requests, vm::setTab)
                    if (accounts.size > 1) {
                        Row(Modifier.padding(start = Gutter, top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(stringResource(R.string.msg_who).uppercase(), style = Type.slug, color = c.muted)
                            if (inbox.accountFilter.isNotEmpty()) {
                                SlugButton(stringResource(R.string.msg_select_all), vm::selectAll, tone = SlugTone.Wait)
                            }
                        }
                        AccountPills(
                            accounts, inbox.accountFilter.toSet(), vm::toggleAccount,
                            Modifier.padding(horizontal = Gutter, vertical = 8.dp),
                        )
                    }
                    Row(Modifier.padding(horizontal = Gutter - 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        SlugButton(
                            stringResource(R.string.msg_unread_only) + if (ui.unreadOnly) " ×" else "",
                            { vm.setUnreadOnly(!ui.unreadOnly) },
                            tone = if (ui.unreadOnly) SlugTone.Wait else SlugTone.Plain,
                        )
                        SlugButton(stringResource(R.string.msg_mark_all_read), { confirmMarkAll = true })
                    }
                    Rule()
                }

                if (ui.conversations.isEmpty()) {
                    item {
                        Column {
                            EmptyState(stringResource(if (ui.tab == "requests") R.string.msg_no_requests else R.string.msg_no_messages))
                            if (ui.tab == "known") {
                                Text(stringResource(R.string.msg_known_hint), style = Type.small, color = c.muted,
                                    modifier = Modifier.padding(horizontal = 32.dp).fillMaxWidth())
                            }
                        }
                    }
                } else {
                    items(ui.conversations, key = { it.id }) { conversation ->
                        ConversationRow(conversation, ui.tab) { nav.navigate(Routes.conversation(conversation.id)) }
                    }
                    if (ui.nextPage != null) {
                        item {
                            LaunchedEffect(ui.nextPage) { vm.loadMore() }
                            Box(Modifier.fillMaxWidth().padding(20.dp), contentAlignment = Alignment.Center) {
                                CircularProgressIndicator(Modifier.size(20.dp), color = Palette.amber, strokeWidth = 2.dp)
                            }
                        }
                    }
                }
            }
        }
    }

    if (confirmMarkAll) {
        ConfirmDialog(
            stringResource(R.string.msg_mark_all_read_confirm),
            stringResource(R.string.msg_mark_all_read),
            onConfirm = {
                vm.markAllRead { cleared ->
                    scope.launch {
                        snackbar.showSnackbar(
                            if (cleared > 0) resources.getQuantityString(R.plurals.msg_marked, cleared, cleared)
                            else resources.getString(R.string.msg_nothing_unread),
                        )
                    }
                }
            },
            onDismiss = { confirmMarkAll = false },
        )
    }
}

@Composable
private fun Tabs(current: String, known: Int, requests: Int, onSelect: (String) -> Unit) {
    val c = LocalConsole.current
    Row(Modifier.fillMaxWidth().padding(horizontal = Gutter)) {
        listOf("known" to (R.string.msg_tab_known to known), "requests" to (R.string.msg_tab_requests to requests)).forEach { (tab, info) ->
            val selected = tab == current
            Column(Modifier.padding(end = 24.dp).width(IntrinsicSize.Max).clickable { onSelect(tab) }) {
                Row(Modifier.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(info.first).uppercase(), style = Type.label, color = if (selected) c.text else c.muted)
                    Text("${info.second}", style = Type.readout, color = c.muted)
                }
                Box(Modifier.height(2.dp).fillMaxWidth().background(if (selected) Palette.amber else Color.Transparent))
            }
        }
    }
    Rule()
}

@Composable
private fun ConversationRow(conversation: Conversation, tab: String, onOpen: () -> Unit) {
    val c = LocalConsole.current
    val peer = conversation.peers.firstOrNull()
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(horizontal = Gutter, vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Avatar(peer?.pictureUrl ?: conversation.account?.pictureUrl, peer?.name ?: conversation.title, 40.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(conversation.title, style = Type.bodyDense, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f))
                Text(Times.age(Times.parse(conversation.lastMessageAt)), style = Type.mono, color = c.muted)
            }
            Text(
                buildString {
                    if (conversation.lastMessageFromSelf) append(stringResource(R.string.msg_row_you)).append(' ')
                    append(conversation.lastMessagePreview?.takeIf { it.isNotBlank() } ?: conversation.subject?.takeIf { it.isNotBlank() }
                        ?: stringResource(R.string.msg_row_no_preview))
                },
                style = Type.small, color = c.legend, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                conversation.account?.let {
                    Chop(it, 16.dp)
                    Text(it.name.uppercase(), style = Type.slug, color = c.muted, maxLines = 1)
                }
                if (conversation.legacy) Slug(stringResource(R.string.msg_row_legacy_badge), SlugTone.Short)
                if (conversation.group) {
                    Text(pluralStringResource(R.plurals.msg_row_people, conversation.peers.size + 1, conversation.peers.size + 1),
                        style = Type.slug, color = c.muted)
                }
            }
            conversation.classificationBadge?.let { Text(it, style = Type.small, color = c.muted) }
        }
        if (conversation.unreadCount > 0) {
            if (tab == "known") {
                Text(
                    if (conversation.unreadCount > 99) "99+" else "${conversation.unreadCount}",
                    style = Type.readout, color = Palette.contactBlack,
                    modifier = Modifier.background(Palette.amber).padding(horizontal = 6.dp, vertical = 2.dp),
                )
            } else {
                // Spam must never drive a number: Requests get an unnumbered dot.
                Lamp(LampState.On, Modifier.padding(top = 6.dp))
            }
        }
    }
    Rule()
}

/** Accounts paired before messaging existed: one line, the fix folded behind it. */
@Composable
private fun RepairNotice(accounts: List<AccountMini>, onRePair: (Long) -> Unit) {
    val c = LocalConsole.current
    var open by remember { mutableStateOf(accounts.size == 1) }
    Column(Modifier.padding(horizontal = Gutter, vertical = 6.dp).fillMaxWidth().border(1.dp, c.rule)) {
        Row(Modifier.fillMaxWidth().clickable { open = !open }.padding(12.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Lamp(LampState.Off)
            Column(Modifier.weight(1f)) {
                Text(pluralStringResource(R.plurals.msg_repair_summary, accounts.size, accounts.size).uppercase(), style = Type.label, color = c.text)
                Text(stringResource(R.string.msg_repair_hint), style = Type.small, color = c.muted)
            }
        }
        if (open) {
            Rule()
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(stringResource(R.string.msg_repair_explanation), style = Type.small, color = c.legend)
                accounts.forEach { account ->
                    Row(Modifier.fillMaxWidth().clickable { onRePair(account.id) }.padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Box(Modifier.width(3.dp).height(16.dp).background(inkOf(account)))
                        Text(account.name.uppercase(), style = Type.label, color = c.text, modifier = Modifier.weight(1f))
                        Text(stringResource(if (accounts.size == 1) R.string.msg_enable_messaging else R.string.msg_re_pair).uppercase(),
                            style = Type.slug, color = c.amberText)
                    }
                }
            }
        }
    }
}

/**
 * The NIP-42 trap: a relay serves gift wraps only to an authenticated client,
 * and the signer did not sign. Neutral, not an alarm — messages keep arriving
 * through every other relay — with the fix stated once behind a disclosure.
 */
@Composable
private fun RelayAuthNotice(inbox: Inbox) {
    val c = LocalConsole.current
    var open by remember { mutableStateOf(false) }
    val blocked = inbox.accountsRelayAuthBlocked
    val hosts = blocked.mapNotNull { it.relay }.distinct()
    Column(Modifier.padding(horizontal = Gutter, vertical = 6.dp).fillMaxWidth().border(1.dp, c.rule)) {
        Row(Modifier.fillMaxWidth().clickable { open = !open }.padding(12.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Lamp(LampState.Off)
            Column(Modifier.weight(1f)) {
                Text(pluralStringResource(R.plurals.msg_not_authenticated, blocked.size, blocked.size).uppercase(), style = Type.label, color = c.text)
                Text(pluralStringResource(R.plurals.msg_still_arrive, hosts.size.coerceAtLeast(1), hosts.size), style = Type.small, color = c.muted)
            }
        }
        if (open) {
            Rule()
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                blocked.forEach { account ->
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(account.name.uppercase(), style = Type.label, color = c.text)
                        account.relay?.let { Text(it, style = Type.mono, color = c.muted) }
                    }
                }
                Text(stringResource(R.string.msg_auth_explainer), style = Type.small, color = c.legend)
                Text("• " + stringResource(R.string.msg_auth_missed_prompt), style = Type.small, color = c.legend)
                Text("• " + stringResource(R.string.msg_auth_whitelist, hosts.joinToString(", ")), style = Type.small, color = c.legend)
            }
        }
    }
}
