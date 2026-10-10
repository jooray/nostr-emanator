package today.cypherpunk.emanator.ui.screens.compose

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MentionRulesTest {
    private fun at(text: String, cursor: Int = text.length) = TextFieldValue(text, TextRange(cursor))

    @Test
    fun findsTheWordAfterAnAtSignBeforeTheCursor() {
        assertEquals(MentionRules.Token("nal", 10, 14), MentionRules.token(at("Thanks to @nal")))
        assertEquals(MentionRules.Token("", 0, 1), MentionRules.token(at("@")))
        assertEquals("nal", MentionRules.token(at("Hi @nal and more", 7))?.query)
    }

    @Test
    fun ignoresEmailsSelectionsAndFinishedWords() {
        assertNull(MentionRules.token(at("mail me@example")))
        assertNull(MentionRules.token(at("@nal done")))
        assertNull(MentionRules.token(TextFieldValue("@nal", TextRange(1, 4))))
    }

    @Test
    fun replacesTheTokenAndAddsASpace() {
        val value = at("Thanks to @nal")
        val out = MentionRules.apply(value, MentionRules.token(value)!!, "nostr:npub1x")
        assertEquals("Thanks to nostr:npub1x ", out.text)
        assertEquals(out.text.length, out.selection.start)

        val mid = at("Hi @nal and more", 7)
        assertEquals("Hi nostr:npub1x and more", MentionRules.apply(mid, MentionRules.token(mid)!!, "nostr:npub1x").text)
    }
}
