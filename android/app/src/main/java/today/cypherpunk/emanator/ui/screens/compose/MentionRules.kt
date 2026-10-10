package today.cypherpunk.emanator.ui.screens.compose

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue

/**
 * The "@word" being typed right before the cursor, the same rule as the web's
 * mention_controller.js: an @ at the start or after whitespace, then up to 30
 * letters, digits, `_`, `.` or `-`.
 */
object MentionRules {
    data class Token(val query: String, val start: Int, val end: Int)

    private val pattern = Regex("""(?:^|\s)@([\p{L}\p{N}_.\-]{0,30})$""")

    fun token(value: TextFieldValue): Token? {
        if (!value.selection.collapsed) return null
        val cursor = value.selection.start
        val match = pattern.find(value.text.substring(0, cursor)) ?: return null
        val query = match.groupValues[1]
        return Token(query, cursor - query.length - 1, cursor)
    }

    /** Replaces the token with [insert] plus a space (unless one follows), cursor after it. */
    fun apply(value: TextFieldValue, token: Token, insert: String): TextFieldValue {
        val after = value.text.substring(token.end)
        val piece = if (after.startsWith(" ") || after.startsWith("\n")) insert else "$insert "
        val text = value.text.substring(0, token.start) + piece + after
        return TextFieldValue(text, TextRange(token.start + piece.length))
    }
}
