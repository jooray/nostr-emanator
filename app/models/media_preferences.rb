# frozen_string_literal: true

# How images are shrunk before they are uploaded. Blossom stores exactly the
# bytes it receives (the blob's address is their SHA-256), so nothing can be
# recompressed after the fact: whatever a client sends is what every reader
# downloads, forever. Both clients therefore shrink on the device, before the
# upload, and they read these settings from the user so the web composer and
# the Android app produce the same result.
#
# Re-encoding also drops every byte of metadata — EXIF, GPS, camera serials —
# which a raw phone photo otherwise publishes to the world.
#
#   compress     shrink at all (off = upload the file untouched)
#   max_edge     longest side in pixels, 0 = keep the size
#   quality      lossy quality for photos, 50..95
#   photo_format "jpeg" or "webp" for photos. Images with transparency and PNG
#                screenshots stay lossless PNG — text and line art turn to mush
#                as JPEG. Animated GIFs, SVG and anything not an image are
#                never touched.
#
# Videos are re-encoded the same way (both clients, same rules):
#
#   video_compress    re-encode videos at all (off = upload untouched)
#   video_resolution  shorter side in pixels ("1080p"), 0 = keep the size
#   video_quality     "small" | "balanced" | "high": bits per pixel per frame,
#                     see VIDEO_BITS_PER_PIXEL. Output is H.264 + AAC in MP4
#                     (what every Nostr client plays), at most 30 fps, and
#                     never above the source's own bitrate.
module MediaPreferences
  SETTING = "media"
  MAX_EDGES = [ 0, 1280, 1600, 2048, 2560, 3840 ].freeze
  PHOTO_FORMATS = %w[jpeg webp].freeze
  QUALITY_RANGE = (50..95)
  VIDEO_RESOLUTIONS = [ 0, 480, 720, 1080, 1440 ].freeze
  VIDEO_QUALITIES = %w[small balanced high].freeze
  # The clients' bitrate rule: width × height × fps × this. Mirrored in
  # app/javascript/lib/video_compress.js and android/…/media/VideoRules.kt.
  VIDEO_BITS_PER_PIXEL = { "small" => 0.05, "balanced" => 0.08, "high" => 0.12 }.freeze

  DEFAULTS = {
    "compress" => true,
    "max_edge" => 2048,
    "quality" => 85,
    "photo_format" => "jpeg",
    "video_compress" => true,
    "video_resolution" => 1080,
    "video_quality" => "balanced"
  }.freeze

  def self.for(user)
    stored = user.settings&.dig(SETTING)
    DEFAULTS.merge(stored.is_a?(Hash) ? stored.slice(*DEFAULTS.keys) : {})
  end

  # Merges the recognised, valid values in `changes` and saves. Unknown keys
  # and out-of-range values are ignored rather than stored.
  def self.update!(user, changes)
    changes = changes.to_h.stringify_keys
    current = self.for(user)

    current["compress"] = ActiveModel::Type::Boolean.new.cast(changes["compress"]) if changes.key?("compress")
    if changes.key?("max_edge") && MAX_EDGES.include?(changes["max_edge"].to_i)
      current["max_edge"] = changes["max_edge"].to_i
    end
    if changes.key?("quality") && QUALITY_RANGE.cover?(changes["quality"].to_i)
      current["quality"] = changes["quality"].to_i
    end
    current["photo_format"] = changes["photo_format"] if PHOTO_FORMATS.include?(changes["photo_format"])
    current["video_compress"] = ActiveModel::Type::Boolean.new.cast(changes["video_compress"]) if changes.key?("video_compress")
    if changes.key?("video_resolution") && VIDEO_RESOLUTIONS.include?(changes["video_resolution"].to_i)
      current["video_resolution"] = changes["video_resolution"].to_i
    end
    current["video_quality"] = changes["video_quality"] if VIDEO_QUALITIES.include?(changes["video_quality"])

    user.settings = (user.settings || {}).merge(SETTING => current)
    user.save!
    current
  end
end
