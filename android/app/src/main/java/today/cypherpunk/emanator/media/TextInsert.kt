package today.cypherpunk.emanator.media

/**
 * Inserts an uploaded file's URL at a remembered caret position, adding a
 * separating space only where the neighbour is not already whitespace — the
 * same as insertAtCursor in the web's blossom_upload_controller.js.
 *
 * Returns the new text and the caret after the insertion. The position is
 * clamped, since the text may have been shortened while the upload ran.
 */
object TextInsert {
    data class Result(val text: String, val caret: Int)

    fun insert(text: String, position: Int, url: String): Result {
        val start = position.coerceIn(0, text.length)
        val before = text.substring(0, start)
        val after = text.substring(start)
        val lead = if (before.isNotEmpty() && !before.last().isWhitespace()) " " else ""
        val trail = if (after.isNotEmpty() && !after.first().isWhitespace()) " " else ""
        val insertion = lead + url + trail
        return Result(before + insertion + after, start + insertion.length)
    }
}
