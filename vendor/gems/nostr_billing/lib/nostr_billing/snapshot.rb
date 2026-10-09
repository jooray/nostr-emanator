# frozen_string_literal: true

module NostrBilling
  # What the app knows about one npub's entitlement for its own product, plus
  # the other products (for an "all-access active" line).
  #
  # source:
  #   :fresh    answered by billing just now or within the cache window
  #   :stale    billing is down; last good answer, re-checked against its own `until`
  #   :unknown  billing is down and nothing is cached: deny paid features
  #   :disabled billing is not configured (self-hosted): allow everything
  class Snapshot
    STATES = %w[active trial expired none].freeze

    attr_reader :product, :products, :source

    def self.disabled(product)
      new(product: product, products: {}, source: :disabled)
    end

    def self.unknown(product, now: -> { Time.now.to_i })
      new(product: product, products: {}, source: :unknown, now: now)
    end

    # products: { "lievik" => { "state" => "trial", "until" => 1759999999 }, ... }
    def initialize(product:, products:, source:, now: -> { Time.now.to_i })
      @product = product
      @products = products || {}
      @source = source
      @now = now
    end

    def disabled?
      source == :disabled
    end

    def unknown?
      source == :unknown
    end

    # "active", "trial", "expired", "none" or "unknown" for this app's product.
    def state(product = @product)
      return "active" if disabled?
      return "unknown" if unknown?

      entry = products[product] or return "none"
      raw = entry["state"].to_s
      # A cached answer must never grant past its own end.
      return "expired" if %w[active trial].include?(raw) && entry["until"] && entry["until"].to_i <= @now.call

      STATES.include?(raw) ? raw : "none"
    end

    def until_time(product = @product)
      value = products.dig(product, "until")
      value && Time.at(value.to_i)
    end

    def allows?(product = @product)
      %w[active trial].include?(state(product))
    end

    def active?(product = @product)
      state(product) == "active"
    end

    def trial?(product = @product)
      state(product) == "trial"
    end

    def expired?(product = @product)
      state(product) == "expired"
    end

    def none?(product = @product)
      state(product) == "none"
    end

    def to_h
      { product: product, state: state, until: until_time&.to_i, source: source, products: products }
    end
  end
end
