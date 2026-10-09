package today.cypherpunk.emanator.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.ReleaseInfo
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links

/**
 * The server answered 426: this build is older than it supports. Nothing else
 * is reachable — a half-working old build against a newer API is worse than a
 * clear stop with a way out.
 */
@Composable
fun UpdateRequiredScreen(info: ReleaseInfo) {
    val context = LocalContext.current
    val c = LocalConsole.current
    Surface(color = c.chassis, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.safeDrawingPadding().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(stringResource(R.string.update_required_title).uppercase(), style = Type.display, color = c.text)
            Text(stringResource(R.string.update_required_body), style = Type.body, color = c.legend)
            if (info.latestVersionName.isNotBlank()) Text(stringResource(R.string.update_available, info.latestVersionName), style = Type.small, color = c.muted)
            info.downloadUrl?.let { PrimaryButton(stringResource(R.string.update_get), { Links.openUrl(context, it) }, Modifier.fillMaxWidth()) }
            info.zapstoreUrl?.let { SecondaryButton(stringResource(R.string.update_zapstore), { Links.openUrl(context, it) }, Modifier.fillMaxWidth()) }
        }
    }
}
