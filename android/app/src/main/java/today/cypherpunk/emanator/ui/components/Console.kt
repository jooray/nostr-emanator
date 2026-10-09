package today.cypherpunk.emanator.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.AccountMini
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.Delivery
import today.cypherpunk.emanator.data.Loadable
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type

// The console's vocabulary (DESIGN.md / ConsoleHelper on the web): lamps,
// slugs, the poll strip, the identity chop. Nominal does not illuminate.

enum class LampState { Off, On, Wait, Alarm }

@Composable
fun Lamp(state: LampState, modifier: Modifier = Modifier) {
    val c = LocalConsole.current
    val color = when (state) {
        LampState.Off -> c.well
        LampState.On -> c.lampLit
        LampState.Wait -> c.amber
        LampState.Alarm -> c.red
    }
    Box(modifier.size(9.dp).clip(RoundedCornerShape(2.dp)).background(color))
}

/** Engraved legend: a section heading in condensed caps. */
@Composable
fun Legend(text: String, modifier: Modifier = Modifier, color: Color = LocalConsole.current.legend, trailing: (@Composable RowScope.() -> Unit)? = null) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(text.uppercase(), style = Type.label, color = color, modifier = Modifier.weight(1f))
        trailing?.invoke(this)
    }
}

@Composable
fun Rule(modifier: Modifier = Modifier) = HorizontalDivider(modifier, thickness = 1.dp, color = LocalConsole.current.rule)

enum class SlugTone { Plain, Wait, Short }

@Composable
fun Slug(text: String, tone: SlugTone = SlugTone.Plain, modifier: Modifier = Modifier, onClick: (() -> Unit)? = null) {
    val c = LocalConsole.current
    val (fill, ink) = when (tone) {
        SlugTone.Plain -> Color.Transparent to c.muted
        SlugTone.Wait -> c.waitFill to (if (c.dark) Palette.amber else Palette.amberDeep)
        SlugTone.Short -> c.alarmFill to (if (c.dark) Palette.redLift else Palette.redDeep)
    }
    Text(
        text.uppercase(),
        style = Type.slug,
        color = ink,
        maxLines = 1,
        modifier = modifier
            .background(fill)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 8.dp, vertical = 6.dp),
    )
}

@Composable
fun statusLabel(status: String): String = when (status) {
    "draft" -> stringResource(R.string.status_draft)
    "pending" -> stringResource(R.string.status_pending)
    "pending_signature" -> stringResource(R.string.status_pending_signature)
    "awaiting_signature" -> stringResource(R.string.status_awaiting_signature)
    "processing" -> stringResource(R.string.status_processing)
    "scheduled" -> stringResource(R.string.status_scheduled)
    "publishing" -> stringResource(R.string.status_publishing)
    "published" -> stringResource(R.string.status_published)
    "failed" -> stringResource(R.string.status_failed)
    else -> status
}

/** A status as a slug, toned by what it asks of the operator. */
@Composable
fun StatusSlug(status: String, modifier: Modifier = Modifier) {
    val tone = when (status) {
        "awaiting_signature", "pending_signature" -> SlugTone.Wait
        "failed" -> SlugTone.Short
        else -> SlugTone.Plain
    }
    Slug(statusLabel(status), tone, modifier)
}

/**
 * Delivery as a poll of N stations: one cell per relay, filled when it took
 * the event, red only when the delivery as a whole is alarming.
 */
@Composable
fun PollStrip(delivery: Delivery, modifier: Modifier = Modifier) {
    if (delivery.total == 0) return
    val c = LocalConsole.current
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            val cells = if (delivery.results.isNotEmpty()) delivery.results.map { it.result == "ok" }
            else List(delivery.total) { it < delivery.ok }
            cells.forEach { ok ->
                val color = when {
                    ok -> c.lampLit
                    delivery.alarming -> c.red
                    else -> c.well
                }
                Box(Modifier.width(9.dp).height(13.dp).background(color))
            }
        }
        Text(delivery.tally ?: "${delivery.ok}/${delivery.total}", style = Type.readout, color = if (delivery.alarming) c.redText else c.legend)
    }
}

/**
 * An identity's mark: its picture, or its letter struck in its wire ink. The
 * ink is derived from the pubkey on the server, so it matches every other
 * surface.
 */
@Composable
fun Chop(account: AccountMini?, size: Dp = 28.dp, modifier: Modifier = Modifier) {
    val ink = account?.ink?.let { runCatching { Color(android.graphics.Color.parseColor(it)) }.getOrNull() } ?: Palette.neutral500
    Avatar(account?.pictureUrl, account?.chop ?: "?", size, modifier, ink)
}

@Composable
fun Avatar(url: String?, letter: String, size: Dp = 36.dp, modifier: Modifier = Modifier, ink: Color = Palette.neutral500) {
    Box(
        modifier.size(size).clip(CircleShape).background(ink),
        contentAlignment = Alignment.Center,
    ) {
        Text(letter.take(1).uppercase(), style = Type.label.copy(fontSize = (size.value * 0.42f).sp), color = Palette.paperWhite)
        if (!url.isNullOrBlank()) {
            AsyncImage(url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
    }
}

/** Identity inline: chop + name. */
@Composable
fun Identity(account: AccountMini?, modifier: Modifier = Modifier, size: Dp = 22.dp) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Chop(account, size)
        Text(
            account?.name ?: "",
            style = Type.label,
            color = LocalConsole.current.legend,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** The one invitation on a screen. */
@Composable
fun PrimaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, busy: Boolean = false) {
    Button(
        onClick = onClick,
        enabled = enabled && !busy,
        modifier = modifier.height(48.dp),
        shape = RoundedCornerShape(0.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Palette.amber, contentColor = Palette.contactBlack,
            disabledContainerColor = LocalConsole.current.well, disabledContentColor = LocalConsole.current.muted),
        contentPadding = PaddingValues(horizontal = 18.dp),
    ) {
        if (busy) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = Palette.contactBlack)
            Spacer(Modifier.width(10.dp))
        }
        Text(text.uppercase(), style = Type.label.copy(fontWeight = FontWeight.Bold))
    }
}

/** A secondary control: outlined, engraved. */
@Composable
fun SecondaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, danger: Boolean = false) {
    val c = LocalConsole.current
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.height(44.dp),
        shape = RoundedCornerShape(0.dp),
        border = BorderStroke(1.dp, c.rule),
        contentPadding = PaddingValues(horizontal = 14.dp),
    ) {
        Text(text.uppercase(), style = Type.label, color = if (danger) c.redText else c.text)
    }
}

/** A quiet text-only control, like the web's `slug` buttons. */
@Composable
fun SlugButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, tone: SlugTone = SlugTone.Plain, enabled: Boolean = true) {
    val c = LocalConsole.current
    TextButton(onClick = onClick, enabled = enabled, modifier = modifier, shape = RoundedCornerShape(0.dp),
        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp)) {
        Text(
            text.uppercase(),
            style = Type.slug,
            color = when (tone) {
                SlugTone.Plain -> c.legend
                SlugTone.Wait -> c.amberText
                SlugTone.Short -> c.redText
            },
        )
    }
}

/** An alarm: something did not land. */
@Composable
fun AlarmBlock(text: String, modifier: Modifier = Modifier, action: (@Composable () -> Unit)? = null) {
    val c = LocalConsole.current
    Row(
        modifier.fillMaxWidth().background(c.alarmFill).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Lamp(LampState.Alarm)
        Text(text, style = Type.small, color = c.redText, modifier = Modifier.weight(1f))
        action?.invoke()
    }
}

/** Something waits on the operator. */
@Composable
fun WaitBlock(text: String, modifier: Modifier = Modifier, action: (@Composable () -> Unit)? = null) {
    val c = LocalConsole.current
    Row(
        modifier.fillMaxWidth().background(c.waitFill).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Lamp(LampState.Wait)
        Text(text, style = Type.small, color = c.text, modifier = Modifier.weight(1f))
        action?.invoke()
    }
}

/** Neutral information. */
@Composable
fun NoteBlock(text: String, modifier: Modifier = Modifier) {
    val c = LocalConsole.current
    Text(
        text,
        style = Type.small,
        color = c.legend,
        modifier = modifier.fillMaxWidth().border(1.dp, c.rule).padding(horizontal = 14.dp, vertical = 10.dp),
    )
}

@Composable
fun EmptyState(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = Type.bodyDense,
        color = LocalConsole.current.muted,
        textAlign = TextAlign.Center,
        modifier = modifier.fillMaxWidth().padding(vertical = 40.dp, horizontal = 24.dp),
    )
}

/** A labelled read-only value, like a settings readout. */
@Composable
fun Readout(label: String, value: String, modifier: Modifier = Modifier, mono: Boolean = false) {
    Column(modifier.padding(vertical = 6.dp)) {
        Text(label.uppercase(), style = Type.slug, color = LocalConsole.current.muted)
        Spacer(Modifier.height(4.dp))
        Text(value, style = if (mono) Type.mono else Type.bodyDense, color = LocalConsole.current.text)
    }
}

/** The page frame: engraved title, back arrow, actions, snackbars. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConsoleScaffold(
    title: String,
    onBack: (() -> Unit)? = null,
    snackbar: SnackbarHostState? = null,
    actions: @Composable RowScope.() -> Unit = {},
    floating: @Composable () -> Unit = {},
    bottomBar: @Composable () -> Unit = {},
    content: @Composable (PaddingValues) -> Unit,
) {
    val c = LocalConsole.current
    Scaffold(
        containerColor = c.chassis,
        topBar = {
            Column {
                TopAppBar(
                    title = { Text(title.uppercase(), style = Type.headline, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    navigationIcon = {
                        if (onBack != null) {
                            IconButton(onClick = onBack) {
                                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back), tint = c.text)
                            }
                        }
                    },
                    actions = actions,
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = c.chassis, scrolledContainerColor = c.chassis),
                )
                Rule()
            }
        },
        snackbarHost = { snackbar?.let { SnackbarHost(it) } },
        floatingActionButton = floating,
        bottomBar = bottomBar,
        content = content,
    )
}

/**
 * Shows a [Loadable]: a thin progress line while refreshing, the saved copy
 * with a quiet notice when the refresh failed, pull-to-refresh, and a retry
 * when there is nothing at all to show.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun <T> LoadableContent(
    state: Loadable<T>,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.(T) -> Unit,
) {
    PullToRefreshBox(isRefreshing = state.loading && state.data != null, onRefresh = onRefresh, modifier = modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            if (state.loading) LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp), color = Palette.amber, trackColor = Color.Transparent)
            val data = state.data
            when {
                data != null -> {
                    state.error?.let { if (!it.isUnauthorized) SavedCopyNotice(it) }
                    content(data)
                }
                state.error != null -> ErrorState(state.error, onRefresh)
                else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = Palette.amber, strokeWidth = 2.dp)
                }
            }
        }
    }
}

@Composable
fun SavedCopyNotice(error: ApiException) {
    NoteBlock(stringResource(R.string.state_saved_copy, error.message), Modifier.padding(16.dp))
}

@Composable
fun ErrorState(error: ApiException, onRetry: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        AlarmBlock(error.message)
        SecondaryButton(stringResource(R.string.action_retry), onRetry)
    }
}

/** Remembered per-screen snackbar host. */
@Composable
fun rememberSnackbar() = remember { SnackbarHostState() }

/** Horizontal page padding used by every screen (16dp gutter, like the web). */
val Gutter = 16.dp

@Composable
fun SectionGap() = Spacer(Modifier.height(24.dp))

@Composable
fun clickableRow(onClick: () -> Unit): Modifier = Modifier.fillMaxWidth().clickable(onClick = onClick)
