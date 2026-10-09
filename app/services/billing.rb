# frozen_string_literal: true

# Paid AI assist on the hosted instance, through the shared nostr-billing
# service (vendor/gems/nostr_billing). Everything else in Emanator is free.
#
# Billing is off unless BILLING_API_URL is set: the gate then allows every AI
# request and the billing pages answer 404, so a self-hosted install behaves
# exactly as before. Tests get a disabled gate by default and swap in
# NostrBilling::MockClient through `Billing.gate=`.
module Billing
  PRODUCT = "emanator-ai"
  # Plans this app sells: its own and the bundle.
  PLANS = [ PRODUCT, "all-access" ].freeze
  # Accounts (managed npubs) a user without a trial or paid time may pair.
  # Paying, or a running trial, lifts the limit; billing off means no limit.
  FREE_ACCOUNT_LIMIT = 10

  # Reads Rails.cache on every call, so a test that swaps the cache store
  # (CacheHelper) is seen by a gate built earlier.
  module Cache
    def self.read(key) = Rails.cache.read(key)
    def self.write(key, value, expires_in: nil) = Rails.cache.write(key, value, expires_in: expires_in)
    def self.delete(key) = Rails.cache.delete(key)
  end

  class << self
    attr_writer :gate

    def gate
      @gate ||= build
    end

    def enabled?
      gate.enabled?
    end

    # True when the user may pair one more account. Existing accounts are never
    # taken away; a user over the limit (from a trial, or from before it
    # existed) only cannot add more.
    def can_add_account?(user)
      return true unless enabled?
      return true if user.accounts.count < FREE_ACCOUNT_LIMIT

      gate.status(user.npub).allows?
    end

    private

    def build
      if Rails.env.test?
        NostrBilling::Gate.new(product: PRODUCT, client: nil, cache: Cache)
      else
        NostrBilling.from_env(product: PRODUCT, cache: Cache, logger: Rails.logger)
      end
    end
  end
end
