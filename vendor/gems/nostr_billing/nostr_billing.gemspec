# frozen_string_literal: true

require_relative "lib/nostr_billing/version"

Gem::Specification.new do |spec|
  spec.name = "nostr_billing"
  spec.version = NostrBilling::VERSION
  spec.authors = ["Juraj Bednar"]
  spec.summary = "Client for the nostr-billing entitlement service"
  spec.description = "Entitlement checks, trials, daily caps and BTCPay charges against nostr-billing, " \
                     "with caching and an outage policy. Disabled (allow everything) when not configured."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb"] + ["README.md"]
  spec.require_paths = ["lib"]
end
