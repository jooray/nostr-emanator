# frozen_string_literal: true

module Nostr
  # Publishes a kind-0 metadata event for a paired account, signed through that
  # account's NIP-46 remote signer. No private key is involved anywhere here.
  #
  # This runs in PublishProfileJob, never in a web request: `request_signature`
  # blocks until the user approves in their signer (up to ~120 s).
  class ProfilePublisherService
    class PublishError < StandardError; end
    class SigningError < PublishError; end

    # Fields this app knows how to edit. Anything else already in the profile is
    # preserved untouched — see `merge_content`.
    EDITABLE_FIELDS = %w[name display_name about picture banner website nip05 lud16].freeze

    def initialize(account, progress: nil)
      @account = account
      @progress = progress
      @signer = EventSignerService.new
    end

    # `edits` is a hash of EDITABLE_FIELDS => value. A nil value means "leave as
    # is"; an empty string means "clear this field".
    # Returns the published event hash.
    def publish(edits)
      raise PublishError, I18n.t("profile_updates.errors.no_signer") unless @account.has_signer?
      unless @account.profile_editing_capable?
        raise PublishError, I18n.t("profile_updates.errors.needs_re_pair")
      end

      report(:fetching, I18n.t("profile_updates.steps.fetching"))
      existing = fetch_existing_event

      content = merge_content(existing&.dig("content"), edits)

      unsigned = @signer.build_unsigned_event(
        content: content,
        kind: 0,
        pubkey: @account.pubkey_hex,
        created_at: monotonic_created_at(existing&.dig("created_at")),
        tags: []
      )

      report(:signing, I18n.t("profile_updates.steps.signing"))
      signed = @signer.request_signature(@account, unsigned)
      raise SigningError, "Signing timed out or was rejected" unless signed

      report(:publishing, I18n.t("profile_updates.steps.publishing"))
      relays = (@account.write_relays || []) + (@account.user.custom_relays || [])
      results = EventPublisherService.new.publish(signed, relays: relays)

      accepted = results.values.count { |v| v == :ok }
      raise PublishError, I18n.t("profile_updates.errors.no_relay_accepted") if accepted.zero?

      { event: signed, results: results, accepted: accepted }
    end

    private

    def report(stage, message)
      @progress&.call(stage, message)
    end

    # Read the account's current kind 0 straight from relays rather than from our
    # cached columns. The cache holds only the four fields we display; publishing
    # from it would silently delete every other field the profile has.
    def fetch_existing_event
      ProfileFetcher.new.fetch_raw_event(@account.pubkey_hex)
    rescue StandardError => e
      Rails.logger.warn("Profile fetch failed for #{@account.pubkey_hex[0, 8]}…: #{e.class} - #{e.message}")
      nil
    end

    # Merge over the parsed existing object rather than building a fresh one.
    #
    # A kind 0 is replaceable: publishing a new one REPLACES the old, it does not
    # patch it. So anything present that this app does not model — nip05, lud16,
    # bot, birthday, a client's own extension field — is silently destroyed by a
    # naive rebuild. That is a data-loss bug wearing the costume of a feature.
    def merge_content(existing_json, edits)
      base = {}
      if existing_json.present?
        begin
          parsed = JSON.parse(existing_json)
          base = parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
          # A malformed existing profile starts clean rather than raising: the
          # alternative is a user who can never fix their own broken profile.
          Rails.logger.warn("Existing kind-0 for #{@account.pubkey_hex[0, 8]}… is not valid JSON; starting fresh")
        end
      end

      edits.each do |key, value|
        key = key.to_s
        next unless EDITABLE_FIELDS.include?(key)
        next if value.nil? # nil means "leave as is"

        value = value.to_s.strip
        if value.empty?
          base.delete(key)
        else
          base[key] = value
        end
      end

      JSON.generate(base)
    end

    # Two edits inside the same second would otherwise tie on created_at, and
    # relays break that tie by event id — effectively at random, so the older
    # edit can win and the user watches their change revert. Always land at
    # least one second after whatever is currently live.
    def monotonic_created_at(existing_created_at)
      now = Time.current.to_i
      latest = existing_created_at.to_i
      latest >= now ? latest + 1 : now
    end
  end
end
