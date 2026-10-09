package today.cypherpunk.emanator.media

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.exifinterface.media.ExifInterface
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import today.cypherpunk.emanator.data.MediaSettings
import java.io.File
import java.io.FileNotFoundException
import java.util.Locale
import java.util.UUID

/** A file ready to upload, and what shrinking did to it. */
data class PreparedFile(
    val file: File,
    val name: String,
    val mime: String,
    val originalBytes: Long,
    val shrunk: Boolean,
) {
    val bytes: Long get() = file.length()
}

/**
 * Shrinks a photo on the phone before it is uploaded. Blossom stores exactly
 * the bytes it receives — a blob's address is their SHA-256 — so nothing can be
 * recompressed after the upload. Re-encoding also drops every byte of metadata
 * (EXIF, GPS position, camera serials). The rules are in [ShrinkRules].
 *
 * Videos are handed to [VideoShrinker]; `onProgress` reports its percent.
 *
 * Any failure falls back to the original bytes: shrinking must never block an
 * upload.
 */
class ImageShrinker(private val context: Context) {
    private val dir = File(context.cacheDir, "uploads").apply { mkdirs() }
    private val videos = VideoShrinker(context)

    suspend fun prepare(uri: Uri, settings: MediaSettings, onProgress: (Int) -> Unit = {}): PreparedFile {
        val copied = copyIn(uri)
        if (!VideoRules.shouldShrink(copied.mime, settings)) return shrinkImage(copied, settings)
        onProgress(0)
        val shrunk = try {
            videos.shrink(copied.file, copied.name, settings, onProgress)
        } catch (e: Exception) {
            null
        }
        return if (shrunk != null) shrunk.also { copied.file.delete() } else copied
    }

    private suspend fun copyIn(uri: Uri): PreparedFile = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val name = displayName(uri) ?: "file"
        val mime = ShrinkRules.normalize(resolver.getType(uri)).ifBlank { guessMime(name) }
        val original = File(dir, "${UUID.randomUUID()}-${ShrinkRules.safeFileName(name)}")
        resolver.openInputStream(uri)?.use { input -> original.outputStream().use { input.copyTo(it) } }
            ?: throw FileNotFoundException(name)
        PreparedFile(original, name, mime, original.length(), shrunk = false)
    }

    private suspend fun shrinkImage(untouched: PreparedFile, settings: MediaSettings): PreparedFile = withContext(Dispatchers.IO) {
        val (original, name, mime) = untouched
        val mode = ShrinkRules.mode(mime, settings, Build.VERSION.SDK_INT)
        if (mode == ShrinkRules.Mode.Untouched) return@withContext untouched

        try {
            val outMime = ShrinkRules.outputMime(mode, settings) ?: return@withContext untouched
            val (bitmap, scaled) = decode(original, settings.maxEdge) ?: return@withContext untouched
            val ready = if (outMime == "image/jpeg" && bitmap.hasAlpha()) flattenOnWhite(bitmap) else bitmap
            val outName = ShrinkRules.rename(name, outMime)
            val out = File(dir, "${UUID.randomUUID()}-${ShrinkRules.safeFileName(outName)}")
            val quality = if (mode == ShrinkRules.Mode.Lossless) 100 else ShrinkRules.quality(settings)
            out.outputStream().use { stream -> ready.compress(format(outMime), quality, stream) }
            if (ready !== bitmap) ready.recycle()
            bitmap.recycle()

            if (ShrinkRules.keepOriginal(mode, scaled, out.length(), original.length())) {
                out.delete()
                untouched
            } else {
                val originalBytes = original.length()
                original.delete()
                PreparedFile(out, outName, outMime, originalBytes, shrunk = true)
            }
        } catch (e: Exception) {
            untouched
        } catch (e: OutOfMemoryError) {
            // A huge panorama on a small phone: upload it as it is.
            untouched
        }
    }

    /** Decoded, upright and scaled; second = whether it was scaled. */
    private fun decode(file: File, maxEdge: Int): Pair<Bitmap, Boolean>? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) decodeWithImageDecoder(file, maxEdge) else decodeLegacy(file, maxEdge)

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.P)
    private fun decodeWithImageDecoder(file: File, maxEdge: Int): Pair<Bitmap, Boolean> {
        var scaled = false
        // ImageDecoder applies the EXIF orientation itself, and info.size is upright.
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
            val (w, h) = ShrinkRules.targetSize(info.size.width, info.size.height, maxEdge)
            scaled = w != info.size.width || h != info.size.height
            if (scaled) decoder.setTargetSize(w, h)
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        return bitmap to scaled
    }

    /** API 26–27: BitmapFactory, with the EXIF rotation applied by hand. */
    private fun decodeLegacy(file: File, maxEdge: Int): Pair<Bitmap, Boolean>? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val orientation = ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        val quarterTurn = orientation in QUARTER_TURNS
        val uprightW = if (quarterTurn) bounds.outHeight else bounds.outWidth
        val uprightH = if (quarterTurn) bounds.outWidth else bounds.outHeight
        val (targetW, targetH) = ShrinkRules.targetSize(uprightW, uprightH, maxEdge)
        val scaled = targetW != uprightW || targetH != uprightH

        // Power-of-two subsampling first, so a 50 MP photo never lands in memory whole.
        var sample = 1
        while (uprightW / (sample * 2) >= targetW && uprightH / (sample * 2) >= targetH) sample *= 2
        val decoded = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null

        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.postRotate(90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.postRotate(270f); matrix.postScale(-1f, 1f) }
        }
        val upright = if (matrix.isIdentity) decoded else Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        if (upright !== decoded) decoded.recycle()

        val result = if (upright.width == targetW && upright.height == targetH) upright
        else Bitmap.createScaledBitmap(upright, targetW, targetH, true)
        if (result !== upright) upright.recycle()
        return result to scaled
    }

    private fun flattenOnWhite(bitmap: Bitmap): Bitmap {
        val flat = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
        Canvas(flat).apply {
            drawColor(Color.WHITE)
            drawBitmap(bitmap, 0f, 0f, null)
        }
        return flat
    }

    private fun format(mime: String): Bitmap.CompressFormat = when (mime) {
        "image/png" -> Bitmap.CompressFormat.PNG
        "image/webp" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Bitmap.CompressFormat.WEBP_LOSSY else legacyWebp()
        else -> Bitmap.CompressFormat.JPEG
    }

    // Below API 30, WEBP with quality < 100 is lossy, which is what we ask for.
    @Suppress("DEPRECATION")
    private fun legacyWebp() = Bitmap.CompressFormat.WEBP

    fun displayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return runCatching {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        }.getOrNull() ?: uri.lastPathSegment
    }

    private fun guessMime(name: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase(Locale.ROOT))
            ?: "application/octet-stream"

    private companion object {
        val QUARTER_TURNS = setOf(
            ExifInterface.ORIENTATION_ROTATE_90, ExifInterface.ORIENTATION_ROTATE_270,
            ExifInterface.ORIENTATION_TRANSPOSE, ExifInterface.ORIENTATION_TRANSVERSE,
        )
    }
}
