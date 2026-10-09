# frozen_string_literal: true

module Accounts
  # Pairing a signer (NIP-46) to a managed account, for the web "Add account" /
  # "Re-pair" pages and the native app alike. The caller owns the pairing
  # session's id — a cookie on the web, the app's own memory on the phone — and
  # asks this object what became of it.
  class Pairing
    # status: :pending, :expired, :paired, :over_limit or :failed
    Result = Struct.new(:status, :account, :auth_url, :error, keyword_init: true) do
      def paired? = status == :paired
    end

    def self.start
      Nip46SupervisorJob.ensure_running
      Nostr::AuthService.new.generate_connect_uri
    end

    # The nostrconnect:// URI of a session already started, so a reload (or a
    # second tab) shows the same QR instead of issuing a new one (L28).
    # Mirrors Nostr::AuthService#generate_connect_uri minus the key material.
    def self.connect_data(auth_session)
      relay_urls = auth_session.relay_urls
      relay_params = relay_urls.map { |r| "relay=#{CGI.escape(r)}" }.join("&")
      canonical_url = Nostr::AuthService.new.canonical_url
      metadata = "secret=#{auth_session.secret}&name=#{CGI.escape('Emanator')}" \
                 "&perms=#{CGI.escape(Nostr::AuthService::PERMISSIONS)}&url=#{CGI.escape(canonical_url)}"

      {
        uri: "nostrconnect://#{auth_session.temp_pubkey}?#{relay_params}&#{metadata}",
        session_id: auth_session.session_id,
        relay_urls: relay_urls
      }
    end

    def self.active_session(session_id)
      return nil if session_id.blank?

      NostrAuthSession.active.find_by(session_id: session_id)
    end

    def initialize(user, session_id)
      @user = user
      @auth_session = self.class.active_session(session_id)
    end

    # Adding a new account. Completes (and consumes the session) once the signer
    # has answered; until then reports :pending.
    def complete_new
      return Result.new(status: :expired) if @auth_session.nil?
      return pending unless @auth_session.authenticated?

      pubkey = @auth_session.authenticated_user_pubkey
      account = @user.accounts.find_or_initialize_by(pubkey_hex: pubkey)
      # Re-pairing an account the user already has is always allowed.
      if account.new_record? && !Billing.can_add_account?(@user)
        return Result.new(status: :over_limit, error: I18n.t("billing.account_limit", limit: Billing::FREE_ACCOUNT_LIMIT))
      end

      account.assign_attributes(npub: Nostr::KeyConverter.hex_to_npub(pubkey))
      account.apply_signer(@auth_session)
      return Result.new(status: :failed, error: account.errors.full_messages.join(", ")) unless account.save

      finish(account)
    rescue ActiveRecord::RecordNotUnique
      # L16: find_or_initialize_by + save races another request pairing the
      # same key (double poll / second tab) — finish against the row it made.
      finish(@user.accounts.find_by!(pubkey_hex: pubkey))
    end

    # Re-pairing an existing account. The signer must speak for that same key.
    def complete_re_pair(account)
      return Result.new(status: :expired) if @auth_session.nil?
      return pending unless @auth_session.authenticated?

      if @auth_session.authenticated_user_pubkey != account.pubkey_hex
        @auth_session.consume!
        return Result.new(status: :failed, error: I18n.t("accounts.re_pair_poll.identity_mismatch",
                                                           signer: @auth_session.authenticated_user_pubkey[0..15],
                                                           account: account.pubkey_hex[0..15]))
      end

      unless account.apply_signer(@auth_session).save
        return Result.new(status: :failed, error: I18n.t("accounts.re_pair_poll.save_failed",
                                                           errors: account.errors.full_messages.to_sentence))
      end

      @auth_session.consume!
      Result.new(status: :paired, account: account)
    end

    private

    def pending
      Result.new(status: :pending, auth_url: @auth_session.auth_url)
    end

    # H11: profile + relay-list fetches are blocking relay round-trips (worst
    # case ~40s combined) — never do them inline in the pairing request.
    def finish(account)
      @auth_session.consume!
      FetchAccountProfileJob.perform_later(account.id)
      FetchRelayListJob.perform_later(account.id)
      Result.new(status: :paired, account: account)
    end
  end
end
