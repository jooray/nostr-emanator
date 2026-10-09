# frozen_string_literal: true

module NostrBilling
  class Error < StandardError; end

  # Misconfiguration: missing token, rejected key (401/403), bad URL.
  class ConfigError < Error; end

  # Billing could not answer: timeout, connection failure, 429 or 5xx.
  class Unavailable < Error; end

  # 400 or 404: the request itself was wrong (unknown plan, bad npub, unknown charge).
  class BadRequest < Error
    attr_reader :status

    def initialize(message, status: 400)
      super(message)
      @status = status
    end
  end

  # 409 from POST /v1/trials: the trial was already used or the product is active.
  class Conflict < Error
    attr_reader :reason

    def initialize(reason)
      super("conflict: #{reason}")
      @reason = reason
    end
  end
end
