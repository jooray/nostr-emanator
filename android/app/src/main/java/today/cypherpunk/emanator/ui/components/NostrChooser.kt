package today.cypherpunk.emanator.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links

/**
 * Which app opens a note or profile: every installed Nostr app, then the
 * user's event viewer on the web. Raised by [Links.openNostr] from anywhere,
 * so it lives once at the root.
 */
@Composable
fun NostrChooser() {
    val choice by Links.nostrChoice.collectAsState()
    val pending = choice ?: return
    val context = LocalContext.current
    val c = LocalConsole.current
    val dismiss = { Links.nostrChoice.value = null }

    AlertDialog(
        onDismissRequest = dismiss,
        containerColor = c.panel,
        title = { Text(stringResource(R.string.nostr_open_with).uppercase(), style = Type.label, color = c.legend) },
        text = {
            Column {
                @Composable
                fun Option(label: String, onClick: () -> Unit) {
                    Text(
                        label, style = Type.body, color = c.text,
                        modifier = Modifier.fillMaxWidth().clickable { dismiss(); onClick() }.padding(vertical = 12.dp),
                    )
                }
                pending.apps.forEach { app ->
                    Option(stringResource(R.string.nostr_open_in_app, app.label)) { Links.openInApp(context, pending.uri, app.packageName) }
                }
                pending.webUrl?.let { url ->
                    val host = android.net.Uri.parse(url).host?.removePrefix("www.") ?: url
                    Option(stringResource(R.string.nostr_open_on_web, host)) { Links.openUrl(context, url) }
                }
            }
        },
        confirmButton = {},
        dismissButton = { SlugButton(stringResource(R.string.action_cancel), dismiss) },
    )
}
