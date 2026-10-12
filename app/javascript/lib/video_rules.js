// The decisions behind re-encoding a video before upload. Shared by the
// composer and the video_compress bundle, and mirrored in the Android app
// (android/…/media/VideoRules.kt) so a clip comes out the same either way.
// The numbers are MediaPreferences' (app/models/media_preferences.rb).
//
//   * Output is MP4 with H.264 video — what every Nostr client plays.
//   * The shorter side is scaled down to `video_resolution` (0 keeps it).
//   * At most 30 frames per second.
//   * Bitrate is width × height × fps × bits-per-pixel for `video_quality`,
//     never above the source's own, so a clip never grows.
//   * Audio is copied when it already is AAC, re-encoded to AAC otherwise.
//   * No metadata tags (location, camera, software) are written.
//   * Anything that cannot be re-encoded here goes up as it is.
//   * A clip small enough to upload unconverted (within the server's upload
//     limit) asks first: the original, the re-encoded copy, or whichever of the
//     two comes out smaller.

const VIDEO_TYPES = /^video\/(mp4|quicktime|webm|x-matroska|3gpp)$/

export const BITS_PER_PIXEL = { small: 0.05, balanced: 0.08, high: 0.12 }
export const MAX_FPS = 30
const MIN_BITRATE = 250_000

export function shouldShrinkVideo(file, prefs) {
  return !!(prefs && prefs.video_compress && VIDEO_TYPES.test(file.type))
}

// The answers to that question, in the order they are offered.
export const VIDEO_MODES = ["original", "reencode", "smaller"]

export function offerVideoChoice(file, prefs, maxBytes) {
  return shouldShrinkVideo(file, prefs) && maxBytes > 0 && file.size <= maxBytes
}

// After re-encoding: true to upload the re-encoded copy, false for the original.
export function useReencoded(mode, originalBytes, reencodedBytes) {
  if (mode === "original") return false
  if (mode === "smaller") return reencodedBytes < originalBytes
  return true
}

// Upright display size → output size, both sides even (H.264 needs it).
export function videoTargetSize(width, height, resolution) {
  const shorter = Math.min(width, height)
  const scale = resolution > 0 && shorter > resolution ? resolution / shorter : 1
  return [even(width * scale), even(height * scale)]
}

export function videoFrameRate(sourceFps) {
  return sourceFps > MAX_FPS + 0.5 ? MAX_FPS : null // null: keep the source's
}

export function videoBitrate(width, height, sourceFps, quality, sourceBitrate) {
  const bpp = BITS_PER_PIXEL[quality] || BITS_PER_PIXEL.balanced
  const fps = Math.min(sourceFps > 0 ? sourceFps : MAX_FPS, MAX_FPS)
  let bitrate = Math.round(width * height * fps * bpp)
  if (sourceBitrate > 0) bitrate = Math.min(bitrate, Math.round(sourceBitrate))
  return Math.max(bitrate, MIN_BITRATE)
}

export function renameVideo(name) {
  return `${(name || "video").replace(/\.[^.]+$/, "") || "video"}.mp4`
}

function even(n) {
  return Math.max(2, 2 * Math.round(n / 2))
}
