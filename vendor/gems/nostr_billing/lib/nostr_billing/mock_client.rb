# frozen_string_literal: true

module NostrBilling
  # In-memory stand-in for Client, for the apps' tests and local development.
  # It follows the service's rules closely enough to drive every app path:
  # trials once per (npub, product), all-access granting all three products,
  # consume refusing without entitlement, charges settling on demand.
  class MockClient
    PRODUCTS = NostrBilling::PRODUCTS
    PLAN_PRODUCTS = {
      "nalgorithm" => %w[nalgorithm], "emanator-ai" => %w[emanator-ai],
      "lievik" => %w[lievik], "all-access" => PRODUCTS
    }.freeze
    PLAN_SATS = { "nalgorithm" => 10_000, "emanator-ai" => 10_000, "lievik" => 15_000, "all-access" => 25_000 }.freeze
    TRIAL_SECONDS = 3 * 86_400

    attr_reader :calls
    # Set to an exception (for example NostrBilling::Unavailable.new("down")) to
    # make every call raise it.
    attr_accessor :failure
    # Set to false to make consume answer cap_reached for an entitled npub.
    attr_accessor :consume_allowed

    def initialize(now: -> { Time.now.to_i })
      @now = now
      @grants = Hash.new { |h, k| h[k] = {} }   # npub => { product => { until:, paid: } }
      @trials = Hash.new { |h, k| h[k] = {} }   # npub => { product => true }
      @charges = {}
      @calls = []
      @consume_allowed = true
    end

    # Test helper: give npub `product` (or a plan) until `until_time` (Time or epoch).
    def grant(npub, product, until_time)
      PLAN_PRODUCTS.fetch(product, [product]).each { |p| @grants[npub][p] = { until: until_time.to_i, paid: true } }
    end

    def mark_trial_used(npub, product)
      @trials[npub][product] = true
    end

    # Test helper: settle a charge created through create_charge.
    def settle!(invoice_id)
      charge = @charges.fetch(invoice_id)
      return if charge[:settled]

      charge[:settled] = true
      days = charge[:sats] * 30.0 / PLAN_SATS.fetch(charge[:plan])
      PLAN_PRODUCTS.fetch(charge[:plan]).each do |p|
        base = [now, @grants[charge[:npub]].dig(p, :until).to_i].max
        @grants[charge[:npub]][p] = { until: base + (days * 86_400).floor, paid: true }
      end
    end

    def entitlement(npub)
      record(:entitlement, npub)
      { "npub" => npub, "now" => now, "products" => products_for(npub) }
    end

    def start_trial(npub, product)
      record(:start_trial, npub, product)
      state = products_for(npub)[product]["state"]
      raise Conflict, "already_active" if state == "active"
      raise Conflict, "already_used" if @trials[npub][product]

      @trials[npub][product] = true
      @grants[npub][product] = { until: now + TRIAL_SECONDS, paid: false }
      { "product" => product, "state" => "trial", "until" => now + TRIAL_SECONDS }
    end

    def consume(npub, product, kind:, units: 1, key: nil)
      record(:consume, npub, product, kind, units, key)
      state = products_for(npub)[product]["state"]
      return { "allowed" => false, "reason" => "not_entitled", "remaining" => 0 } unless %w[active trial].include?(state)
      return { "allowed" => false, "reason" => "cap_reached", "remaining" => 0 } unless consume_allowed

      { "allowed" => true, "remaining" => 100 }
    end

    def create_charge(npub, plan:, sats: nil, redirect_url: nil)
      record(:create_charge, npub, plan, sats, redirect_url)
      raise BadRequest, "unknown plan" unless PLAN_SATS.key?(plan)

      id = "inv_#{@charges.size + 1}"
      sats ||= PLAN_SATS[plan]
      @charges[id] = { npub: npub, plan: plan, sats: sats, settled: false }
      { "invoice_id" => id, "checkout_url" => "https://pay.example.test/i/#{id}", "sats" => sats }
    end

    # Test helper: mark an unpaid charge as expired.
    def expire!(invoice_id)
      @charges.fetch(invoice_id)[:status] = "Expired"
    end

    def charge(id)
      record(:charge, id)
      charge = @charges[id] or raise BadRequest.new("unknown charge", status: 404)
      body = charge[:settled] ? { "settled" => true, "plan" => charge[:plan] } : { "settled" => false, "status" => charge[:status] || "New" }
      body.merge("products" => products_for(charge[:npub]))
    end

    def plans
      record(:plans)
      {
        "trial_days" => 3, "min_charge_sats" => 1_000, "max_charge_sats" => 1_000_000,
        "plans" => PLAN_SATS.to_h { |name, sats| [name, { "sats" => sats, "days" => 30, "products" => PLAN_PRODUCTS[name] }] }
      }
    end

    private

    def now
      @now.call
    end

    def record(*call)
      @calls << call
      raise failure if failure
    end

    def products_for(npub)
      PRODUCTS.to_h do |p|
        grant = @grants[npub][p]
        state =
          if grant.nil? then "none"
          elsif grant[:until] <= now then "expired"
          elsif grant[:paid] then "active"
          else "trial"
          end
        [p, { "state" => state, "until" => grant&.dig(:until) }]
      end
    end
  end
end
