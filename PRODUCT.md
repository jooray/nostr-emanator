# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

The primary user is a **Nostr power user running several identities at once** —
their own npub plus one or more project/brand accounts they operate. They are
already fluent in the protocol: Amber, NIP-46 pairing, npubs, relay lists, event
kinds. Jargon is not a barrier; density and speed beat hand-holding.

Ownership is single-operator: an `Account` belongs to one login `User`, and there
is no team, seat, or shared-workspace model. A second person managing the same
brand account pairs it under their own login.

## Product Purpose

Emanator writes, schedules, and publishes Nostr notes across every account a
person manages — "Buffer for Nostr". A post is composed (optionally with
AI assistance tuned to that account's personality), pre-signed by the user's own
signer, stored as a finished signed event, and published to the account's relays
by a background job when its scheduled time arrives. Reposts of the same content
can be pre-signed under other paired accounts with random delays.

**Success is reliable personal infrastructure**: it posts what was scheduled,
every time, without the operator thinking about it. Unattended correctness
outranks reach, growth, and acquisition.

## Positioning

Every hosted scheduler for other networks holds a credential that can post as
you. Emanator does not: **the server never holds an nsec.** Events are signed
ahead of time by the user's own Amber over NIP-46 and stored already-signed, so
publishing is only relaying bytes the user personally authorized. The server
holds public keys and an ephemeral NIP-46 app keypair, nothing more.

Around that spine sit things a generic scheduler cannot copy: per-account
personality files that steer AI drafting, cross-account reposts with randomized
delays, Blossom media uploads authorized by the posting account's own signature,
a NIP-17 private inbox spanning every paired account, and an MCP endpoint that
lets an agent draft and schedule end-to-end.

## Operating Context

- **Two devices, always.** Composing happens in a browser; approving happens on
  the phone where Amber lives. A signature round trip can take up to 120 s of
  waiting for a human to tap. *Waiting on a person is a normal state, not an
  error* — every signing surface must say what is being asked and where.
- **Nobody is present at publish time.** Posts go out from a background job,
  hours or days after they were written. The future schedule has to stay
  inspectable and repairable while it is still in the future.
- **Relays are not uniform infrastructure.** Each account carries its own NIP-65
  write/read relays and NIP-17 DM relays; delivery is best-effort and partial
  success is routine. So is a media server that lacks an endpoint, or a signer
  whose permissions are out of date.
- **Installed on a phone.** The app is used as an installed PWA as well as in a
  desktop browser.
- **Pairing is a distinct ritual** from sign-in: a `nostrconnect://` QR scanned
  with Amber, repeated as re-pairing when the permission set changes.
- Existing surfaces: public landing, dashboard, accounts (+ settings, recent
  events, interactions), post composer / schedule / posts list, calendar,
  interactions feed, messages inbox, user settings with API tokens.

## Capabilities and Constraints

**Durable, user-confirmed constraints**

- **No nsec ever reaches the server.** All signing — posts, reposts, Blossom
  upload auth, DM encryption — goes through NIP-07 or NIP-46/Amber. No design
  may route around the signer.
- **Must keep working as an installed PWA on a phone**, including the
  auto-refresh-to-new-version behaviour (never require a manual hard refresh).

**Confirmed product facts**

- Sign-in is Nostr-only: NIP-07 extension or NIP-46 QR. No passwords, no email,
  no account recovery to design for.
- Post lifecycle is user-visible truth: `draft → awaiting_signature → scheduled
  → publishing → published | failed`, with retry/rebroadcast/cancel/reschedule
  as first-class actions.
- Reposts carry a per-account random delay (default up to 24 h) from the
  original's scheduled time.
- AI drafting/refining/humanizing runs against an OpenAI-compatible provider
  (VeniceAI) using the account's Markdown personality file.
- Media attaches via a Blossom server (per-account override of a global
  default); uploads are asynchronous and can need their own signer approval.
- Private messaging is NIP-17 across all paired accounts, with an acknowledged
  legacy NIP-04 downgrade path and a Known/Requests spam split. Message bodies
  are encrypted at rest and therefore **not searchable in SQL**. Kind-15 file
  attachments are read-only. There are deliberately **no MCP messaging tools**.
- An MCP server (bearer `emn_` tokens) exposes read tools plus draft and
  schedule; because Amber signs kind-1 notes without manual confirmation, an
  agent can schedule with no human in the loop.
- Per-user theme preference exists (`system` / `light` / `dark`).
- Single locale: `config/locales/en.yml`, English only. Whether other languages
  are ever supported is **undecided** — do not assume either way.
- No analytics, telemetry, or tracking provider is wired into the app source
  (verified against the common providers). Nothing is free, hosted, or billed:
  there is no payment or plan system at all.
- Production runs one Puma worker with Solid Queue in-process (`WEB_CONCURRENCY`
  must stay 0), so heavy synchronous work in a request is a real constraint.

## Brand Commitments

- **Name**: Emanator. Live instance at `emanator.cypherpunk.today`. Icon assets
  at `public/icon.svg` and `public/icon.png`.
- **Voice** (inferred from README, SPECIFICATION.md and in-app copy, not yet
  confirmed): plain, technical, unhyped; explains mechanism rather than
  benefits; comfortable naming protocol details.
- The current dark-first app theme with the amber accent (`#d97706`), and the
  landing page's separate warm-paper light/dark world, are the **incumbent**
  look. They were **explicitly not pinned as binding** — treat them as evidence
  of where the product stands today, not as a commitment future work must keep.

## Evidence on Hand

- A running public instance: `emanator.cypherpunk.today`.
- Public source: `github.com/jooray/nostr-emanator` (squashed public lineage).
- Product screenshots already captured for the landing page in
  `public/landing/shots/` — dashboard, calendar, interactions, new post and
  schedule, desktop plus mobile light/dark.
- Written product truth: `README.md`, `SPECIFICATION.md`, `CLAUDE.md`,
  `AGENTS.md`.
- **Absent, and must never be invented**: testimonials, named customers, user
  counts, uptime or delivery benchmarks, pricing, funding, press, awards, or any
  claim of scale. None exist.

## Product Principles

1. **The signer is the boundary.** Anything touching a key goes to the user's
   own Amber. Design around the wait; never design around the key.
2. **Unattended correctness first.** The product does its real work when nobody
   is watching — a surface earns its place by making the scheduled future
   inspectable, verifiable, and repairable before it fires.
3. **Speak protocol truth to protocol people.** Relays, kinds, npubs, signer
   permissions: name them plainly. This audience knows them, and abstracting
   them away hides the failure modes that actually occur.
4. **Partial success is the normal case.** Relay publishing, DM reach, and media
   uploads all succeed unevenly. Report what actually happened rather than a
   binary result.
5. **Many identities, one operator.** Every surface spans accounts, so whose
   identity an action runs under must be unmistakable at a glance — posting as
   the wrong account is the expensive, unrecoverable mistake.
