package today.cypherpunk.emanator.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import today.cypherpunk.emanator.data.MediaSettings

// The same cases hold for app/javascript/lib/video_rules.js.
class VideoRulesTest {
    @Test fun onlyPlayableVideoTypesAreReEncoded() {
        val on = MediaSettings()
        assertTrue(VideoRules.shouldShrink("video/mp4", on))
        assertTrue(VideoRules.shouldShrink("video/quicktime", on))
        assertFalse(VideoRules.shouldShrink("image/gif", on))
        assertFalse(VideoRules.shouldShrink("video/mp4", on.copy(videoCompress = false)))
    }

    @Test fun shorterSideIsScaledAndKeptEven() {
        assertEquals(720 to 1280, VideoRules.targetSize(1080, 1920, 720))
        assertEquals(1920 to 1080, VideoRules.targetSize(3840, 2160, 1080))
        assertEquals(640 to 360, VideoRules.targetSize(640, 360, 1080)) // never upscales
        assertEquals(1080 to 1920, VideoRules.targetSize(1080, 1920, 0))
        assertEquals(480 to 854, VideoRules.targetSize(1080, 1920, 480)) // 853.3 → even
    }

    @Test fun frameRateIsCappedAtThirty() {
        assertEquals(30, VideoRules.frameRate(59.94f))
        assertNull(VideoRules.frameRate(30f))
        assertNull(VideoRules.frameRate(0f))
    }

    @Test fun bitrateFollowsPixelsAndNeverExceedsTheSource() {
        assertEquals(2_211_840, VideoRules.bitrate(720, 1280, 60f, "balanced", 16_000_000))
        assertEquals(1_000_000, VideoRules.bitrate(720, 1280, 30f, "high", 1_000_000))
        assertEquals(250_000, VideoRules.bitrate(160, 90, 30f, "small", 0))
        assertEquals(VideoRules.bitrate(720, 1280, 30f, "balanced", 0), VideoRules.bitrate(720, 1280, 30f, "bogus", 0))
    }

    @Test fun outputIsNamedMp4() {
        assertEquals("clip.mp4", VideoRules.rename("clip.MOV"))
        assertEquals("video.mp4", VideoRules.rename(null))
    }

    @Test fun aChoiceIsOfferedOnlyForAClipThatCouldGoUpAsItIs() {
        val on = MediaSettings()
        val limit = 99L * 1024 * 1024
        assertTrue(VideoRules.offerChoice("video/mp4", 40L * 1024 * 1024, on, limit))
        assertTrue(VideoRules.offerChoice("video/mp4", limit, on, limit))
        assertFalse(VideoRules.offerChoice("video/mp4", limit + 1, on, limit))
        assertFalse(VideoRules.offerChoice("video/mp4", 1024, on.copy(videoCompress = false), limit))
        assertFalse(VideoRules.offerChoice("image/jpeg", 1024, on, limit))
    }

    @Test fun smallerKeepsWhicheverCopyIsSmaller() {
        assertTrue(VideoRules.useReencoded(VideoRules.Mode.Smaller, 1000, 999))
        assertFalse(VideoRules.useReencoded(VideoRules.Mode.Smaller, 1000, 1000))
        assertFalse(VideoRules.useReencoded(VideoRules.Mode.Smaller, 1000, 2000))
        assertTrue(VideoRules.useReencoded(VideoRules.Mode.Reencode, 1000, 2000))
        assertFalse(VideoRules.useReencoded(VideoRules.Mode.Original, 1000, 10))
    }
}
