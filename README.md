# Emanator

A Nostr post scheduling platform — think Buffer for Nostr. Log in with your
Nostr identity, pair the accounts you manage, and write, schedule, and cross-post
notes across them. Posts are written with AI assistance (personality-aware per
account), signed with [Amber](https://github.com/greenart7c3/Amber) over NIP-46,
and published at their scheduled time.

## Try it

A live instance runs at [emanator.cypherpunk.today](https://emanator.cypherpunk.today) — no install
needed. Sign in with any Nostr identity (NIP-07 extension or Amber/NIP-46 QR) to get an account.

## Tech stack

- **Rails 8.1** with Hotwire (Turbo + Stimulus)
- **SQLite** (development) / **MariaDB** (production)
- **Tailwind CSS 4** (dark theme, amber accent), bundled with esbuild
- **Solid Queue** for background jobs
- **Auth**: Nostr NIP-07 (browser extension) + NIP-46 (Amber remote signer)
- **AI**: VeniceAI (OpenAI-compatible) for writing and humanizing posts

## Getting started

Requires Ruby (Homebrew) and Node. On macOS:

```bash
export PATH="/opt/homebrew/opt/ruby/bin:/opt/homebrew/lib/ruby/gems/3.4.0/bin:$PATH"

bundle install
yarn install
cp .env.example .env          # set VENICE_API_KEY
bin/rails db:prepare
bin/dev                       # http://localhost:3001
```

Emanator runs on port **3001** (3000 is reserved for lievik). Override with
`PORT=3002 bin/dev`.

## Configuration

- `config/emanator.yml` — Nostr relays (incl. NIP-46 `auth_relays`), AI
  settings (provider, endpoint, model), and the default `blossom.server` for
  media uploads (per-account override in account settings).
- `.env` — API keys (see `.env.example`).

## How it works

1. **Log in** with NIP-07 or by scanning a `nostrconnect://` QR with Amber (NIP-46).
2. **Pair accounts** you manage; each gets a personality style guide for AI writing.
3. **Write & schedule** posts (and reposts at random delays across accounts).
4. **Attach media** by drag & drop, paste, or the Attach button — files upload to
   a [Blossom](https://github.com/hzrd149/blossom) server (default Primal), signed
   by the posting account, and the URL is inserted into the post.
5. **Sign** the events with Amber over NIP-46; signed events are stored.
6. A background job **publishes** each post to its relays at the scheduled time.

## MCP server (Model Context Protocol)

Emanator exposes an [MCP](https://modelcontextprotocol.io) server so an AI agent
can read your accounts and posts and draft/schedule on your behalf. It is a
JSON-RPC 2.0 endpoint at `POST /mcp`, authenticated with a bearer **API token**.

### Creating a token

Go to **Settings → API Tokens (MCP)**, name a token, and copy it (shown once).
Tokens carry an `emn_` prefix and are stored only as a SHA-256 digest. Revoke
anytime from the same screen.

### Connecting

Point your MCP client at the endpoint and send the token as a bearer header:

```
POST https://emanator.cypherpunk.today/mcp
Authorization: Bearer emn_xxxxxxxx…
Content-Type: application/json
```

Example MCP client config:

```json
{
  "mcpServers": {
    "emanator": {
      "url": "https://emanator.cypherpunk.today/mcp",
      "headers": { "Authorization": "Bearer emn_xxxxxxxx…" }
    }
  }
}
```

### Tools

All tools are scoped to the token owner's data.

| Tool | Purpose |
|------|---------|
| `list_accounts` | Accounts you manage, with personality, write relays, signer status, and post counts — the "who posts what" map |
| `list_posts` | Posts, filterable by account, status, and an `upcoming` (future scheduled) window; includes reposts |
| `get_post` | One post in full detail, with its reposts |
| `search_posts` | Substring search over post content |
| `suggest_schedule_slot` | Next free posting slot for an account |
| `create_draft_post` | Create a draft (no signing or publishing) |
| `schedule_post` | Sign & schedule a draft so it publishes automatically |

### Automatic scheduling

**Amber signs kind-1 notes without manual confirmation**, so scheduling can be
fully automatic. `schedule_post` builds the Nostr event, sets the time,
optionally adds reposts, and enqueues background signing. The post moves
`draft → awaiting_signature → scheduled` on its own and is published at its
scheduled time — no human step in the loop. The account must have a paired Amber
signer; without one the tool returns an error. You can draft and schedule in one
agent turn (`create_draft_post` then `schedule_post`) or schedule existing drafts.

## Deployment

`git push production main` triggers the auto-deploy hook
(`bundle install` → `yarn install` → `assets:precompile` → `db:migrate` →
restart). Production runs at https://emanator.cypherpunk.today. See `CLAUDE.md`
for server details.
