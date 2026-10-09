# frozen_string_literal: true

module NostrBilling
  # Remembers the charges a browser session created. Billing does not
  # authenticate users and GET /v1/charges/:id does not return the checkout URL,
  # so the app keeps both here: only a charge this session made can be polled
  # or shown, and the checkout link survives a page reload.
  #
  # `store` is anything hash-like that persists per user, normally the Rails
  # session. Entries are kept small (a session cookie holds 4 KB).
  class ChargeLedger
    SESSION_KEY = "nostr_billing_charges"
    LIMIT = 5
    MAX_AGE = 24 * 3600

    def initialize(store, now: -> { Time.now.to_i })
      @store = store
      @now = now
    end

    def remember(invoice_id, checkout_url:, plan:)
      entries = fresh_entries
      entries[invoice_id.to_s] = { "url" => checkout_url.to_s, "plan" => plan.to_s, "at" => @now.call }
      @store[SESSION_KEY] = entries.sort_by { |_, e| -e["at"].to_i }.first(LIMIT).to_h
    end

    # Newest first.
    def ids
      fresh_entries.sort_by { |_, e| -e["at"].to_i }.map(&:first)
    end

    def owns?(invoice_id)
      fresh_entries.key?(invoice_id.to_s)
    end

    def checkout_url(invoice_id)
      fresh_entries.dig(invoice_id.to_s, "url")
    end

    def plan(invoice_id)
      fresh_entries.dig(invoice_id.to_s, "plan")
    end

    def forget(invoice_id)
      entries = fresh_entries
      entries.delete(invoice_id.to_s)
      @store[SESSION_KEY] = entries
    end

    private

    def fresh_entries
      raw = @store[SESSION_KEY]
      return {} unless raw.is_a?(Hash)

      raw.to_h { |k, v| [k.to_s, v.to_h.transform_keys(&:to_s)] }
         .select { |_, e| e["at"].to_i > @now.call - MAX_AGE }
    end
  end
end
