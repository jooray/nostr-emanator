package today.cypherpunk.emanator.ui.screens.accounts

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.navigation.NavHostController
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.Account
import today.cypherpunk.emanator.data.AccountDetail
import today.cypherpunk.emanator.data.EventsResponse
import today.cypherpunk.emanator.data.InteractionsResponse
import today.cypherpunk.emanator.data.Loadable
import today.cypherpunk.emanator.ui.LocalContainer
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.AlarmBlock
import today.cypherpunk.emanator.ui.components.Chop
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Legend
import today.cypherpunk.emanator.ui.components.LoadableContent
import today.cypherpunk.emanator.ui.components.NoteBlock
import today.cypherpunk.emanator.ui.components.PostRow
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.Readout
import today.cypherpunk.emanator.ui.components.RichContent
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.SlugTone
import today.cypherpunk.emanator.ui.components.WaitBlock
import today.cypherpunk.emanator.ui.components.rememberSnackbar
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links
import today.cypherpunk.emanator.util.Times

/**
 * One identity (web: accounts/show + accounts/settings): what is queued for it,
 * what it recently said and heard on relays, and everything that can be done
 * to it.
 */
@Composable
fun AccountScreen(nav: NavHostController, id: Long) {
    val container = LocalContainer.current
    val scope = rememberCoroutineScope()
    val snackbar = rememberSnackbar()

    val vm = appViewModel("account-$id") { c -> LoadVm(c.cache, "account/$id", AccountDetail.serializer()) { c.api.account(id) } }
    val events = appViewModel("account-events-$id") { c -> LoadVm(c.cache, "account/$id/events", EventsResponse.serializer()) { c.api.recentEvents(id) } }
    val heard = appViewModel("account-interactions-$id") { c ->
        LoadVm(c.cache, "account/$id/interactions", InteractionsResponse.serializer()) { c.api.recentInteractions(id) }
    }
    val state by vm.state.collectAsState()
    val eventsState by events.state.collectAsState()
    val heardState by heard.state.collectAsState()
    var confirmRemove by remember { mutableStateOf(false) }

    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { vm.load() }
    // Relay reads are slow (seconds): fetched once per visit, shown from the
    // phone's copy meanwhile.
    LaunchedEffect(id) {
        events.load()
        heard.load()
    }

    fun message(block: suspend () -> String?) = scope.launch {
        withSnackbar(snackbar) { block() }?.let { snackbar.showSnackbar(it) }
    }

    ConsoleScaffold(
        state.data?.account?.name ?: stringResource(R.string.acc_account),
        onBack = { nav.popBackStack() },
        snackbar = snackbar,
    ) { padding ->
        LoadableContent(state, onRefresh = { vm.load(); events.load(); heard.load() }, modifier = Modifier.padding(padding)) { detail ->
            val account = detail.account
            LazyColumn(Modifier.fillMaxSize()) {
                item { Header(account) }
                item {
                    PrimaryButton(stringResource(R.string.acc_new_post), { nav.navigate(Routes.compose(account = id)) },
                        Modifier.fillMaxWidth().padding(horizontal = Gutter, vertical = 8.dp))
                }
                item { Banners(account, nav) }

                item { SectionTitle(stringResource(R.string.acc_scheduled)) }
                if (detail.upcoming.isEmpty()) {
                    item {
                        Row(Modifier.padding(horizontal = Gutter, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(stringResource(R.string.acc_no_scheduled), style = Type.small, color = LocalConsole.current.muted)
                            SlugButton(stringResource(R.string.acc_create_one), { nav.navigate(Routes.compose(account = id)) })
                        }
                    }
                } else {
                    items(detail.upcoming, key = { "up-${it.id}" }) { post -> PostRow(post, onOpen = { nav.navigate(Routes.post(it.targetPostId)) }) }
                }

                recentEvents(eventsState)
                recentInteractions(heardState)

                item { SettingsSection(account, nav, onRefreshProfile = { message { container.api.refreshAccountProfile(id).message } },
                    onRefreshRelays = { message { container.api.refreshAccountRelays(id).message } }) }

                item {
                    Column(Modifier.padding(Gutter), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Legend(stringResource(R.string.acc_danger_zone), color = LocalConsole.current.redText)
                        Text(stringResource(R.string.acc_remove_help), style = Type.small, color = LocalConsole.current.muted)
                        SecondaryButton(stringResource(R.string.acc_remove_button), { confirmRemove = true }, danger = true)
                    }
                }
            }
        }
    }

    if (confirmRemove) {
        ConfirmDialog(
            stringResource(R.string.acc_remove_confirm),
            stringResource(R.string.acc_remove_button),
            onConfirm = {
                scope.launch {
                    if (withSnackbar(snackbar) { container.api.removeAccount(id) } != null) nav.popBackStack()
                }
            },
            onDismiss = { confirmRemove = false },
        )
    }
}

@Composable
private fun Header(account: Account) {
    val c = LocalConsole.current
    val context = LocalContext.current
    Row(Modifier.fillMaxWidth().padding(Gutter), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Chop(account.mini(), 64.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(account.name, style = Type.headline, color = c.text)
            account.username?.takeIf { it.isNotBlank() }?.let { Text("@$it", style = Type.small, color = c.legend) }
            account.npub?.let { npub ->
                Text(shortNpub(npub), style = Type.mono, color = c.muted, modifier = Modifier.clickable { Links.copy(context, "npub", npub) })
            }
            account.about?.takeIf { it.isNotBlank() }?.let { Text(it, style = Type.small, color = c.legend, maxLines = 6) }
            SlugButton(stringResource(R.string.action_open_in_client), { Links.openNostr(context, account.npub, account.profileUrl) })
        }
    }
    Rule()
}

@Composable
private fun Banners(account: Account, nav: NavHostController) {
    Column(Modifier.padding(horizontal = Gutter, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (!account.hasSigner) {
            AlarmBlock(stringResource(R.string.no_signer)) {
                SlugButton(stringResource(R.string.acc_re_pair_signer), { nav.navigate(Routes.pair(account.id)) }, tone = SlugTone.Short)
            }
        }
        if (account.messagingDenied) {
            AlarmBlock(stringResource(R.string.acc_messaging_denied)) {
                SlugButton(stringResource(R.string.acc_messaging_enable), { nav.navigate(Routes.pair(account.id, "messaging")) }, tone = SlugTone.Short)
            }
        } else if (account.needsMessagingRepair) {
            WaitBlock(stringResource(R.string.acc_messaging_not_granted)) {
                SlugButton(stringResource(R.string.acc_messaging_enable), { nav.navigate(Routes.pair(account.id, "messaging")) }, tone = SlugTone.Wait)
            }
        }
        if (account.relayAuthBlocked) {
            AlarmBlock(stringResource(R.string.acc_relay_auth_blocked, account.relayAuthBlockedRelay ?: "?"))
        }
    }
}

@Composable
private fun SectionTitle(text: String, help: String? = null) {
    Column(Modifier.padding(start = Gutter, end = Gutter, top = 24.dp, bottom = 8.dp)) {
        Legend(text)
        help?.let { Text(it, style = Type.small, color = LocalConsole.current.muted) }
    }
    Rule()
}

@Composable
private fun SmallLoading() {
    Row(Modifier.fillMaxWidth().padding(Gutter), horizontalArrangement = Arrangement.Center) {
        CircularProgressIndicator(Modifier.padding(4.dp), color = Palette.amber, strokeWidth = 2.dp)
    }
}

private fun LazyListScope.recentEvents(state: Loadable<EventsResponse>) {
    item {
        SectionTitle(stringResource(R.string.acc_recent_events), stringResource(R.string.acc_recent_events_help))
    }
    val events = state.data?.events
    when {
        events == null && state.loading -> item { SmallLoading() }
        events.isNullOrEmpty() -> item { NoteBlock(stringResource(R.string.acc_recent_events_empty), Modifier.padding(Gutter)) }
        else -> items(events.take(20), key = { "ev-${it.id}" }) { event ->
            val context = LocalContext.current
            Column(
                Modifier.fillMaxWidth().clickable { Links.openNostr(context, event.nevent, event.viewerUrl) }.padding(horizontal = Gutter, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                RichContent(event.content, event.references, style = Type.bodyDense, maxLines = 10)
                Text(Times.dateTime(Times.parse(event.createdAt)), style = Type.mono, color = LocalConsole.current.muted)
            }
            Rule()
        }
    }
}

private fun LazyListScope.recentInteractions(state: Loadable<InteractionsResponse>) {
    item {
        SectionTitle(stringResource(R.string.acc_recent_interactions), stringResource(R.string.acc_recent_interactions_help))
    }
    val list = state.data?.interactions
    when {
        list == null && state.loading -> item { SmallLoading() }
        list.isNullOrEmpty() -> item { NoteBlock(stringResource(R.string.acc_recent_interactions_empty), Modifier.padding(Gutter)) }
        else -> items(list, key = { "int-${it.eventId}" }) { interaction ->
            val context = LocalContext.current
            val c = LocalConsole.current
            Column(
                Modifier.fillMaxWidth().clickable { Links.openNostr(context, interaction.nevent, interaction.viewerUrl) }
                    .padding(horizontal = Gutter, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(interaction.author.name ?: shortNpub(interaction.author.npub), style = Type.label, color = c.text)
                    Text(interaction.type.uppercase(), style = Type.slug, color = c.muted)
                    Text(Times.age(Times.parse(interaction.createdAt)), style = Type.mono, color = c.muted)
                }
                interaction.original?.let { Text(it.content, style = Type.small, color = c.muted, maxLines = 2) }
                RichContent(interaction.content, interaction.references, style = Type.bodyDense, maxLines = 6, showMedia = false)
            }
            Rule()
        }
    }
}

@Composable
private fun SettingsSection(account: Account, nav: NavHostController, onRefreshProfile: () -> Unit, onRefreshRelays: () -> Unit) {
    val c = LocalConsole.current
    SectionTitle(stringResource(R.string.acc_settings))
    Column(Modifier.padding(Gutter), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (account.hasSigner) {
            Text(
                stringResource(if (account.messagingCapable) R.string.acc_messaging_enabled else R.string.acc_messaging_needs_repair).uppercase(),
                style = Type.slug, color = if (account.messagingCapable) c.legend else c.amberText,
            )
        }
        SecondaryButton(stringResource(R.string.acc_edit), { nav.navigate(Routes.accountEdit(account.id)) }, Modifier.fillMaxWidth())
        SecondaryButton(stringResource(R.string.acc_nostr_profile), { nav.navigate(Routes.accountProfile(account.id)) }, Modifier.fillMaxWidth())
        if (account.hasSigner && !account.profileEditingCapable) {
            Text(stringResource(R.string.acc_profile_needs_repair), style = Type.small, color = c.muted)
        }
        SecondaryButton(stringResource(R.string.acc_refresh_profile), onRefreshProfile, Modifier.fillMaxWidth())
        SecondaryButton(stringResource(R.string.acc_refresh_relays), onRefreshRelays, Modifier.fillMaxWidth())
        SecondaryButton(stringResource(R.string.acc_re_pair_signer), { nav.navigate(Routes.pair(account.id)) }, Modifier.fillMaxWidth())

        Readout(
            stringResource(R.string.acc_write_relays),
            account.writeRelays.joinToString("\n").ifBlank { stringResource(R.string.acc_no_write_relays) },
            mono = account.writeRelays.isNotEmpty(),
        )
        if (account.readRelays.isNotEmpty()) Readout(stringResource(R.string.acc_read_relays), account.readRelays.joinToString("\n"), mono = true)
        account.signerRelay?.let { Readout(stringResource(R.string.acc_signer_relay), it, mono = true) }
        account.blossomServer?.let { Readout(stringResource(R.string.acc_blossom_server), it, mono = true) }
        account.personality?.takeIf { it.isNotBlank() }?.let {
            Readout(stringResource(R.string.acc_personality), if (it.length > 400) it.take(400) + "…" else it)
        }
    }
}
