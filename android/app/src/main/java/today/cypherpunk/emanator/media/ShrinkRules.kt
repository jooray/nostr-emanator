package today.cypherpunk.emanator.media

import today.cypherpunk.emanator.data.MediaSettings
import java.util.Locale
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * The decisions behind shrinking a photo before upload, kept free of Android
 * types so they can be tested on the JVM. They match the web's
 * app/javascript/lib/media_compress.js, so a photo comes out the same whichever
 * client posted it:
 *
 *  - PNG stays lossless PNG (screenshots, line art, transparency), resized only.
 *  - Every other decodable still becomes `photo_format` ("jpeg" | "webp") at
 *    `quality`, flattened onto white when the target is JPEG.
 *  - GIF (may be animated), SVG, video, audio and PDFs are never touched.
 *  - A PNG that comes out larger without being resized keeps its original bytes.
 *    A JPEG never does: dropping its metadata is the reason to re-encode.
 */
object ShrinkRules {
    enum class Mode { Untouched, Lossless, Lossy }

    private val DECODABLE = setOf("image/jpeg", "image/jpg", "image/png", "image/webp", "image/heic", "image/heif", "image/avif", "image/bmp")

    /** HEIC/HEIF/AVIF decode only through ImageDecoder (API 28+). */
    private val NEEDS_IMAGE_DECODER = setOf("image/heic", "image/heif", "image/avif")

    fun normalize(mime: String?): String = mime.orEmpty().substringBefore(';').trim().lowercase(Locale.ROOT)

    fun mode(mime: String?, settings: MediaSettings, sdk: Int = Int.MAX_VALUE): Mode {
        val type = normalize(mime)
        if (!settings.compress || type !in DECODABLE) return Mode.Untouched
        if (type in NEEDS_IMAGE_DECODER && sdk < 28) return Mode.Untouched
        return if (type == "image/png") Mode.Lossless else Mode.Lossy
    }

    fun outputMime(mode: Mode, settings: MediaSettings): String? = when (mode) {
        Mode.Untouched -> null
        Mode.Lossless -> "image/png"
        Mode.Lossy -> if (settings.photoFormat == "webp") "image/webp" else "image/jpeg"
    }

    /** Scaled size with the longest side at most [maxEdge]; 0 keeps the size. Never upscales. */
    fun targetSize(width: Int, height: Int, maxEdge: Int): Pair<Int, Int> {
        val longest = max(width, height)
        if (maxEdge <= 0 || longest <= maxEdge) return width to height
        val scale = maxEdge.toDouble() / longest
        return max(1, (width * scale).roundToInt()) to max(1, (height * scale).roundToInt())
    }

    /** Whether to upload the original bytes instead of the re-encoded ones. */
    fun keepOriginal(mode: Mode, scaled: Boolean, encodedBytes: Long, originalBytes: Long): Boolean =
        mode == Mode.Lossless && !scaled && encodedBytes >= originalBytes

    fun quality(settings: MediaSettings) = settings.quality.coerceIn(1, 100)

    fun rename(name: String?, mime: String): String {
        val ext = when (mime) {
            "image/jpeg" -> "jpg"
            "image/webp" -> "webp"
            "image/png" -> "png"
            else -> return name ?: "file"
        }
        val base = (name ?: "image").substringBeforeLast('.').ifBlank { "image" }
        return "$base.$ext"
    }

    /** "4.2 MB", "380 KB" — the same rounding as the web's humanSize. */
    fun humanSize(bytes: Long): String = when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "${(bytes / 1024.0).roundToInt()} KB"
        else -> String.format(Locale.ROOT, "%.1f MB", bytes / (1024.0 * 1024.0))
    }

    /** File-system-safe version of a display name. */
    fun safeFileName(name: String): String = name.replace(Regex("[^A-Za-z0-9._-]"), "_").take(80)
}
