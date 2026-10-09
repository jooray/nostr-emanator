package today.cypherpunk.emanator.ui.screens.posts

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
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
import androidx.compose.ui.platform.LocalContext
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
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.BuildConfig
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.Dashboard
import today.cypherpunk.emanator.data.Loadable
import today.cypherpunk.emanator.data.PostItem
import today.cypherpunk.emanator.data.ReleaseInfo
import today.cypherpunk.emanator.data.cachedFlow
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.EmptyState
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Lamp
import today.cypherpunk.emanator.ui.components.LampState
import today.cypherpunk.emanator.ui.components.Legend
import today.cypherpunk.emanator.ui.components.LoadableContent
import today.cypherpunk.emanator.ui.components.NoteBlock
import today.cypherpunk.emanator.ui.components.PostRow
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.RowKind
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.SlugTone
import today.cypherpunk.emanator.ui.components.rememberSnackbar
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links

/**
 * The press run (web: dashboard/index). Ordered by what the operator needs
 * first: what waits on them, what barely reached the network, what goes out
 * next, and what never went out. The same board the web reads
 * (Dashboard::Board), so the two never disagree.
 */
class DashboardViewModel(private val container: AppContainer) : ViewModel() {
    private val _state = MutableStateFlow(Loadable<Dashboard>())
    val state: StateFlow<Loadable<Dashboard>> = _state.asStateFlow()
    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val messages = _messages.asSharedFlow()
    val update = MutableStateFlow<ReleaseInfo?>(null)
    private var job: Job? = null

    init {
        refresh()
        viewModelScope.launch {
            runCatching { container.api.meta() }.getOrNull()?.android?.let {
                if (it.latestVersionCode > BuildConfig.VERSION_CODE) update.value = it
            }
        }
    }

    fun refresh() {
        job?.cancel()
        job = viewModelScope.launch {
            cachedFlow(container.cache, "dashboard", Dashboard.serializer()) { container.api.dashboard() }
                .collect { _state.value = it }
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
    fun discardFailed() = act { container.api.discardFailed(null).message }
}

@Composable
fun DashboardScreen(nav: NavHostController) {
    val vm = appViewModel { DashboardViewModel(it) }
    val state by vm.state.collectAsState()
    val update by vm.update.collectAsState()
    val snackbar = rememberSnackbar()
    val context = LocalContext.current
    var confirmDiscard by remember { mutableStateOf(0) }

    LaunchedEffect(Unit) { vm.messages.collect { snackbar.showSnackbar(it) } }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { vm.refresh() }

    val open: (PostItem) -> Unit = { nav.navigate(Routes.post(it.targetPostId)) }

    ConsoleScaffold(
        title = stringResource(R.string.dash_title),
        snackbar = snackbar,
        floating = {
            FloatingActionButton(onClick = { nav.navigate(Routes.compose()) }, containerColor = Palette.amber, contentColor = Palette.contactBlack,
                shape = androidx.compose.foundation.shape.RoundedCornerShape(0.dp)) {
                Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.dash_new_post))
            }
        },
    ) { padding ->
        LoadableContent(state, onRefresh = vm::refresh, modifier = Modifier.padding(padding)) { board ->
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 96.dp)) {
                update?.let { info ->
                    NoteBlock(stringResource(R.string.update_available, info.latestVersionName), Modifier.padding(Gutter))
                    info.downloadUrl?.let { url ->
                        SlugButton(stringResource(R.string.update_get), { Links.openUrl(context, url) }, Modifier.padding(horizontal = Gutter))
                    }
                }

                if (!board.hasAccounts) {
                    NoIdentities { nav.navigate(Routes.pair()) }
                    return@Column
                }

                StationLine(board)

                if (board.waiting.isNotEmpty()) {
                    Section(stringResource(R.string.dash_waiting_on_you), LampState.Wait)
                    board.waiting.forEach { PostRow(it, open, kind = RowKind.Waiting) }
                }

                if (board.unreached.isNotEmpty()) {
                    Section(stringResource(R.string.dash_barely_reached_heading), LampState.Alarm)
                    Text(stringResource(R.string.dash_barely_reached_help), style = Type.small, color = LocalConsole.current.muted,
                        modifier = Modifier.padding(horizontal = Gutter, vertical = 6.dp))
                    board.unreached.forEach { PostRow(it, open, kind = RowKind.Short, onRebroadcast = vm::rebroadcast) }
                }

                Section(stringResource(R.string.dash_scheduled), LampState.Off) {
                    SlugButton(stringResource(R.string.dash_all_posts), { nav.navigate(Routes.posts()) })
                }
                if (board.upcoming.isEmpty()) {
                    EmptyState(stringResource(R.string.dash_nothing_scheduled))
                    SecondaryButton(stringResource(R.string.dash_write_one), { nav.navigate(Routes.compose()) },
                        Modifier.padding(horizontal = Gutter))
                } else {
                    board.upcoming.forEach { PostRow(it, open) }
                }

                if (board.failed.isNotEmpty()) {
                    Section(pluralStringResource(R.plurals.dash_never_went_out_total, board.failedTotal, board.failedTotal), LampState.Alarm) {
                        SlugButton(stringResource(R.string.posts_filter_failed), { nav.navigate(Routes.posts(status = "failed")) })
                    }
                    board.failed.forEach { PostRow(it, open, kind = RowKind.Failed, onRetry = vm::retry) }
                    SlugButton(
                        pluralStringResource(R.plurals.dash_discard_all, board.failedTotal, board.failedTotal),
                        { confirmDiscard = board.failedTotal },
                        Modifier.padding(horizontal = Gutter, vertical = 8.dp),
                        tone = SlugTone.Short,
                    )
                }

                if (board.recent.isNotEmpty()) {
                    Section(stringResource(R.string.dash_last_pulled), LampState.Off)
                    board.recent.forEach { PostRow(it, open, kind = RowKind.Sent) }
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

/** The rail's readings in one line: held, waiting, short, failed. */
@Composable
private fun StationLine(board: Dashboard) {
    FlowRow(
        Modifier.fillMaxWidth().padding(horizontal = Gutter, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Reading(pluralStringResource(R.plurals.dash_held, board.heldCount, board.heldCount), if (board.heldCount > 0) LampState.On else LampState.Off)
        if (board.summary.waiting > 0) Reading(pluralStringResource(R.plurals.dash_reading_waiting, board.summary.waiting, board.summary.waiting), LampState.Wait)
        if (board.summary.short > 0) Reading(pluralStringResource(R.plurals.dash_reading_short, board.summary.short, board.summary.short), LampState.Alarm)
        if (board.summary.failed > 0) Reading(pluralStringResource(R.plurals.dash_reading_failed, board.summary.failed, board.summary.failed), LampState.Alarm)
    }
    Rule()
}

@Composable
private fun Reading(text: String, lamp: LampState) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Lamp(lamp)
        Text(text.uppercase(), style = Type.label, color = LocalConsole.current.legend)
    }
}

@Composable
private fun Section(title: String, lamp: LampState, trailing: (@Composable () -> Unit)? = null) {
    Row(
        Modifier.fillMaxWidth().padding(start = Gutter, end = 8.dp, top = 24.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Lamp(lamp)
        Legend(title, Modifier.weight(1f))
        trailing?.invoke()
    }
    Rule()
}

@Composable
private fun NoIdentities(onPair: () -> Unit) {
    val c = LocalConsole.current
    Column(Modifier.fillMaxWidth().padding(Gutter), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(stringResource(R.string.dash_no_identities).uppercase(), style = Type.headline, color = c.text)
        Text(stringResource(R.string.dash_no_identities_help), style = Type.bodyDense, color = c.legend)
        PrimaryButton(stringResource(R.string.dash_pair_account), onPair, Modifier.fillMaxWidth())
    }
}
