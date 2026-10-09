package today.cypherpunk.emanator.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.PostItem
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Times

/** What a row is listed as; decides its stamp and the action it offers. */
enum class RowKind { Normal, Waiting, Short, Failed, Sent }

fun rowKindFor(item: PostItem): RowKind = when {
    item.status == "awaiting_signature" || item.status == "pending_signature" -> RowKind.Waiting
    item.status == "failed" -> RowKind.Failed
    item.status == "published" && item.delivery.alarming -> RowKind.Short
    item.status == "published" -> RowKind.Sent
    else -> RowKind.Normal
}

/**
 * One forme on the stone (web: shared/_forme_row). The hour and day, the
 * identity, two lines of copy, and the state with the action that belongs to
 * it: an elapsed counter while waiting, the poll strip once sent, Retry when it
 * never went out.
 */
@Composable
fun PostRow(
    item: PostItem,
    onOpen: (PostItem) -> Unit,
    modifier: Modifier = Modifier,
    kind: RowKind = rowKindFor(item),
    onRetry: ((PostItem) -> Unit)? = null,
    onRebroadcast: ((PostItem) -> Unit)? = null,
) {
    val c = LocalConsole.current
    val stampIso = if (kind == RowKind.Sent || kind == RowKind.Short) item.publishedAt else item.scheduledAt
    val stamp = Times.parse(stampIso)

    Column(
        modifier
            .fillMaxWidth()
            .then(if (kind == RowKind.Waiting) Modifier.background(c.waitFill) else Modifier)
            .clickable { onOpen(item) }
            .padding(horizontal = Gutter, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.width(76.dp)) {
                Text(Times.hour(stamp), style = Type.hour, color = c.text)
                Spacer(Modifier.height(4.dp))
                Text(
                    when {
                        stamp == null -> stringResource(R.string.row_draft)
                        kind == RowKind.Sent || kind == RowKind.Short -> stringResource(R.string.row_sent)
                        Times.isToday(stamp) -> stringResource(R.string.row_today)
                        Times.isTomorrow(stamp) -> stringResource(R.string.row_tomorrow)
                        else -> Times.dayMonth(stamp)
                    }.uppercase(),
                    style = Type.slug,
                    color = c.muted,
                )
            }
            Identity(item.account, Modifier.weight(1f))
        }

        Text(
            item.content.orEmpty().trim(),
            style = Type.bodyDense,
            color = c.legend,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )

        if (item.isRepost) {
            Text(stringResource(R.string.row_repost_of_note).uppercase(), style = Type.slug, color = c.muted)
        } else if (item.repostsCount > 0) {
            Text(pluralStringResource(R.plurals.row_reposts, item.repostsCount, item.repostsCount).uppercase(), style = Type.slug, color = c.muted)
        }
        if (kind == RowKind.Failed) {
            Text(
                item.error ?: item.delivery.results.firstOrNull { it.result != "ok" }?.let { "${it.relay.removePrefix("wss://")} ${it.result}" }
                    ?: stringResource(R.string.row_never_reached),
                style = Type.mono,
                color = c.redText,
            )
        }

        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
            when (kind) {
                RowKind.Waiting -> {
                    ElapsedReadout(item.updatedAt)
                    Spacer(Modifier.width(12.dp))
                    Slug(stringResource(R.string.row_open), SlugTone.Wait) { onOpen(item) }
                }
                RowKind.Short, RowKind.Sent -> {
                    PollStrip(item.delivery, Modifier.weight(1f))
                    if (kind == RowKind.Short && onRebroadcast != null) {
                        SlugButton(stringResource(R.string.row_rebroadcast), { onRebroadcast(item) })
                    }
                }
                RowKind.Failed -> if (onRetry != null) {
                    SlugButton(stringResource(R.string.row_retry), { onRetry(item) }, tone = SlugTone.Short)
                } else {
                    StatusSlug(item.status)
                }
                RowKind.Normal -> StatusSlug(item.status)
            }
        }
    }
    Rule()
}

/** mm:ss since a moment, ticking — how long something has waited on a human. */
@Composable
fun ElapsedReadout(sinceIso: String?) {
    val since = remember(sinceIso) { Times.parse(sinceIso) }
    var text by remember { mutableStateOf(Times.elapsed(since)) }
    LaunchedEffect(since) {
        while (true) {
            text = Times.elapsed(since)
            delay(1000)
        }
    }
    Text(text, style = Type.readout, color = LocalConsole.current.amberText)
}
