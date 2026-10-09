# frozen_string_literal: true

# AI writing for the web composer. The actions, gate and stream format live in
# AiAssistActions so the native app's API gets exactly the same behaviour.
#
# H5: generate_stream/refine_stream used to be GET, so a SameSite=Lax top-level
# navigation (a crafted link) could trigger a paid AI call from a logged-in
# user's browser with no confirmation. The routes are POST only — the client
# streams the SSE response via fetch()/ReadableStream instead of EventSource
# (which cannot POST).
class AiAssistController < ApplicationController
  include AiAssistActions
end
