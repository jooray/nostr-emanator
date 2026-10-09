package today.cypherpunk.emanator.media

import org.junit.Assert.assertEquals
import org.junit.Test

class TextInsertTest {
    private val url = "https://blossom.example/abc.jpg"

    @Test fun intoEmptyText() {
        assertEquals(TextInsert.Result(url, url.length), TextInsert.insert("", 0, url))
    }

    @Test fun addsSpacesOnlyWhereNeeded() {
        assertEquals("gm $url", TextInsert.insert("gm", 2, url).text)
        assertEquals("gm $url", TextInsert.insert("gm ", 3, url).text)
        assertEquals("a $url b", TextInsert.insert("ab", 1, url).text)
        assertEquals("a $url b", TextInsert.insert("a b", 2, url).text)
    }

    @Test fun clampsAPositionPastTheEnd() {
        val result = TextInsert.insert("hi", 40, url)
        assertEquals("hi $url", result.text)
        assertEquals(result.text.length, result.caret)
    }

    @Test fun caretMovesPastTheInsertionSoTheNextLandsAfterIt() {
        val first = TextInsert.insert("x", 1, url)
        val second = TextInsert.insert(first.text, first.caret, "u2")
        assertEquals("x $url u2", second.text)
    }
}
