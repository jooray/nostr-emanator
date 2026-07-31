# frozen_string_literal: true

# Gives a test class a real cache.
#
# config/environments/test.rb sets `cache_store = :null_store`, so every
# Rails.cache.write is a no-op and every read returns nil. That is the right
# default — it keeps unrelated tests from sharing state — but it silently makes
# anything cache-backed untestable: InteractionsCache, the WoT budget, rate
# limits. Swapping in a MemoryStore per test class is explicit and leaks nothing
# between classes.
module CacheHelper
  extend ActiveSupport::Concern

  included do
    # Runs in before_setup, i.e. ahead of the class's own `def setup`.
    setup do
      @previous_cache_store = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
    end

    teardown do
      Rails.cache = @previous_cache_store
    end
  end
end
