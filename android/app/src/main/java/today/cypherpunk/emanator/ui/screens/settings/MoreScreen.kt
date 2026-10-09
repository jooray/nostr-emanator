package today.cypherpunk.emanator.ui.screens.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import today.cypherpunk.emanator.BuildConfig
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.ui.LocalContainer
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.components.Avatar
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.screens.accounts.NavRow
import today.cypherpunk.emanator.ui.screens.accounts.shortNpub
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type

/** The fifth tab: everything the bottom bar has no room for. */
@Composable
fun MoreScreen(nav: NavHostController) {
    val container = LocalContainer.current
    val me by container.me.collectAsState()
    val c = LocalConsole.current

    ConsoleScaffold(stringResource(R.string.nav_more)) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())) {
            me?.user?.let { user ->
                Row(
                    Modifier.fillMaxWidth().padding(Gutter),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Avatar(user.pictureUrl, user.name, 48.dp)
                    Column {
                        Text(user.name, style = Type.title, color = c.text)
                        Text(shortNpub(user.npub), style = Type.mono, color = c.muted)
                    }
                }
                Rule()
            }
            NavRow(stringResource(R.string.nav_new_post), { nav.navigate(Routes.compose()) })
            NavRow(stringResource(R.string.nav_accounts), { nav.navigate(Routes.ACCOUNTS) })
            NavRow(stringResource(R.string.nav_interactions), { nav.navigate(Routes.INTERACTIONS) })
            NavRow(stringResource(R.string.nav_settings), { nav.navigate(Routes.SETTINGS) })
            if (me?.billingEnabled == true) NavRow(stringResource(R.string.nav_billing), { nav.navigate(Routes.BILLING) })

            Text(
                stringResource(R.string.set_version, BuildConfig.VERSION_NAME, container.prefs.serverUrl.removePrefix("https://")),
                style = Type.mono, color = c.muted, modifier = Modifier.padding(Gutter),
            )
        }
    }
}
