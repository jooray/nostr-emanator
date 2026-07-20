# Emanator - Claude Code Project Documentation

## Project Overview

**Emanator** is a Nostr post scheduling platform (like Buffer for Nostr). Users log in with their Nostr identity, pair multiple Nostr accounts they manage, and create/schedule posts and reposts across those accounts. Posts are written with AI assistance (personality-aware per account), pre-signed with Amber (NIP-46 remote signer), and published at scheduled times.

## Tech Stack

- **Framework**: Ruby on Rails 8.1 with Hotwire (Turbo + Stimulus)
- **Database**: SQLite3 (development), MariaDB 10.11 (production)
- **CSS**: Tailwind CSS 4.x with dark theme (amber accent)
- **JS Bundling**: esbuild
- **Background Jobs**: Solid Queue
- **Authentication**: Nostr (NIP-07 browser extension + NIP-46 remote signing)
- **AI**: VeniceAI (OpenAI-compatible API) for post writing + humanization
- **Key Gems**: nostr, rqrcode, kaminari, httpx, faye-websocket, bech32, ecdsa, view_component

## Ruby Environment

This project uses Homebrew Ruby. Always prefix commands with the correct PATH:

```bash
export PATH="/opt/homebrew/opt/ruby/bin:/opt/homebrew/lib/ruby/gems/3.4.0/bin:$PATH"
```

## Key Commands

```bash
bin/dev                    # Start development server on port 3001 (Rails + esbuild + Tailwind + Solid Queue)
bin/rails db:migrate       # Run migrations
bin/rails console          # Rails console
yarn build && yarn build:css  # Build assets manually
```

**Port**: Emanator runs on port **3001** (port 3000 is reserved for lievik). The default is set in `bin/dev`. Override with `PORT=3002 bin/dev` if needed.

## Configuration

- `config/emanator.yml` - Nostr relays, AI settings (provider, model, endpoint)
- `.env` - API keys (copy from .env.example)

### AI Configuration

```yaml
# config/emanator.yml
ai:
  provider: venice
  endpoint: https://api.venice.ai/api/v1
  rating_model: grok-41-fast
```

Set `VENICE_API_KEY` in `.env`.

### Blossom Configuration

```yaml
# config/emanator.yml
blossom:
  server: https://blossom.primal.net   # global default media server
```

This is the fallback server for media uploads; each account can override it
(`account.settings["blossom_server"]`). See **Media Attachments** below.

## Database Models

### User
- `npub`, `pubkey_hex` - Nostr identity (login user)
- `settings` - JSON (theme preferences)

### Account
- `user_id` - belongs to User
- `pubkey_hex`, `npub` - The Nostr account being managed
- `personality` - Markdown style guide for AI post writing
- `write_relays` - NIP-65 write relay list
- `signer_pubkey`, `signer_relay`, `app_pubkey`, `app_privkey` - NIP-46 connection
- `settings` - JSON. Holds the per-account `blossom_server` override and the
  cached `blossom_media_unsupported` flag (see **Media Attachments**). Accessed
  via `account.blossom_server` / `blossom_media_supported?` / `mark_media_unsupported!`.

### Post
- `account_id` - The account this post will be published under
- `content` - Post text content
- `status` - draft, awaiting_signature, scheduled, publishing, published, failed
- `scheduled_at`, `published_at` - Scheduling timestamps
- `unsigned_event`, `signed_event` - Nostr event JSON
- `event_kind` - Default 1 (short text note)

### Repost
- `post_id`, `account_id` - Which post is being reposted by which account
- `delay_minutes` - Random delay from post's scheduled_at
- Same status/event fields as Post

### BlossomUpload
- `user_id`, `account_id` - who is uploading, and under which account it is signed
- `status` - pending, signing, uploading, completed, failed; `step` is the
  human-readable progress line the composer polls for
- `filename`, `content_type`, `byte_size`, `file_path` (staged tempfile), `url`, `error`
- Short-lived scratch state for the background media upload. See **Media
  Attachments (Blossom)**.

### NostrAuthSession
- Temporary NIP-46 authentication sessions

### ApiToken
- `user_id` - belongs to User
- `name`, `token_digest` (SHA-256, plaintext shown once), `last_used_at`, `expires_at`
- Bearer credential for the MCP server (`emn_` prefix). See **MCP Server** below.

## Authentication Flow

1. **NIP-07**: Browser extension detects `window.nostr`, signs auth event
2. **NIP-46**: QR code with `nostrconnect://` URI, polls relay for response
3. User auto-created on first login with profile fetched from relays

## NIP-46 Signing Flow

1. User creates post, clicks "Sign & Schedule"
2. App builds unsigned events (post + reposts)
3. Sends sign_event requests via NIP-46 to Amber
4. User approves on phone
5. Signed events stored, status -> scheduled
6. At scheduled time, background job publishes to relays

## Media Attachments (Blossom)

Images/files are attached to posts by uploading them to a [Blossom](https://github.com/hzrd149/blossom)
media server (content-addressed blob storage on Nostr). In the post composer you
can **drag & drop, paste, or click "Attach"**; the file uploads and its URL is
inserted at the cursor (with smart whitespace), and the existing `media-preview`
controller renders a thumbnail.

Flow (browser → Rails → background job → Blossom). Signing is server-side only,
so we proxy — and because a NIP-46 signature can take up to 120 s of waiting for
the user to tap "approve" in Amber, **the upload never runs inside the web
request** (it would pin a Puma thread; 10 threads total):

1. `blossom_upload_controller.js` POSTs the file (multipart) to
   `POST /accounts/:account_id/blossom_uploads` (`BlossomUploadsController#create`).
2. The controller validates it (**25 MB cap**, content-type allowlist of
   `image/*`, `video/*`, `audio/*`, `application/pdf`; per-user `rate_limit` of
   20/min), streams the bytes to `tmp/blossom_uploads/`, creates a
   **`BlossomUpload`** row and enqueues **`BlossomUploadJob`** (queue `:default`).
   It answers **202** with `{ id, status, step, status_url }`.
3. `BlossomUploadJob` runs `Nostr::BlossomUploaderService`, which hashes the file
   with a streaming read (never buffered in memory), builds a **kind-24242** auth
   event (`["t", verb]`, `["x", sha256]`, `["expiration", …]`), signs it via
   `EventSignerService#request_signature` (NIP-46/Amber), then PUTs the file as an
   IO body with `Authorization: Nostr <base64(signed event)>`.
4. Each step writes a human-readable `step` onto the row
   ("Approve the upload in your signer app (1 of 2)…", "Uploading to the media
   server…"); the job finishes with `completed` + `url` or `failed` + `error`.
5. The JS polls `GET /blossom_uploads/:id` (`#show`) once a second, shows the
   `step`, and on `completed` inserts the URL at the caret position saved when the
   upload started. **Submit buttons on the composer form are disabled while any
   upload is in flight**, so the draft can't be saved without its media URL.

Multi-file uploads run **concurrently and independently**: one failure no longer
drops the remaining files — each file reports its own error in the status line.
Rows and their staged files are swept after `BlossomUpload::RETENTION` (6 h), and
a row whose job vanished is failed after `STUCK_AFTER` (6 min) so the browser
never polls forever.

**Endpoint selection**: images/video use the BUD-05 `/media` endpoint (strips
EXIF/GPS) when the server has it. Before spending a signature, an
*unauthenticated* `HEAD /media` probe rules out servers that don't route it at
all (404/405/501) — those are cached via `mark_media_unsupported!` and go
straight to `/upload`. If `/media` still fails server-side after signing, it
falls back to BUD-02 `/upload` and caches that too, so the double Amber prompt
happens at most once per server. Signing failures (`SigningError`) fail fast
without falling back. Non-media (PDF, etc.) goes straight to `/upload`.
**Note**: `blossom.primal.net` (the default) does **not** implement `/media` — it
rejects `t=media` with `HTTP 401 invalid action` — so uploads there use `/upload`
and keep file metadata.

Per-account server is set in **account edit → Blossom media server**; blank uses
the global `blossom.server` default.

## Key Services

- `Nostr::AuthService` - NIP-46 auth, user creation
- `Nostr::ProfileFetcher` - Fetch kind 0 profiles from relays
- `Nostr::EventFetcher` - Fetch kind 1 events from relays
- `Nostr::RelayListFetcher` - Fetch kind 10002 relay lists
- `Nostr::EventSignerService` - Build unsigned events, NIP-46 signing
- `Nostr::EventPublisherService` - Publish signed events to relays
- `Nostr::BlossomUploaderService` - Upload media to a Blossom server (see below)
- `Ai::Client` - OpenAI-compatible API client (Venice/OpenAI)
- `Ai::PostWriterService` - Generate, refine, humanize posts
- `Ai::SkillLoader` - Load SKILL.md prompt files
- `Scheduling::SchedulerService` - Smart scheduling suggestions
- `Scheduling::RepostSchedulerService` - Schedule reposts with random delays

## MCP Server (Model Context Protocol)

Lets an AI agent read the user's accounts/posts and draft & schedule posts on
their behalf. JSON-RPC 2.0 over HTTP at `POST /mcp`, authenticated with a bearer
API token (`Authorization: Bearer emn_…`). Mirrors lievik's MCP architecture.

- **Endpoint**: `Mcp::ServerController#handle` (`config/routes.rb`: `post "/mcp"`).
  Handles `initialize`, `tools/list`, `tools/call`, `ping`. `ActionController::API`
  (no CSRF, no session).
- **Auth**: `Mcp::BaseController` reads the bearer token; `ApiToken.authenticate`
  matches the SHA-256 digest and returns the owning `User`. Tokens are created/
  revoked in **Settings → API Tokens (MCP)** (`ApiTokensController`,
  `app/views/users/_api_tokens.html.erb`). The plaintext token is shown once.
- **Tools** (`app/services/mcp/tools/`, all scoped to the token's user):
  - `list_accounts` - accounts with personality, relays, signer status, post counts
  - `list_posts` - filter by account/status/`upcoming` window; reposts included
  - `get_post` - one post with full detail + reposts
  - `search_posts` - substring search over content
  - `suggest_schedule_slot` - next free slot via `SchedulerService`
  - `create_draft_post` - create a draft (no signing/publishing)
  - `schedule_post` - sign & schedule a draft so it publishes automatically

### Automatic scheduling

`schedule_post` replicates `PostsController#sign`: it builds the unsigned event,
sets `scheduled_at`, optionally creates reposts, and enqueues `SignPostJob`.
**Amber signs kind-1 notes without manual confirmation**, so the post moves
`draft → awaiting_signature → scheduled` on its own and is published at its
scheduled time by `EnqueueScheduledPostsJob` — no human step required. The
account must have a paired signer (`account.has_signer?`); otherwise the tool
returns an error. Drafts created via `create_draft_post` can be scheduled in a
second step with `schedule_post`.

## Production Deployment

**Domain**: https://emanator.cypherpunk.today (port 3001)
**Server**: jl.bednar.io (AlmaLinux 10.1), user `nostr-tools`
**Full docs**: `~/projects/lievik-emanator-server/deployment-lievik-emanator.md`

### Deploy

```bash
git push production main    # triggers auto-deploy via post-receive hook
```

The post-receive hook runs: `bundle install` → `yarn install` → `assets:precompile` → `db:migrate` → `systemctl --user restart emanator`

### Two pushes: deploy vs. publish

There are **two separate pushes**:

- **`git push production main`** — deploys to the live server (do this whenever a
  change is ready to run in production).
- **`git push origin main`** — publishes the source to the public GitHub repo
  (https://github.com/jooray/nostr-emanator).

These are independent. Deploying does **not** publish to GitHub, and vice versa.
Use judgement on when to publish: push to GitHub after a complete, tested feature
(not for every WIP commit) — but do it from time to time so the public repo does
not drift far behind production.

### SSH Access

```bash
ssh nostr-tools@jl.bednar.io
```

### Service Management

```bash
# On server as nostr-tools:
systemctl --user status emanator
systemctl --user restart emanator
journalctl --user -u emanator -f          # follow logs
journalctl --user -u emanator -n 100      # last 100 lines
```

### Production Stack

- **Ruby 4.0** via rbenv, **Node 25** via fnm
- **MariaDB 10.11** — 4 databases: `emanator_production`, `emanator_queue`, `emanator_cable`, `emanator_cache`
- **Puma** with 10 threads, **Solid Queue** runs in-process (`SOLID_QUEUE_IN_PUMA=true`)
- **Nginx** reverse proxy with SSL (SAN cert at `/etc/letsencrypt/live/mnam.io/`)
- Environment variables in `~/apps/nostr-emanator/.env` (loaded by systemd `EnvironmentFile`)

### Required environment variables

Beyond `VENICE_API_KEY`, the server needs the ActiveRecord encryption keys —
`app_privkey` (Account) and `temp_privkey`/`secret` (NostrAuthSession) are
encrypted at rest, so **without these keys every login, pairing and signing call
raises**:

```
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=…
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=…
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=…
```

Generate with `ruby -rsecurerandom -e '3.times { puts SecureRandom.alphanumeric(32) }'`
and put them in `~/apps/nostr-emanator/.env` **before** deploying. Rows written
before encryption was introduced are migrated with `bin/rails
encryption:encrypt_existing_data` (idempotent, safe to re-run).

### Operational constraints

- **`WEB_CONCURRENCY` must stay 0.** Solid Queue runs in-process and the NIP-46
  supervisor is a singleton; a second Puma worker would double-enqueue the
  recurring jobs.
- **Deploy order is `assets → db:migrate → restart`**, so old code briefly runs
  against the new schema. Keep migrations additive (add columns/indexes, never
  rename or drop in the same deploy as the code that stops using them).
- **Restarting during signing** kills jobs waiting on Amber; Solid Queue retries
  them, so the user may see a second approval prompt. Harmless, but prefer to
  deploy when nothing is mid-signature.
- **No automated DB backups live in this repo.** MariaDB dumps are the operator's
  responsibility — worth a cron on the server before relying on migrations.
- `lib/tasks/migrate_sqlite.rake` is a one-shot import (plain INSERTs); re-running
  it double-inserts.

### Git Remotes

```bash
# One-time setup:
git remote add production nostr-tools@jl.bednar.io:repos/nostr-emanator.git
git remote add origin https://github.com/jooray/nostr-emanator.git
```

`origin` = public GitHub repo (source publishing), `production` = server bare repo
(deploy). See **Two pushes: deploy vs. publish** above.
