package today.cypherpunk.emanator.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import today.cypherpunk.emanator.data.Reference
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links

private val UrlPattern = Regex("""https?://[^\s<>"']+""")
private val ImagePattern = Regex("""\.(jpe?g|png|gif|webp|avif)(\?.*)?$""", RegexOption.IGNORE_CASE)
private val VideoPattern = Regex("""\.(mp4|webm|mov)(\?.*)?$""", RegexOption.IGNORE_CASE)

fun imageUrls(content: String?): List<String> =
    content?.let { UrlPattern.findAll(it).map { m -> m.value.trimEnd('.', ',', ')') }.filter { u -> ImagePattern.containsMatchIn(u) }.distinct().toList() }
        ?: emptyList()

/**
 * Post or message text, as the web renders it: `nostr:` references replaced by
 * the names the server resolved (tap = open in a Nostr app), links tappable,
 * quoted notes shown inline, and image links previewed as thumbnails.
 */
@Composable
fun RichContent(
    content: String?,
    references: List<Reference> = emptyList(),
    modifier: Modifier = Modifier,
    style: TextStyle = Type.body,
    maxLines: Int = Int.MAX_VALUE,
    showMedia: Boolean = true,
) {
    val context = LocalContext.current
    val c = LocalConsole.current
    val text = content.orEmpty()
    val linkStyle = TextLinkStyles(SpanStyle(color = c.amberText, fontWeight = FontWeight.Medium))

    val annotated: AnnotatedString = remember(text, references, c) {
        buildAnnotatedString {
            data class Span(val start: Int, val end: Int, val label: String, val onClick: () -> Unit)
            val spans = mutableListOf<Span>()
            references.forEach { ref ->
                var index = text.indexOf(ref.match)
                while (index >= 0) {
                    spans += Span(index, index + ref.match.length, ref.label) {
                        Links.openNostr(context, ref.identifier, ref.url)
                    }
                    index = text.indexOf(ref.match, index + ref.match.length)
                }
            }
            UrlPattern.findAll(text).forEach { m ->
                val url = m.value.trimEnd('.', ',', ')')
                val end = m.range.first + url.length
                if (spans.none { it.start < end && m.range.first < it.end }) {
                    spans += Span(m.range.first, end, url) { Links.openUrl(context, url) }
                }
            }
            var cursor = 0
            spans.sortedBy { it.start }.forEach { span ->
                if (span.start < cursor) return@forEach
                append(text.substring(cursor, span.start))
                withLink(LinkAnnotation.Clickable(span.label, linkStyle) { span.onClick() }) { append(span.label) }
                cursor = span.end
            }
            append(text.substring(cursor))
        }
    }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(annotated, style = style, color = c.text, maxLines = maxLines, overflow = TextOverflow.Ellipsis)

        if (showMedia) {
            references.filter { it.quote != null }.forEach { ref ->
                QuoteCard(ref.quote!!.author, ref.quote.content) { Links.openNostr(context, ref.identifier, ref.url) }
            }
            val images = remember(text) { imageUrls(text) }
            if (images.isNotEmpty()) MediaStrip(images)
        }
    }
}

@Composable
fun MediaStrip(urls: List<String>, onRemove: ((String) -> Unit)? = null) {
    val context = LocalContext.current
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        urls.forEach { url ->
            AsyncImage(
                url, contentDescription = null, contentScale = ContentScale.Crop,
                modifier = Modifier.size(96.dp).border(1.dp, LocalConsole.current.rule).clickable { Links.openUrl(context, url) },
            )
        }
    }
}

@Composable
fun QuoteCard(author: String?, content: String, onClick: () -> Unit) {
    val c = LocalConsole.current
    Column(
        Modifier.fillMaxWidth().background(c.panel).border(1.dp, c.rule).clickable(onClick = onClick).padding(10.dp),
    ) {
        author?.let { Text(it.uppercase(), style = Type.slug, color = c.amberText) }
        Text(content, style = Type.small, color = c.legend, maxLines = 5, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 4.dp))
    }
}

fun isVideoUrl(url: String) = VideoPattern.containsMatchIn(url)
