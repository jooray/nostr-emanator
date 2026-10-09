# frozen_string_literal: true

# Turns billing on for one test class, backed by NostrBilling::MockClient and
# a MemoryStore, and turns it back off afterwards. Without this, tests run with
# billing disabled, like a self-hosted install.
module BillingTestHelper
  extend ActiveSupport::Concern

  included do
    setup do
      @previous_cache_store = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      @billing = NostrBilling::MockClient.new
      Billing.gate = NostrBilling::Gate.new(product: Billing::PRODUCT, client: @billing, cache: Billing::Cache)
    end

    teardown do
      Billing.gate = nil
      Rails.cache = @previous_cache_store
    end
  end

  def billing_calls(name)
    @billing.calls.select { |call| call.first == name }
  end
end
