// Re-encodes a video in the browser before upload (WebCodecs, via mediabunny).
// A separate bundle, loaded only when a video is attached, so ordinary pages
// never download the encoder. The rules live in lib/video_rules.js.
import {
  ALL_FORMATS, BlobSource, BufferTarget, Conversion, Input, Mp4OutputFormat, Output, Quality, canEncodeVideo
} from "mediabunny"
import { renameVideo, videoBitrate, videoFrameRate, videoTargetSize } from "./lib/video_rules"

// Returns { file, original, shrunk }; `file` is what to upload.
export async function shrinkVideo(file, prefs, onProgress = () => {}) {
  const unchanged = { file, original: file.size, shrunk: false }
  if (typeof VideoEncoder === "undefined" || typeof VideoDecoder === "undefined") return unchanged

  const input = new Input({ source: new BlobSource(file), formats: ALL_FORMATS })
  try {
    const track = await input.getPrimaryVideoTrack()
    if (!track) return unchanged

    const stats = await track.computePacketStats(120)
    const [width, height] = videoTargetSize(track.displayWidth, track.displayHeight, Number(prefs.video_resolution) || 0)
    const bitrate = videoBitrate(width, height, stats.averagePacketRate, prefs.video_quality, stats.averageBitrate)
    if (!(await canEncodeVideo("avc", { width, height, bitrate }))) return unchanged

    const frameRate = videoFrameRate(stats.averagePacketRate)
    const output = new Output({ format: new Mp4OutputFormat({ fastStart: "in-memory" }), target: new BufferTarget() })
    const conversion = await Conversion.init({
      input,
      output,
      video: { codec: "avc", width, height, fit: "fill", quality: new Quality({ bitrate }), ...(frameRate ? { frameRate } : {}) },
      // No quality given, so AAC audio is copied as is; anything else becomes AAC.
      audio: { codec: "aac" },
      tags: {},
      showWarnings: false
    })
    // A dropped track (no AAC encoder in this browser, an exotic codec) would
    // upload a silent or empty clip: send the original instead.
    if (!conversion.isValid || conversion.discardedTracks.length > 0) return unchanged

    conversion.onProgress = (progress) => onProgress(progress)
    await conversion.execute()

    const name = renameVideo(file.name)
    const result = new File([output.target.buffer], name, { type: "video/mp4", lastModified: Date.now() })
    return { file: result, original: file.size, shrunk: true }
  } finally {
    input.dispose?.()
  }
}
