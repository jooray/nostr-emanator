package today.cypherpunk.emanator.media

import android.media.MediaMetadataRetriever
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import today.cypherpunk.emanator.data.MediaSettings
import java.io.File

/**
 * Re-encodes a real clip on the device. Push one first:
 *   adb push sample.mp4 /data/local/tmp/emanator-sample.mp4
 * The result is left in the app's cache (uploads/) for inspection.
 */
@RunWith(AndroidJUnit4::class)
class VideoShrinkerTest {
    @Test fun reEncodesToH264AtTheTargetSize(): Unit = runBlocking {
        val sample = File("/data/local/tmp/emanator-sample.mp4")
        assumeTrue("no sample pushed", sample.canRead())
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val input = File(context.cacheDir, "sample-in.mp4").also { sample.copyTo(it, overwrite = true) }

        var lastProgress = -1
        val out = VideoShrinker(context).shrink(input, "sample.mp4", MediaSettings(videoResolution = 720)) { lastProgress = it }
        assertNotNull("not re-encoded", out)
        out!!
        File(context.cacheDir, "uploads/latest.mp4").also { out.file.copyTo(it, overwrite = true) }

        val r = MediaMetadataRetriever().apply { setDataSource(out.file.path) }
        val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)!!.toInt()
        val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)!!.toInt()
        val rotation = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0
        val location = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION)
        r.release()
        val upright = if (rotation == 90 || rotation == 270) h to w else w to h
        assertEquals(720, minOf(upright.first, upright.second))
        assertEquals("location survived: $location", null, location)
        assertTrue("got bigger: ${out.bytes} vs ${input.length()}", out.bytes < input.length())
        assertEquals("sample.mp4", out.name)
        android.util.Log.i("VideoShrinkerTest", "in=${input.length()} out=${out.bytes} ${upright} progress=$lastProgress")
    }
}
