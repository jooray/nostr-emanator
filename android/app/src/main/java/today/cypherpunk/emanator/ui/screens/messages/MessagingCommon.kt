package today.cypherpunk.emanator.ui.screens.messages

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.graphics.toColorInt
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.AccountMini
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type

/** Refreshes the badge counts after something was read, so the tab badge moves. */
suspend fun refreshBadges(container: AppContainer) {
    val summary = runCatching { container.api.summary() }.getOrNull() ?: return
    container.me.value?.let { container.setMe(it.copy(summary = summary)) }
}

/** A yes/no question before something that cannot be undone from here. */
@Composable
fun ConfirmDialog(
    text: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    body: (@Composable () -> Unit)? = null,
) {
    val c = LocalConsole.current
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = c.panel,
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(text, style = Type.bodyDense, color = c.text)
                body?.invoke()
            }
        },
        confirmButton = {
            TextButton(onClick = { onDismiss(); onConfirm() }) {
                Text(confirmLabel.uppercase(), style = Type.label, color = c.amberText)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.action_cancel).uppercase(), style = Type.label, color = c.legend)
            }
        },
    )
}

/** The legacy (NIP-04) downgrade risks, as the web lists them. */
@Composable
fun RiskList(risks: List<String>) {
    val c = LocalConsole.current
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        risks.forEach { risk -> Text("• $risk", style = Type.small, color = c.redText) }
    }
}

/**
 * Account pills: each identity with its wire ink. An empty selection means
 * every account — rendered all-on, like the web, never all-off.
 */
@Composable
fun AccountPills(
    accounts: List<AccountMini>,
    selected: Set<Long>,
    onToggle: (Long) -> Unit,
    modifier: Modifier = Modifier,
    allWhenEmpty: Boolean = true,
) {
    val c = LocalConsole.current
    val showingAll = allWhenEmpty && selected.isEmpty()
    Row(
        modifier.horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        accounts.forEach { account ->
            val active = showingAll || account.id in selected
            Row(
                Modifier
                    .border(1.dp, if (active) c.text else c.rule)
                    .clickable { onToggle(account.id) }
                    .alpha(if (active) 1f else 0.55f)
                    .padding(horizontal = 10.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(Modifier.width(3.dp).height(12.dp).background(inkOf(account)))
                Text(account.name.uppercase(), style = Type.label, color = if (active) c.text else c.muted, maxLines = 1)
            }
        }
    }
}

fun inkOf(account: AccountMini): Color =
    runCatching { Color(account.ink.toColorInt()) }.getOrDefault(Palette.neutral500)

/**
 * Toggling one pill out of "every account" means "every account but this one";
 * selecting all by hand collapses back to empty (= all), matching the server.
 */
fun toggleAccount(selected: Set<Long>, all: List<Long>, id: Long): Set<Long> {
    val current = if (selected.isEmpty()) all.toSet() else selected
    val next = if (id in current) current - id else current + id
    return if (next.isEmpty() || next.containsAll(all)) emptySet() else next
}
