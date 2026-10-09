package today.cypherpunk.emanator.ui.screens.accounts

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.navigation.NavHostController
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.Account
import today.cypherpunk.emanator.data.AccountsResponse
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.Chop
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.EmptyState
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.LoadableContent
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.Slug
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.SlugTone
import today.cypherpunk.emanator.ui.components.WaitBlock
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links

/** Every paired identity (web: accounts/index). */
@Composable
fun AccountsScreen(nav: NavHostController) {
    val vm = appViewModel("accounts") { c -> LoadVm(c.cache, "accounts", AccountsResponse.serializer()) { c.api.accounts() } }
    val state by vm.state.collectAsState()
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { vm.load() }

    ConsoleScaffold(
        stringResource(R.string.acc_title),
        onBack = { nav.popBackStack() },
        actions = {
            IconButton(onClick = { nav.navigate(Routes.pair()) }) {
                Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.acc_pair), tint = LocalConsole.current.text)
            }
        },
    ) { padding ->
        LoadableContent(state, onRefresh = vm::load, modifier = Modifier.padding(padding)) { data ->
            AccountsList(data.accounts, nav)
        }
    }
}

@Composable
private fun AccountsList(accounts: List<Account>, nav: NavHostController) {
    val needRepair = accounts.filter { it.needsMessagingRepair }
    LazyColumn(Modifier.fillMaxSize()) {
        if (needRepair.isNotEmpty()) {
            item {
                WaitBlock(
                    pluralStringResource(R.plurals.acc_repair_summary, needRepair.size, needRepair.size) + ". " +
                        stringResource(R.string.acc_repair_hint),
                    Modifier.padding(Gutter),
                )
            }
            items(needRepair, key = { "repair-${it.id}" }) { account ->
                Row(Modifier.fillMaxWidth().padding(horizontal = Gutter), verticalAlignment = Alignment.CenterVertically) {
                    Text(account.name, style = Type.bodyDense, color = LocalConsole.current.text, modifier = Modifier.weight(1f))
                    SlugButton(stringResource(R.string.acc_repair_action), { nav.navigate(Routes.pair(account.id, "messaging")) }, tone = SlugTone.Wait)
                }
            }
        }
        if (accounts.isEmpty()) {
            item {
                Column(Modifier.padding(Gutter), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(stringResource(R.string.acc_empty_title).uppercase(), style = Type.title, color = LocalConsole.current.text)
                    EmptyState(stringResource(R.string.acc_empty_body))
                }
            }
        }
        item {
            PrimaryButton(stringResource(R.string.acc_pair), { nav.navigate(Routes.pair()) }, Modifier.fillMaxWidth().padding(Gutter))
            Rule()
        }
        items(accounts, key = { it.id }) { account -> AccountRow(account) { nav.navigate(Routes.account(account.id)) } }
    }
}

@Composable
private fun AccountRow(account: Account, onOpen: () -> Unit) {
    val c = LocalConsole.current
    val context = LocalContext.current
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(horizontal = Gutter, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Chop(account.mini(), 44.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(account.name, style = Type.title, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            account.npub?.let { npub ->
                Text(
                    shortNpub(npub), style = Type.mono, color = c.muted,
                    modifier = Modifier.clickable { Links.copy(context, "npub", npub) },
                )
            }
            account.counts?.let { counts ->
                Text(
                    pluralStringResource(R.plurals.acc_posts_count, counts.total, counts.total) +
                        if (counts.upcoming > 0) " · " + pluralStringResource(R.plurals.acc_upcoming_count, counts.upcoming, counts.upcoming) else "",
                    style = Type.small, color = c.legend,
                )
            }
        }
        if (account.hasSigner) {
            Slug(stringResource(R.string.acc_signer_connected))
        } else {
            Slug(stringResource(R.string.acc_no_signer), SlugTone.Short)
        }
    }
    Rule()
}
