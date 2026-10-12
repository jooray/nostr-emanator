package today.cypherpunk.emanator.media

import today.cypherpunk.emanator.data.MediaSettings
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * The decisions behind re-encoding a video before upload, free of Android
 * types so they can be tested on the JVM. They match the web's
 * app/javascript/lib/video_rules.js, and the numbers are MediaPreferences':
 *
 *  - Output is MP4 with H.264 video, which every Nostr client plays.
 *  - The shorter side is scaled down to `video_resolution` (0 keeps it).
 *  - At most 30 frames per second.
 *  - Bitrate is width × height × fps × bits-per-pixel for `video_quality`,
 *    never above the source's own, so a clip never grows.
 *  - Audio is re-encoded to AAC (copied when nothing else changes).
 *  - No metadata (location, camera) is written.
 *  - Anything that cannot be re-encoded goes up as it is.
 *  - A clip small enough to upload unconverted (within the server's upload
 *    limit) asks first: the original, the re-encoded copy, or whichever of
 *    the two comes out smaller.
 */
object VideoRules {
    val BITS_PER_PIXEL = mapOf("small" to 0.05, "balanced" to 0.08, "high" to 0.12)
    const val MAX_FPS = 30
    private const val MIN_BITRATE = 250_000

    private val VIDEO_TYPES = setOf("video/mp4", "video/quicktime", "video/webm", "video/x-matroska", "video/3gpp")

    fun shouldShrink(mime: String?, settings: MediaSettings): Boolean =
        settings.videoCompress && ShrinkRules.normalize(mime) in VIDEO_TYPES

    /** The answers to that question, in the order they are offered. */
    enum class Mode { Original, Reencode, Smaller }

    fun offerChoice(mime: String?, bytes: Long, settings: MediaSettings, maxBytes: Long): Boolean =
        shouldShrink(mime, settings) && maxBytes > 0 && bytes <= maxBytes

    /** After re-encoding: true to upload the re-encoded copy, false for the original. */
    fun useReencoded(mode: Mode, originalBytes: Long, reencodedBytes: Long): Boolean = when (mode) {
        Mode.Original -> false
        Mode.Smaller -> reencodedBytes < originalBytes
        Mode.Reencode -> true
    }

    /** Upright display size → output size, both sides even (H.264 needs it). */
    fun targetSize(width: Int, height: Int, resolution: Int): Pair<Int, Int> {
        val shorter = min(width, height)
        val scale = if (resolution > 0 && shorter > resolution) resolution.toDouble() / shorter else 1.0
        return even(width * scale) to even(height * scale)
    }

    /** The frame rate to cap at, or null to keep the source's. */
    fun frameRate(sourceFps: Float): Int? = if (sourceFps > MAX_FPS + 0.5f) MAX_FPS else null

    fun bitrate(width: Int, height: Int, sourceFps: Float, quality: String, sourceBitrate: Int): Int {
        val bpp = BITS_PER_PIXEL[quality] ?: BITS_PER_PIXEL.getValue("balanced")
        val fps = min(if (sourceFps > 0) sourceFps.toDouble() else MAX_FPS.toDouble(), MAX_FPS.toDouble())
        var bitrate = (width.toLong() * height * fps * bpp).roundToLong()
        if (sourceBitrate > 0) bitrate = min(bitrate, sourceBitrate.toLong())
        return max(bitrate, MIN_BITRATE.toLong()).toInt()
    }

    fun rename(name: String?): String = "${(name ?: "video").substringBeforeLast('.').ifBlank { "video" }}.mp4"

    private fun even(n: Double): Int = max(2, 2 * (n / 2).roundToInt())
}
