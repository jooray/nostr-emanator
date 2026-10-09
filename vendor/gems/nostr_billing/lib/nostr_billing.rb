# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require "time"

require_relative "nostr_billing/version"
require_relative "nostr_billing/errors"
require_relative "nostr_billing/client"
require_relative "nostr_billing/mock_client"
require_relative "nostr_billing/memory_cache"
require_relative "nostr_billing/snapshot"
require_relative "nostr_billing/gate"
require_relative "nostr_billing/charge_ledger"

# Client for the nostr-billing service, shared by the apps that sell through it
# (Lievik, Emanator). Billing is optional: without BILLING_API_URL the gate is
# disabled and allows everything, which is how a self-hosted install runs.
module NostrBilling
  # Builds a gate from BILLING_API_URL and BILLING_API_TOKEN. A blank URL gives a
  # disabled gate; a URL without a token, or an http URL that is not loopback,
  # raises at boot rather than failing on the first paid request.
  def self.from_env(product:, cache:, logger: nil, env: ENV)
    url = env["BILLING_API_URL"].to_s.strip
    return Gate.new(product: product, client: nil, cache: cache, logger: logger) if url.empty?

    token = env["BILLING_API_TOKEN"].to_s.strip
    raise ConfigError, "BILLING_API_TOKEN is required when BILLING_API_URL is set" if token.empty?

    Gate.new(product: product, client: Client.new(url: url, token: token), cache: cache, logger: logger)
  end
end
