package today.cypherpunk.emanator.ui.screens.posts

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.PostItem
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.SlugTone
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type

/**
 * The action a failed row offers, as on the web's forme row: a repost retries
 * through its own signing path; a post republishes its signed event when it has
 * one, otherwise asks the signer again. Returns the server's message.
 */
suspend fun retryRow(container: AppContainer, item: PostItem): String? {
    val response = if (item.isRepost) {
        container.api.repostAction(item.targetPostId, item.id, "retry_sign")
    } else {
        container.api.postAction(item.id, if (item.can.retryPublish) "retry_publish" else "retry_sign")
    }
    refreshBadges(container)
    return response.message
}

/** Sends the same signed event again (never re-signs). */
suspend fun rebroadcastRow(container: AppContainer, item: PostItem): String? {
    val response = if (item.isRepost) {
        container.api.repostAction(item.targetPostId, item.id, "rebroadcast")
    } else {
        container.api.postAction(item.id, "rebroadcast")
    }
    return response.message
}

/** Keeps the tab badges in step after anything that moves a count. */
suspend fun refreshBadges(container: AppContainer) {
    try {
        container.setMe(container.api.me())
    } catch (_: ApiException) {
    }
}

/** A yes/no question before something that cannot be undone. */
@Composable
fun ConfirmDialog(
    text: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    danger: Boolean = true,
) {
    val c = LocalConsole.current
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = c.panel,
        text = { Text(text, style = Type.bodyDense, color = c.text) },
        confirmButton = {
            SlugButton(confirmLabel, { onDismiss(); onConfirm() }, tone = if (danger) SlugTone.Short else SlugTone.Wait)
        },
        dismissButton = { SlugButton(stringResource(R.string.action_cancel), onDismiss) },
    )
}

/** A horizontally scrolling row of single-choice filter chips. */
@Composable
fun <T> ChipRow(
    options: List<Pair<T, String>>,
    selected: T,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    val c = LocalConsole.current
    Row(
        modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Gutter),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        options.forEach { (value, label) ->
            FilterChip(
                selected = value == selected,
                onClick = { onSelect(value) },
                label = { Text(label.uppercase(), style = Type.slug) },
                colors = FilterChipDefaults.filterChipColors(
                    containerColor = c.chassis,
                    labelColor = c.legend,
                    selectedContainerColor = c.activeFill,
                    selectedLabelColor = c.text,
                ),
                border = FilterChipDefaults.filterChipBorder(
                    enabled = true, selected = value == selected,
                    borderColor = c.rule, selectedBorderColor = c.amber,
                ),
            )
        }
    }
}
