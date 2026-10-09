# frozen_string_literal: true

# The Android APK in public/android/ is served by Rails' static file server,
# which otherwise labels it text/plain (with nosniff), so phones save it as a
# text file instead of offering to install it.
Rack::Mime::MIME_TYPES[".apk"] = "application/vnd.android.package-archive"
