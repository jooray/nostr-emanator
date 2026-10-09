package today.cypherpunk.emanator.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import today.cypherpunk.emanator.data.MediaSettings
import today.cypherpunk.emanator.media.ShrinkRules.Mode

// The same rules as app/javascript/lib/media_compress.js; a photo must come out
// the same from the web and the app.
class ShrinkRulesTest {
    private val defaults = MediaSettings()

    @Test fun photosAreReencodedLossy() {
        assertEquals(Mode.Lossy, ShrinkRules.mode("image/jpeg", defaults))
        assertEquals(Mode.Lossy, ShrinkRules.mode("image/webp", defaults))
        assertEquals(Mode.Lossy, ShrinkRules.mode("IMAGE/JPEG; charset=binary", defaults))
        assertEquals("image/jpeg", ShrinkRules.outputMime(Mode.Lossy, defaults))
        assertEquals("image/webp", ShrinkRules.outputMime(Mode.Lossy, defaults.copy(photoFormat = "webp")))
    }

    @Test fun pngStaysLosslessPng() {
        assertEquals(Mode.Lossless, ShrinkRules.mode("image/png", defaults))
        assertEquals("image/png", ShrinkRules.outputMime(Mode.Lossless, defaults.copy(photoFormat = "webp")))
    }

    @Test fun animatedAndNonImagesAreNeverTouched() {
        listOf("image/gif", "image/svg+xml", "video/mp4", "audio/mpeg", "application/pdf", "", null).forEach {
            assertEquals(it.toString(), Mode.Untouched, ShrinkRules.mode(it, defaults))
        }
        assertNull(ShrinkRules.outputMime(Mode.Untouched, defaults))
    }

    @Test fun compressOffUploadsAsIs() {
        assertEquals(Mode.Untouched, ShrinkRules.mode("image/jpeg", defaults.copy(compress = false)))
    }

    @Test fun heicNeedsImageDecoder() {
        assertEquals(Mode.Lossy, ShrinkRules.mode("image/heic", defaults, sdk = 28))
        assertEquals(Mode.Untouched, ShrinkRules.mode("image/heic", defaults, sdk = 27))
    }

    @Test fun longestSideIsCappedWithoutUpscaling() {
        assertEquals(2048 to 1536, ShrinkRules.targetSize(4032, 3024, 2048))
        assertEquals(1536 to 2048, ShrinkRules.targetSize(3024, 4032, 2048))
        assertEquals(800 to 600, ShrinkRules.targetSize(800, 600, 2048))
        assertEquals(4032 to 3024, ShrinkRules.targetSize(4032, 3024, 0))
        assertEquals(1 to 2048, ShrinkRules.targetSize(1, 9000, 2048))
    }

    @Test fun onlyAnUnresizedLargerPngKeepsItsOriginal() {
        assertTrue(ShrinkRules.keepOriginal(Mode.Lossless, scaled = false, encodedBytes = 120, originalBytes = 100))
        assertFalse(ShrinkRules.keepOriginal(Mode.Lossless, scaled = true, encodedBytes = 120, originalBytes = 100))
        assertFalse(ShrinkRules.keepOriginal(Mode.Lossless, scaled = false, encodedBytes = 80, originalBytes = 100))
        // A JPEG's metadata is the reason to re-encode, even when it grows.
        assertFalse(ShrinkRules.keepOriginal(Mode.Lossy, scaled = false, encodedBytes = 120, originalBytes = 100))
    }

    @Test fun renamesToTheNewFormat() {
        assertEquals("IMG_1234.jpg", ShrinkRules.rename("IMG_1234.HEIC", "image/jpeg"))
        assertEquals("shot.webp", ShrinkRules.rename("shot.png", "image/webp"))
        assertEquals("image.png", ShrinkRules.rename(null, "image/png"))
        assertEquals("noext.jpg", ShrinkRules.rename("noext", "image/jpeg"))
    }

    @Test fun humanSizeMatchesTheWeb() {
        assertEquals("512 B", ShrinkRules.humanSize(512))
        assertEquals("380 KB", ShrinkRules.humanSize(380L * 1024))
        assertEquals("4.2 MB", ShrinkRules.humanSize((4.2 * 1024 * 1024).toLong()))
    }
}
