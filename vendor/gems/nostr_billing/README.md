# nostr_billing (Ruby client)

Client for the nostr-billing service, shared by Lievik and Emanator. Standard
library only.

Billing is optional. Without `BILLING_API_URL` the gate is disabled: every
check allows, nothing calls out, and the apps hide their billing UI. That is
how a self-hosted install runs, from the same code as the hosted one.

## Use

```ruby
gate = NostrBilling.from_env(product: "emanator-ai", cache: Rails.cache, logger: Rails.logger)

snap = gate.status(user.npub)      # Snapshot: state "active"|"trial"|"expired"|"none"|"unknown"
snap.allows?                       # paid features allowed?
gate.activate(user.npub)           # starts the trial if the npub never had this product
gate.consume(user.npub, kind: "generate", units: 2, key: "...")  # :allowed, :capped, :not_entitled, :unavailable
gate.create_charge(user.npub, plan: "all-access", redirect_url: "...")
gate.charge(user.npub, invoice_id) # { settled:, status:, snapshot: }
gate.plans                         # price list from billing, cached for an hour
```

`NostrBilling::ChargeLedger.new(session)` remembers which charges a browser
session created, so only those can be polled and their checkout link survives
a reload.

Always pass the login npub (`users.npub`), never an account or channel npub.

## Outage policy

- Answers are cached for 60 s, and the last good answer for 24 h.
- When billing is down (timeout, 5xx, 429, rejected key), the gate uses the
  last good answer, re-checked against its own `until`. With nothing cached the
  state is `unknown` and paid features are denied; free features never depend
  on billing.
- A failure opens a 15 s circuit breaker, so a dead billing service costs one
  timeout, not one per request.
- `consume` during an outage allows only an npub last seen as paid.

## Tests

```
ruby -Ilib -e 'Dir["test/*_test.rb"].each { |f| require_relative f }'
```

The apps' tests use `NostrBilling::MockClient`, which follows the service's
rules (one trial per npub and product, all-access grants all three, consume
refuses without entitlement) and settles charges on demand with `settle!`.

## Vendored copies

Lievik and Emanator carry a copy in `vendor/gems/nostr_billing`, referenced
with `gem "nostr_billing", path: "vendor/gems/nostr_billing"`, so they build
from their own repositories. Edit the code here, then run
`clients/ruby/sync.sh` to copy it into both apps. Do not edit the copies.
