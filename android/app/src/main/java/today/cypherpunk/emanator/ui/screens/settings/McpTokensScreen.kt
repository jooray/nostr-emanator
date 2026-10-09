package today.cypherpunk.emanator.ui.screens.settings

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.McpToken
import today.cypherpunk.emanator.data.McpTokens
import today.cypherpunk.emanator.ui.LocalContainer
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.AlarmBlock
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.EmptyState
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Legend
import today.cypherpunk.emanator.ui.components.LoadableContent
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.SlugTone
import today.cypherpunk.emanator.ui.components.WaitBlock
import today.cypherpunk.emanator.ui.components.rememberSnackbar
import today.cypherpunk.emanator.ui.screens.accounts.ConfirmDialog
import today.cypherpunk.emanator.ui.screens.accounts.Field
import today.cypherpunk.emanator.ui.screens.accounts.LoadVm
import today.cypherpunk.emanator.ui.screens.accounts.withSnackbar
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links
import today.cypherpunk.emanator.util.Times

/**
 * MCP tokens for AI agents (web: users/_api_tokens). The warning is not
 * decoration: a token can schedule posts that Amber then signs without a
 * prompt, so it is a posting key in all but name.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun McpTokensScreen(nav: NavHostController) {
    val container = LocalContainer.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbar = rememberSnackbar()
    val vm = appViewModel("mcp-tokens") { c -> LoadVm(c.cache, "mcp_tokens", McpTokens.serializer()) { c.api.mcpTokens() } }
    val state by vm.state.collectAsState()
    LaunchedEffect(Unit) { vm.load() }

    var name by rememberSaveable { mutableStateOf("") }
    var days by rememberSaveable { mutableIntStateOf(90) }
    var created by remember { mutableStateOf<McpToken?>(null) }
    var creating by remember { mutableStateOf(false) }
    var revoke by remember { mutableStateOf<McpToken?>(null) }

    ConsoleScaffold(stringResource(R.string.mcp_title), onBack = { nav.popBackStack() }, snackbar = snackbar) { padding ->
        LoadableContent(state, onRefresh = vm::load, modifier = Modifier.padding(padding).imePadding()) { data ->
            val c = LocalConsole.current
            LazyColumn(Modifier.fillMaxSize()) {
                item {
                    Column(Modifier.padding(Gutter), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(stringResource(R.string.mcp_intro, data.endpoint ?: "/mcp"), style = Type.small, color = c.legend)
                        AlarmBlock(stringResource(R.string.mcp_warning))

                        created?.let { token ->
                            WaitBlock(stringResource(R.string.mcp_created, token.name))
                            SelectionContainer {
                                Text(token.token.orEmpty(), style = Type.mono, color = c.text,
                                    modifier = Modifier.fillMaxWidth().border(1.dp, c.rule).padding(10.dp))
                            }
                            SlugButton(stringResource(R.string.action_copy), {
                                token.token?.let { Links.copy(context, "MCP token", it) }
                            }, tone = SlugTone.Wait)
                        }

                        Field(stringResource(R.string.mcp_name_label), name, { name = it }, placeholder = stringResource(R.string.mcp_name_placeholder))
                        Text(stringResource(R.string.mcp_expires_label).uppercase(), style = Type.slug, color = c.muted)
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            data.expiryOptionsDays.forEach { option -> Chip(expiryLabel(option), days == option) { days = option } }
                        }
                        PrimaryButton(stringResource(R.string.mcp_generate), {
                            creating = true
                            scope.launch {
                                withSnackbar(snackbar) { container.api.createMcpToken(name.trim(), days) }?.let {
                                    created = it
                                    name = ""
                                    vm.load()
                                }
                                creating = false
                            }
                        }, Modifier.fillMaxWidth(), enabled = name.isNotBlank(), busy = creating)
                    }
                    Rule()
                    Legend(stringResource(R.string.mcp_title), Modifier.padding(Gutter))
                    Rule()
                }
                if (data.tokens.isEmpty()) item { EmptyState(stringResource(R.string.mcp_empty)) }
                items(data.tokens, key = { it.id }) { token -> TokenRow(token) { revoke = token } }
            }
        }
    }

    revoke?.let { token ->
        ConfirmDialog(
            stringResource(R.string.mcp_revoke_confirm), stringResource(R.string.mcp_revoke),
            onConfirm = {
                scope.launch {
                    if (withSnackbar(snackbar) { container.api.revokeMcpToken(token.id) } != null) {
                        if (created?.id == token.id) created = null
                        vm.load()
                    }
                }
            },
            onDismiss = { revoke = null },
        )
    }
}

@Composable
private fun expiryLabel(days: Int) = when (days) {
    30 -> stringResource(R.string.mcp_expiry_30)
    90 -> stringResource(R.string.mcp_expiry_90)
    180 -> stringResource(R.string.mcp_expiry_180)
    365 -> stringResource(R.string.mcp_expiry_year)
    0 -> stringResource(R.string.mcp_expiry_never)
    else -> "$days"
}

@Composable
private fun TokenRow(token: McpToken, onRevoke: () -> Unit) {
    val c = LocalConsole.current
    Row(Modifier.fillMaxWidth().padding(horizontal = Gutter, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(token.name, style = Type.title, color = c.text)
            token.preview?.let { Text(it, style = Type.mono, color = c.muted) }
            val expires = Times.parse(token.expiresAt)
            Text(
                when {
                    expires == null -> stringResource(R.string.mcp_no_expiry)
                    token.expired -> stringResource(R.string.mcp_expired_on, Times.date(expires))
                    else -> stringResource(R.string.mcp_expires_on, Times.date(expires))
                },
                style = Type.small, color = if (token.expired) c.redText else c.muted,
            )
            val used = Times.parse(token.lastUsedAt)
            Text(
                if (used != null) stringResource(R.string.mcp_last_used, Times.age(used)) else stringResource(R.string.mcp_never_used),
                style = Type.small, color = c.muted,
            )
        }
        SlugButton(stringResource(R.string.mcp_revoke), onRevoke, tone = SlugTone.Short)
    }
    Rule()
}
