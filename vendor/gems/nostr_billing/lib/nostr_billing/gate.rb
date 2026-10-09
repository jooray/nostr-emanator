# frozen_string_literal: true

module NostrBilling
  # The one object an app talks to. It answers "may this npub use the paid
  # features of my product", caches the answer, and decides what happens when
  # billing is down. Without a client it is disabled and allows everything.
  #
  # Cache (any ActiveSupport::Cache-like store):
  #   nostr_billing:v1:ent:<npub>    fresh answer, FRESH_TTL
  #   nostr_billing:v1:stale:<npub>  last good answer, STALE_TTL, used only while billing is down
  #   nostr_billing:v1:down          circuit breaker, BREAKER_TTL, skips calls after a failure
  #   nostr_billing:v1:plans         price list, PLANS_TTL
  class Gate
    FRESH_TTL = 60
    STALE_TTL = 24 * 3600
    BREAKER_TTL = 15
    PLANS_TTL = 3600
    PREFIX = "nostr_billing:v1"

    attr_reader :product, :client

    def initialize(product:, client:, cache:, logger: nil, now: -> { Time.now.to_i })
      raise ArgumentError, "unknown product #{product}" unless PRODUCTS.include?(product)

      @product = product
      @client = client
      @cache = cache
      @logger = logger
      @now = now
    end

    def enabled?
      !@client.nil?
    end

    # Snapshot for npub. Never raises for an outage: a down billing service gives
    # the stale answer or :unknown.
    def status(npub)
      return Snapshot.disabled(product) unless enabled?

      cached = @cache.read(key(:ent, npub))
      return snapshot(cached, :fresh) if cached

      fetch(npub)
    end

    def allows?(npub)
      status(npub).allows?
    end

    # Starts this product's trial for npub and returns the new snapshot. A trial
    # that was already used, or a product that is already active, is not an
    # error: the snapshot says what the npub has. Only call this from an
    # explicit user action, never from a background job.
    def start_trial(npub)
      return Snapshot.disabled(product) unless enabled?

      begin
        @client.start_trial(npub, product)
      rescue Conflict => e
        log(:info, "trial for #{npub} not started: #{e.reason}")
      rescue Unavailable, ConfigError => e
        trip(e)
        return status(npub)
      end
      invalidate(npub)
      fetch(npub)
    end

    # Starts the trial when npub has never had this product, otherwise just
    # returns the status. This is the "first AI activation" hook.
    def activate(npub)
      snap = status(npub)
      snap.none? ? start_trial(npub) : snap
    end

    # Counts units against the daily safety cap. Returns
    #   :allowed       go ahead
    #   :capped        daily cap reached
    #   :not_entitled  no trial or paid time
    #   :unavailable   billing is down and the npub was not known to be paid
    # During an outage only an npub last seen as paid ("active") is allowed;
    # a trial is not, so outages cannot be farmed with fresh keys.
    def consume(npub, kind:, units: 1, key: nil)
      return :allowed unless enabled?

      begin
        raise Unavailable, "circuit open" if down?

        result = @client.consume(npub, product, kind: kind, units: units, key: key)
      rescue Unavailable, ConfigError => e
        trip(e)
        return status(npub).active? ? :allowed : :unavailable
      end
      return :allowed if result["allowed"]

      result["reason"] == "cap_reached" ? :capped : :not_entitled
    end

    # Creates a BTCPay charge. Returns the billing response
    # ({"invoice_id", "checkout_url", "sats", ...}). Raises Unavailable,
    # BadRequest or ConfigError; the caller shows an error.
    def create_charge(npub, plan:, sats: nil, redirect_url: nil)
      raise ConfigError, "billing is not configured" unless enabled?
      raise BadRequest, "unknown plan" unless PLANS.include?(plan)

      @client.create_charge(npub, plan: plan, sats: sats, redirect_url: redirect_url)
    end

    # Polls a charge. Billing settles it from BTCPay if the webhook was missed.
    # On settlement the npub's cached entitlement is dropped and refreshed.
    # Returns { settled: true|false, status:, snapshot: }.
    def charge(npub, invoice_id)
      raise ConfigError, "billing is not configured" unless enabled?

      body = @client.charge(invoice_id)
      settled = body["settled"] == true
      snap =
        if body["products"].is_a?(Hash)
          remember(npub, body["products"])
          snapshot(body["products"], :fresh)
        else
          status(npub)
        end
      { settled: settled, status: body["status"], snapshot: snap }
    end

    # BTCPay statuses after which an invoice can no longer be paid.
    DEAD_INVOICE_STATUSES = %w[Expired Invalid].freeze

    # Checks the charges a session created (a ChargeLedger), for the page the
    # payer returns to. Billing settles each one from BTCPay if its webhook has
    # not arrived yet. Settled, dead and unknown charges leave the ledger, so
    # each is reported once. Returns the settled ones as
    # [{ id:, plan:, snapshot: }], newest first; outages are skipped quietly.
    def check_charges(npub, ledger)
      return [] unless enabled?

      ledger.ids.filter_map do |id|
        plan = ledger.plan(id)
        result = charge(npub, id)
        if result[:settled]
          ledger.forget(id)
          { id: id, plan: plan, snapshot: result[:snapshot] }
        elsif DEAD_INVOICE_STATUSES.include?(result[:status])
          ledger.forget(id)
          nil
        end
      rescue BadRequest
        ledger.forget(id)
        nil
      rescue Error => e
        log(:warn, "checking charge #{id} failed: #{e.message}")
        nil
      end
    end

    # Price list from billing, cached for an hour. nil when billing is down and
    # nothing is cached, or when billing is disabled.
    def plans
      return nil unless enabled?

      cached = @cache.read(key(:plans))
      return cached if cached

      fresh = @client.plans
      @cache.write(key(:plans), fresh, expires_in: PLANS_TTL)
      fresh
    rescue Unavailable, BadRequest, ConfigError => e
      log(:warn, "plans unavailable: #{e.message}")
      nil
    end

    def invalidate(npub)
      @cache.delete(key(:ent, npub))
    end

    private

    def fetch(npub)
      return stale_or_unknown(npub) if down?

      products = @client.entitlement(npub)["products"]
      remember(npub, products)
      snapshot(products, :fresh)
    rescue Unavailable, ConfigError => e
      trip(e)
      stale_or_unknown(npub)
    end

    def remember(npub, products)
      @cache.write(key(:ent, npub), products, expires_in: FRESH_TTL)
      @cache.write(key(:stale, npub), products, expires_in: STALE_TTL)
    end

    def stale_or_unknown(npub)
      stale = @cache.read(key(:stale, npub))
      stale ? snapshot(stale, :stale) : Snapshot.unknown(product, now: @now)
    end

    def down?
      @cache.read(key(:down)) ? true : false
    end

    # A rejected key (ConfigError) is treated like an outage so pages keep
    # rendering, but logged as an error because only the operator can fix it.
    def trip(error)
      log(error.is_a?(ConfigError) ? :error : :warn, "billing unavailable: #{error.message}")
      @cache.write(key(:down), true, expires_in: BREAKER_TTL)
    end

    def snapshot(products, source)
      Snapshot.new(product: product, products: products, source: source, now: @now)
    end

    def key(kind, npub = nil)
      npub ? "#{PREFIX}:#{kind}:#{npub}" : "#{PREFIX}:#{kind}"
    end

    def log(level, message)
      @logger&.public_send(level, "[billing] #{message}")
    end
  end
end
