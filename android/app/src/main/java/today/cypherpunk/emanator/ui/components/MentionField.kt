package today.cypherpunk.emanator.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.Mention
import today.cypherpunk.emanator.ui.screens.compose.MentionRules
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type

/**
 * The "@word" lookup behind every field that can mention someone — the post
 * composer and the interactions reply box (web: mention_controller.js). It
 * tracks the token under the caret, asks Mentions::Search after a short pause,
 * and knows how to put the picked `nostr:npub…` in its place.
 */
class MentionLookup(
    private val scope: CoroutineScope,
    private val search: suspend (String) -> List<Mention>,
) {
    val suggestions = MutableStateFlow<List<Mention>>(emptyList())
    private var token: MentionRules.Token? = null
    private var job: Job? = null

    fun onTextChange(value: TextFieldValue) {
        val next = MentionRules.token(value)
        if (next == token) return
        token = next
        job?.cancel()
        if (next == null) {
            suggestions.value = emptyList()
            return
        }
        job = scope.launch {
            delay(150)
            val found = search(next.query)
            if (token == next) suggestions.value = found
        }
    }

    /** The text with [mention] in place of the token; null when there is nothing to replace. */
    fun pick(value: TextFieldValue, mention: Mention): TextFieldValue? {
        val current = token ?: return null
        job?.cancel()
        token = null
        suggestions.value = emptyList()
        return MentionRules.apply(value, current, mention.mention)
    }

    fun dismiss() {
        job?.cancel()
        token = null
        suggestions.value = emptyList()
    }
}

/** OutlinedTextField's inner padding: [caret] is relative to the text, not the field. */
private val FieldPadding = 16.dp
private val SuggestionRow = 53.dp

/**
 * Who "@word" could mean: your own accounts first, then people they follow.
 * Shown under the caret's line, or above it when there is more room there
 * (the keyboard takes the bottom half), never stealing focus from the field.
 *
 * [bounds] is the field's box from `onGloballyPositioned`, [textStyle] the
 * style it draws with; everything else belongs to the caller's lookup.
 */
@Composable
fun MentionPopup(
    mentions: List<Mention>,
    text: TextFieldValue,
    bounds: Rect?,
    textStyle: TextStyle = Type.body,
    onPick: (Mention) -> Unit,
    onDismiss: () -> Unit,
) {
    if (mentions.isEmpty() || bounds == null) return
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    // Same text, style and width as inside the field, to find the caret's line.
    val inner = (bounds.width - 2 * with(density) { FieldPadding.toPx() }).roundToInt().coerceAtLeast(1)
    val layout = measurer.measure(text.text, textStyle, constraints = Constraints(maxWidth = inner))
    val caret = layout.getCursorRect(text.selection.start.coerceIn(0, text.text.length))
    Suggestions(mentions, caret, bounds, onPick, onDismiss)
}

@Composable
private fun Suggestions(
    mentions: List<Mention>,
    caret: Rect,
    field: Rect,
    onPick: (Mention) -> Unit,
    onDismiss: () -> Unit,
) {
    val density = LocalDensity.current
    val view = LocalView.current
    val pad = with(density) { FieldPadding.toPx() }
    val gap = with(density) { 4.dp.toPx() }
    val caretTop = field.top + pad + caret.top
    val caretBottom = field.top + pad + caret.bottom
    val bottomEdge = view.rootView.height - maxOf(WindowInsets.ime.getBottom(density), WindowInsets.navigationBars.getBottom(density))
    val topEdge = WindowInsets.statusBars.getTop(density).toFloat()
    val roomBelow = bottomEdge - caretBottom - gap
    val roomAbove = caretTop - topEdge - gap
    val wanted = with(density) { (SuggestionRow * mentions.size.coerceAtMost(4)).toPx() }
    val below = roomBelow >= wanted || roomBelow >= roomAbove
    val maxHeight = with(density) { (if (below) roomBelow else roomAbove).coerceAtLeast(0f).toDp() }
    val provider = remember(below, caretTop, caretBottom, field.left) {
        object : PopupPositionProvider {
            override fun calculatePosition(
                anchorBounds: IntRect, windowSize: IntSize, layoutDirection: LayoutDirection, popupContentSize: IntSize,
            ): IntOffset {
                val y = if (below) caretBottom + gap else caretTop - gap - popupContentSize.height
                return IntOffset(field.left.roundToInt(), y.roundToInt())
            }
        }
    }
    Popup(popupPositionProvider = provider, onDismissRequest = onDismiss, properties = PopupProperties(focusable = false)) {
        MentionList(mentions, Modifier.width(with(density) { field.width.toDp() }).heightIn(max = maxHeight), onPick)
    }
}

@Composable
private fun MentionList(mentions: List<Mention>, modifier: Modifier, onPick: (Mention) -> Unit) {
    val c = LocalConsole.current
    Column(modifier.border(1.dp, c.rule).background(c.panel).verticalScroll(rememberScrollState())) {
        mentions.forEachIndexed { index, m ->
            if (index > 0) Rule()
            Row(
                Modifier.fillMaxWidth().clickable { onPick(m) }.padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Avatar(m.pictureUrl, m.label, 32.dp)
                Column(Modifier.weight(1f)) {
                    Text(m.label, style = Type.bodyDense, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    val sub = when {
                        m.own -> stringResource(R.string.compose_mention_own)
                        !m.nip05.isNullOrBlank() -> m.nip05
                        !m.name.isNullOrBlank() -> "@${m.name}"
                        else -> m.npub.take(20) + "…"
                    }
                    Text(sub, style = Type.small, color = c.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}
