package today.cypherpunk.emanator.media

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.coroutineScope
import today.cypherpunk.emanator.data.MediaSettings
import java.io.File
import java.util.UUID
import kotlin.coroutines.resume

/**
 * Re-encodes a video on the phone before upload (Media3 Transformer, using the
 * hardware encoder). The rules are in [VideoRules], shared with the web.
 * Returns null when the clip cannot be re-encoded here; the caller then
 * uploads the original.
 */
@OptIn(UnstableApi::class)
class VideoShrinker(private val context: Context) {
    private val dir = File(context.cacheDir, "uploads").apply { mkdirs() }

    private data class Source(val width: Int, val height: Int, val fps: Float, val bitrate: Int)

    suspend fun shrink(input: File, name: String, settings: MediaSettings, onProgress: (Int) -> Unit): PreparedFile? {
        val source = withContext(Dispatchers.IO) { probe(input) } ?: return null
        val (width, height) = VideoRules.targetSize(source.width, source.height, settings.videoResolution)
        val bitrate = VideoRules.bitrate(width, height, source.fps, settings.videoQuality, source.bitrate)
        val outName = VideoRules.rename(name)
        val out = File(dir, "${UUID.randomUUID()}-${ShrinkRules.safeFileName(outName)}")

        val videoEffects = buildList {
            add(Presentation.createForWidthAndHeight(width, height, Presentation.LAYOUT_SCALE_TO_FIT))
            VideoRules.frameRate(source.fps)?.let { add(FrameDropEffect.createDefaultFrameDropEffect(it.toFloat())) }
        }
        val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(input)))
            .setEffects(Effects(emptyList(), videoEffects))
            .build()
        // Phones record HDR (10-bit HEVC); H.264 is 8-bit, so map it to SDR.
        val composition = Composition.Builder(EditedMediaItemSequence.Builder(item).build())
            .setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
            .build()

        val ok = withContext(Dispatchers.Main) { export(composition, out, bitrate, onProgress) }
        if (!ok || out.length() == 0L) {
            out.delete()
            return null
        }
        return PreparedFile(out, outName, "video/mp4", input.length(), shrunk = true)
    }

    private suspend fun export(composition: Composition, out: File, bitrate: Int, onProgress: (Int) -> Unit): Boolean = coroutineScope {
        val encoders = DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(bitrate).build())
            .setEnableFallback(true)
            .build()
        var transformer: Transformer? = null
        val progress = launch {
            val holder = ProgressHolder()
            while (true) {
                delay(500)
                if (transformer?.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) onProgress(holder.progress.coerceIn(0, 99))
            }
        }
        try {
            suspendCancellableCoroutine { cont ->
                val t = Transformer.Builder(context)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .setEncoderFactory(encoders)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                            if (cont.isActive) cont.resume(true)
                        }

                        override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                            if (cont.isActive) cont.resume(false)
                        }
                    })
                    .build()
                transformer = t
                cont.invokeOnCancellation { t.cancel() }
                t.start(composition, out.path)
            }
        } finally {
            progress.cancel()
        }
    }

    /** Upright display size, frame rate and bitrate; null if there is no video track. */
    private fun probe(file: File): Source? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.path)
            if (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) != "yes") return null
            val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: return null
            val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: return null
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            val bitrate = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull() ?: 0
            val quarterTurn = rotation == 90 || rotation == 270
            return Source(if (quarterTurn) h else w, if (quarterTurn) w else h, frameRate(file), bitrate)
        } catch (e: Exception) {
            return null
        } finally {
            retriever.release()
        }
    }

    private fun frameRate(file: File): Float {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(file.path)
            (0 until extractor.trackCount).map { extractor.getTrackFormat(it) }
                .firstOrNull { it.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true }
                ?.let { format ->
                    if (!format.containsKey(MediaFormat.KEY_FRAME_RATE)) 0f
                    else runCatching { format.getInteger(MediaFormat.KEY_FRAME_RATE).toFloat() }
                        .getOrElse { format.getFloat(MediaFormat.KEY_FRAME_RATE) }
                } ?: 0f
        } catch (e: Exception) {
            0f
        } finally {
            extractor.release()
        }
    }
}
