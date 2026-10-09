package today.cypherpunk.emanator.ui.screens.posts

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.viewModelScope
import androidx.navigation.NavHostController
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.AccountsResponse
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.Loadable
import today.cypherpunk.emanator.data.PostItem
import today.cypherpunk.emanator.data.PostsPage
import today.cypherpunk.emanator.data.cachedFlow
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.EmptyState
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.LoadableContent
import today.cypherpunk.emanator.ui.components.PostRow
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.SlugTone
import today.cypherpunk.emanator.ui.components.rememberSnackbar
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type

/**
 * All posts across every identity, filterable by account and state (web:
 * posts/index). The failed and awaiting filters include reposts, because the
 * station readings count them.
 */
class PostsViewModel(private val container: AppContainer, status: String?, account: Long?) : ViewModel() {
    val status = MutableStateFlow(status)
    val account = MutableStateFlow(account)
    val state = MutableStateFlow(Loadable<PostsPage>())
    val accounts = MutableStateFlow<AccountsResponse?>(null)
    val loadingMore = MutableStateFlow(false)
    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val messages = _messages.asSharedFlow()
    private var job: Job? = null

    init {
        refresh()
        viewModelScope.launch {
            cachedFlow(container.cache, "accounts", AccountsResponse.serializer()) { container.api.accounts() }
                .collect { it.data?.let { data -> accounts.value = data } }
        }
    }

    private fun key() = "posts:${status.value.orEmpty()}:${account.value ?: 0}"

    fun setFilter(newStatus: String?, newAccount: Long?) {
        status.value = newStatus
        account.value = newAccount
        refresh()
    }

    fun refresh() {
        job?.cancel()
        moreJob?.cancel()
        loadingMore.value = false
        job = viewModelScope.launch {
            cachedFlow(container.cache, key(), PostsPage.serializer()) {
                container.api.posts(account.value, status.value, 1)
            }.collect { state.value = it }
        }
    }

    private var moreJob: Job? = null

    /**
     * Back from a post: re-read every page already loaded, so the list keeps
     * its length (and the scroll position) instead of snapping to page one.
     */
    fun refreshKeepingPages() {
        val loaded = state.value.data?.pagination?.page ?: 1
        if (loaded <= 1) return refresh()
        job?.cancel()
        moreJob?.cancel()
        job = viewModelScope.launch {
            try {
                val pages = (1..loaded).map { container.api.posts(account.value, status.value, it) }
                state.value = Loadable(data = pages.last().copy(items = pages.flatMap { it.items }, failedHere = pages.first().failedHere))
            } catch (e: ApiException) {
                state.value = state.value.copy(error = e)
            }
        }
    }

    fun loadMore() {
        val current = state.value.data ?: return
        val next = current.pagination.nextPage ?: return
        if (loadingMore.value) return
        loadingMore.value = true
        moreJob = viewModelScope.launch {
            try {
                val page = container.api.posts(account.value, status.value, next)
                state.value = state.value.copy(data = page.copy(items = current.items + page.items))
            } catch (e: ApiException) {
                _messages.emit(e.message)
            } finally {
                loadingMore.value = false
            }
        }
    }

    private fun act(block: suspend () -> String?) {
        viewModelScope.launch {
            try {
                block()?.let { _messages.emit(it) }
            } catch (e: ApiException) {
                _messages.emit(e.message)
            }
            refresh()
            refreshBadges(container)
        }
    }

    fun retry(item: PostItem) = act { retryRow(container, item) }
    fun rebroadcast(item: PostItem) = act { rebroadcastRow(container, item) }
    fun discardFailed() = act { container.api.discardFailed(account.value).message }
}

@Composable
fun PostsScreen(nav: NavHostController, status: String?, accountId: Long?) {
    val vm = appViewModel(key = "posts:$status:$accountId") { PostsViewModel(it, status, accountId) }
    val state by vm.state.collectAsState()
    val selectedStatus by vm.status.collectAsState()
    val selectedAccount by vm.account.collectAsState()
    val accounts by vm.accounts.collectAsState()
    val loadingMore by vm.loadingMore.collectAsState()
    val snackbar = rememberSnackbar()
    var confirmDiscard by remember { mutableStateOf(0) }
    val c = LocalConsole.current

    LaunchedEffect(Unit) { vm.messages.collect { snackbar.showSnackbar(it) } }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { vm.refreshKeepingPages() }

    val statusOptions = listOf<Pair<String?, String>>(
        null to stringResource(R.string.posts_filter_all),
        "draft" to stringResource(R.string.posts_filter_draft),
        "awaiting_signature" to stringResource(R.string.posts_filter_awaiting_signature),
        "scheduled" to stringResource(R.string.posts_filter_scheduled),
        "published" to stringResource(R.string.posts_filter_published),
        "short" to stringResource(R.string.posts_filter_short),
        "failed" to stringResource(R.string.posts_filter_failed),
    )
    val accountOptions = listOf<Pair<Long?, String>>(null to stringResource(R.string.posts_all_accounts)) +
        accounts?.accounts.orEmpty().map { it.id to it.name }

    ConsoleScaffold(
        title = stringResource(R.string.posts_title),
        snackbar = snackbar,
        floating = {
            FloatingActionButton(
                onClick = { nav.navigate(Routes.compose(account = selectedAccount)) },
                containerColor = Palette.amber, contentColor = Palette.contactBlack,
                shape = androidx.compose.foundation.shape.RoundedCornerShape(0.dp),
            ) { Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.nav_new_post)) }
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            Column(Modifier.padding(vertical = 8.dp)) {
                ChipRow(statusOptions, selectedStatus, { vm.setFilter(it, selectedAccount) })
                if (accountOptions.size > 2) {
                    ChipRow(accountOptions, selectedAccount, { vm.setFilter(selectedStatus, it) })
                }
            }
            Rule()
            LoadableContent(state, onRefresh = vm::refresh) { page ->
                val filtered = selectedStatus != null || selectedAccount != null
                LazyColumn(Modifier.fillMaxSize()) {
                    if (selectedStatus == "failed" && page.failedHere > 0) {
                        item {
                            Row(Modifier.fillMaxWidth().padding(horizontal = Gutter, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    pluralStringResource(R.plurals.dash_never_went_out_total, page.failedHere, page.failedHere).uppercase(),
                                    style = Type.label, color = c.redText, modifier = Modifier.weight(1f),
                                )
                                SlugButton(
                                    pluralStringResource(R.plurals.dash_discard_all, page.failedHere, page.failedHere),
                                    { confirmDiscard = page.failedHere }, tone = SlugTone.Short,
                                )
                            }
                            Rule()
                        }
                    }
                    if (page.items.isEmpty()) {
                        item {
                            EmptyState(
                                when {
                                    selectedStatus == "short" -> stringResource(R.string.posts_empty_short)
                                    filtered -> stringResource(R.string.posts_empty_filtered)
                                    else -> stringResource(R.string.posts_empty_none)
                                },
                            )
                            if (filtered) {
                                SecondaryButton(stringResource(R.string.posts_clear_filters), { vm.setFilter(null, null) },
                                    Modifier.padding(horizontal = Gutter))
                            } else {
                                SecondaryButton(stringResource(R.string.dash_write_one), { nav.navigate(Routes.compose()) },
                                    Modifier.padding(horizontal = Gutter))
                            }
                        }
                    }
                    items(page.items, key = { "${it.type}-${it.id}" }) { item ->
                        PostRow(
                            item,
                            onOpen = { nav.navigate(Routes.post(it.targetPostId)) },
                            onRetry = vm::retry,
                            onRebroadcast = vm::rebroadcast,
                        )
                    }
                    if (page.pagination.nextPage != null) {
                        item {
                            Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = androidx.compose.foundation.layout.Arrangement.Center) {
                                if (loadingMore) CircularProgressIndicator(color = Palette.amber, strokeWidth = 2.dp)
                                else SecondaryButton(stringResource(R.string.action_load_more), vm::loadMore)
                            }
                        }
                    }
                    item { androidx.compose.foundation.layout.Spacer(Modifier.padding(bottom = 88.dp)) }
                }
            }
        }
    }

    if (confirmDiscard > 0) {
        ConfirmDialog(
            text = pluralStringResource(R.plurals.dash_discard_confirm, confirmDiscard, confirmDiscard),
            confirmLabel = pluralStringResource(R.plurals.dash_discard_all, confirmDiscard, confirmDiscard),
            onConfirm = vm::discardFailed,
            onDismiss = { confirmDiscard = 0 },
        )
    }
}
