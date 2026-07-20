A Ruby on Rails application for authoring and publishing Nostr events (notes) under multiple accounts —
a social media scheduling platform, similar to what Buffer used to be, but focused on Nostr.

## Core idea

A user manages several Nostr accounts (their own and/or ones they run on behalf of a project) and can
write, schedule, and cross-post notes across them. Example use case: write several posts in advance for
a project account, then repost each one under a personal (or related) account with a random delay —
check a box, get a random delay up to 24h. Events are pre-built and pre-signed with the correct future
timestamp, stored, and published automatically when their scheduled time arrives.

## Identity and signing

- **Sign-in** is Nostr-only: NIP-07 (browser extension) or a `nostrconnect://` QR scanned with
  [Amber](https://github.com/greenart7c3/Amber) (NIP-46). No passwords, no separate user management.
- **Account pairing** is a distinct step from sign-in: once logged in, a user pairs any number of Nostr
  accounts via NIP-46 remote signing. Sign-in identity and posting accounts are independent — a user's
  own login npub is just one of the accounts they can pair and post as.
- **No nsec ever touches the server.** All signing — post events, repost events, and Blossom upload auth
  events — goes through Amber over NIP-46. The server only ever holds public keys and the ephemeral
  NIP-46 app keypair used to talk to the signer.
- Publishing respects each account's NIP-65 write relays (fetched and cached), plus the app's configured
  default relays, deduplicated.

## AI-assisted writing

Each account has a freeform Markdown **personality** file describing its voice, language, and style,
which is included in the AI prompt when drafting for that account — the Nostr equivalent of lievik's
per-channel templates. Posts can be AI-generated from a prompt, refined in place, and run through a
**humanizer** skill (shared with lievik, another social-media management project) that strips
telltale AI-writing patterns before scheduling.

## Scheduling

- The composer suggests a slot based on the account's existing schedule: if nothing conflicts, it
  proposes a sensible default gap after the last scheduled post; if the next couple of slots are
  already taken, it offers the first free day or the day after the last scheduled item, and always
  allows a fully custom date/time.
- **Reposts**: any other paired account can be checked to repost the same content, each with its own
  random delay (default: up to 24h) after the original's scheduled time, pre-signed the same way as the
  original post.
- A background job publishes each post/repost to its relays once its scheduled time arrives — no human
  step required after signing.

## Media

Images and files can be attached in the composer (drag & drop, paste, or an Attach button). They upload
to a [Blossom](https://github.com/hzrd149/blossom) media server, authorized by a signed kind-24242 event
(so uploads are still gated by the posting account's signer, not a server-held secret), and the
resulting URL is inserted into the post.

## Automation (MCP)

Beyond the web UI, Emanator exposes an [MCP](https://modelcontextprotocol.io) server so an AI agent can
read a user's accounts and posts and draft/schedule on their behalf over a bearer-token-authenticated
JSON-RPC endpoint. Because Amber signs kind-1 notes without manual confirmation, an agent can draft and
schedule a post in one turn with no human approval step in the loop — see the README for the tool list
and setup.

## Relationship to lievik

Emanator and lievik are sibling social-media management projects — lievik's Amber sign-in, AI
content-creation interface, and humanizer skill were the starting point for Emanator's equivalents,
adapted for Nostr's account/relay/signing model instead of arbitrary channels.
