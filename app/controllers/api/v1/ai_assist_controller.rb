# frozen_string_literal: true

module Api
  module V1
    # AI writing: the web composer's actions (AiAssistActions) behind a device
    # token. Denials are JSON with a real status before any SSE header:
    # 402 paywall, 429 daily_cap / rate limit, 503 billing_unavailable.
    class AiAssistController < BaseController
      include AiAssistActions
    end
  end
end
