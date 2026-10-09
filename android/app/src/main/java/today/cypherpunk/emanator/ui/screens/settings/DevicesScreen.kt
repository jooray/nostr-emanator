package today.cypherpunk.emanator.ui.screens.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.Device
import today.cypherpunk.emanator.data.DevicesResponse
import today.cypherpunk.emanator.ui.LocalContainer
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.EmptyState
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.LoadableContent
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.Slug
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.SlugTone
import today.cypherpunk.emanator.ui.components.rememberSnackbar
import today.cypherpunk.emanator.ui.screens.accounts.ConfirmDialog
import today.cypherpunk.emanator.ui.screens.accounts.LoadVm
import today.cypherpunk.emanator.ui.screens.accounts.withSnackbar
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Times

/**
 * Phones signed in to the app — the same list as the web's Settings, so a lost
 * phone can be signed out from either side. Signing out this one logs out.
 */
@Composable
fun DevicesScreen(nav: NavHostController) {
    val container = LocalContainer.current
    val scope = rememberCoroutineScope()
    val snackbar = rememberSnackbar()
    val vm = appViewModel("devices") { c -> LoadVm(c.cache, "devices", DevicesResponse.serializer()) { c.api.devices() } }
    val state by vm.state.collectAsState()
    var confirm by remember { mutableStateOf<Device?>(null) }
    LaunchedEffect(Unit) { vm.load() }

    ConsoleScaffold(stringResource(R.string.dev_title), onBack = { nav.popBackStack() }, snackbar = snackbar) { padding ->
        LoadableContent(state, onRefresh = vm::load, modifier = Modifier.padding(padding)) { data ->
            LazyColumn(Modifier.fillMaxSize()) {
                item {
                    Text(stringResource(R.string.dev_intro), style = Type.small, color = LocalConsole.current.muted, modifier = Modifier.padding(Gutter))
                    Rule()
                }
                if (data.devices.isEmpty()) item { EmptyState(stringResource(R.string.dev_empty)) }
                items(data.devices, key = { it.id }) { device -> DeviceRow(device) { confirm = device } }
            }
        }
    }

    confirm?.let { device ->
        ConfirmDialog(
            if (device.current) stringResource(R.string.dev_sign_out_this) else stringResource(R.string.dev_sign_out_confirm),
            stringResource(R.string.dev_sign_out),
            onConfirm = {
                scope.launch {
                    if (device.current) {
                        logOut(container)
                    } else if (withSnackbar(snackbar) { container.api.removeDevice(device.id) } != null) {
                        vm.load()
                    }
                }
            },
            onDismiss = { confirm = null },
        )
    }
}

@Composable
private fun DeviceRow(device: Device, onSignOut: () -> Unit) {
    val c = LocalConsole.current
    Row(Modifier.fillMaxWidth().padding(horizontal = Gutter, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(device.name, style = Type.title, color = c.text)
                if (device.current) Slug(stringResource(R.string.dev_this))
            }
            val lastUsed = Times.parse(device.lastUsedAt)
            Text(
                listOfNotNull(
                    if (lastUsed != null) stringResource(R.string.dev_last_used, Times.age(lastUsed)) else stringResource(R.string.dev_never_used),
                    device.clientVersion?.let { stringResource(R.string.dev_version, it) },
                ).joinToString(" · "),
                style = Type.small, color = c.muted,
            )
        }
        SlugButton(stringResource(R.string.dev_sign_out), onSignOut, tone = SlugTone.Short)
    }
    Rule()
}
