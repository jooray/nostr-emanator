# frozen_string_literal: true

module Nostr
  # NIP-04 (AES-256-CBC, no MAC) is deprecated: it is malleable, padding-oracle
  # prone, and silently falling back to it gives a censoring relay a downgrade
  # path. All current signers speak NIP-44, so the fallback is off by default and
  # only exists for pairing an old signer.
  #
  # Enable with `nostr.allow_nip04_fallback: true` in config/emanator.yml (or
  # ALLOW_NIP04_FALLBACK=true).
  module Nip04Policy
    module_function

    def fallback_allowed?
      return ActiveModel::Type::Boolean.new.cast(ENV["ALLOW_NIP04_FALLBACK"]) if ENV.key?("ALLOW_NIP04_FALLBACK")

      !!Rails.application.config_for(:emanator).dig(:nostr, :allow_nip04_fallback)
    rescue StandardError
      false
    end

    # Logs once per process so a signer stuck on NIP-04 is visible without
    # flooding the log.
    def log_refusal(context)
      @logged ||= {}
      return if @logged[context]

      @logged[context] = true
      Rails.logger.warn(
        "#{context}: payload could not be decrypted with NIP-44 and the deprecated NIP-04 " \
        "fallback is disabled (set nostr.allow_nip04_fallback to re-enable)"
      )
    end
  end
end
