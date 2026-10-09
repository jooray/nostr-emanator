// Shrinks a photo in the browser before it is uploaded.
//
// Blossom stores exactly the bytes it receives — a blob's address is their
// SHA-256 — so nothing can be recompressed after the upload. Whatever leaves
// this browser is what every reader downloads. Re-encoding also drops all
// metadata (EXIF, GPS position, camera serials), which a phone photo otherwise
// publishes to the world.
//
// The rules match the Android app's (android/…/media/ImageShrinker.kt), and
// both read the same per-user settings (MediaPreferences), so a photo comes out
// the same whichever client posted it:
//
//   * PNG stays lossless PNG (screenshots, line art, transparency), resized only.
//   * Every other still image becomes `photo_format` ("jpeg" | "webp") at
//     `quality`, flattened onto white when the target is JPEG.
//   * GIF (may be animated), SVG, video, audio and PDFs are never touched.
//   * Anything the browser cannot decode (HEIC in most browsers) is sent as is.
//   * A PNG that comes out larger without being resized keeps its original
//     bytes. A JPEG never does: its metadata is the reason to re-encode.

const DECODABLE = /^image\/(jpeg|png|webp|avif|bmp)$/

export function shouldShrink(file, prefs) {
  return !!(prefs && prefs.compress && DECODABLE.test(file.type))
}

// Returns { file, original, shrunk } — `file` is what to upload.
export async function shrinkImage(file, prefs) {
  const unchanged = { file, original: file.size, shrunk: false }
  if (!shouldShrink(file, prefs)) return unchanged

  let bitmap
  try {
    bitmap = await createImageBitmap(file, { imageOrientation: "from-image" })
  } catch {
    return unchanged
  }

  try {
    const maxEdge = Number(prefs.max_edge) || 0
    const longest = Math.max(bitmap.width, bitmap.height)
    const scale = maxEdge > 0 && longest > maxEdge ? maxEdge / longest : 1
    const width = Math.max(1, Math.round(bitmap.width * scale))
    const height = Math.max(1, Math.round(bitmap.height * scale))

    const lossless = file.type === "image/png"
    const type = lossless ? "image/png" : (prefs.photo_format === "webp" ? "image/webp" : "image/jpeg")

    const canvas = makeCanvas(width, height)
    const ctx = canvas.getContext("2d")
    if (type === "image/jpeg") {
      ctx.fillStyle = "#ffffff"
      ctx.fillRect(0, 0, width, height)
    }
    ctx.imageSmoothingEnabled = true
    ctx.imageSmoothingQuality = "high"
    ctx.drawImage(bitmap, 0, 0, width, height)

    const blob = await toBlob(canvas, type, lossless ? undefined : (Number(prefs.quality) || 85) / 100)
    // A browser that cannot encode the type (old Safari and WebP) answers PNG.
    if (!blob || blob.type !== type) return unchanged
    if (lossless && scale === 1 && blob.size >= file.size) return unchanged

    const renamed = new File([blob], renameFor(file.name, type), { type, lastModified: Date.now() })
    return { file: renamed, original: file.size, shrunk: true }
  } finally {
    bitmap.close?.()
  }
}

export function humanSize(bytes) {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

function makeCanvas(width, height) {
  if (typeof OffscreenCanvas !== "undefined") return new OffscreenCanvas(width, height)
  const canvas = document.createElement("canvas")
  canvas.width = width
  canvas.height = height
  return canvas
}

function toBlob(canvas, type, quality) {
  if (canvas.convertToBlob) return canvas.convertToBlob({ type, quality })
  return new Promise((resolve) => canvas.toBlob(resolve, type, quality))
}

function renameFor(name, type) {
  const ext = { "image/jpeg": "jpg", "image/webp": "webp", "image/png": "png" }[type]
  const base = (name || "image").replace(/\.[^.]+$/, "")
  return `${base}.${ext}`
}
