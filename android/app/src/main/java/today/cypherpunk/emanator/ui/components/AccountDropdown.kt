package today.cypherpunk.emanator.ui.components

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.AccountMini
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type

/**
 * The single-choice sender picker shared by New post and New message: a boxed
 * field that opens a vertical, scrollable list. Scales to any number of
 * identities, unlike a row of pills.
 */
@Composable
fun AccountDropdown(
    label: String,
    accounts: List<AccountMini>,
    selectedId: Long?,
    onSelect: (Long) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val c = LocalConsole.current
    var open by remember { mutableStateOf(false) }
    val selected = accounts.firstOrNull { it.id == selectedId }
    val interactive = enabled && accounts.size > 1
    Box(modifier) {
        Row(
            Modifier.fillMaxWidth().border(1.dp, c.rule)
                .then(if (interactive) Modifier.clickable { open = true } else Modifier)
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Chop(selected, 28.dp)
            Column(Modifier.weight(1f)) {
                Text(label.uppercase(), style = Type.slug, color = c.muted)
                Text(selected?.name ?: stringResource(R.string.compose_choose_account), style = Type.bodyDense, color = c.text, maxLines = 1)
            }
            if (interactive) Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = c.legend)
        }
        DropdownMenu(open, onDismissRequest = { open = false }) {
            accounts.forEach { account ->
                DropdownMenuItem(
                    text = { Text(account.name, style = Type.bodyDense) },
                    leadingIcon = { Chop(account, 24.dp) },
                    onClick = { onSelect(account.id); open = false },
                )
            }
        }
    }
}
