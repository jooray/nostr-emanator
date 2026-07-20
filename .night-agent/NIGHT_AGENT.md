# Night Agent Operating Policy

## Objective

Audit Emanator, a multi-account Nostr social publishing and scheduling application for people and agents that manage Nostr identities. Protect authentication, account isolation, remote-signing material, scheduled content, and irreversible Nostr publication while making small, reviewable fixes that do not contact external systems or change operational state.

## Project Context

- Product and users: Emanator lets a signed-in Nostr user pair managed accounts, author or AI-refine notes, attach Blossom-hosted media, schedule signed posts and delayed reposts, inspect interactions, and publish to configured and per-user relays. Bearer-authenticated MCP clients can read user data, create drafts, and schedule posts (`README.md`, `config/routes.rb`, `app/services/mcp/tools/schedule_post.rb`).
- Primary flows: NIP-07 or Amber/NIP-46 login; managed-account NIP-46 pairing; profile/relay/interactions synchronization; AI-assisted authoring; remote signing and persistence of future-dated events; periodic Solid Queue publication; Blossom uploads authorized by signed kind-24242 events; MCP token creation and JSON-RPC tool calls (`AGENTS.md`, `config/recurring.yml`, `app/services/nostr/blossom_uploader_service.rb`).
- Architecture: Rails 8.1 server-rendered application with Hotwire/Turbo/Stimulus, ViewComponent, Propshaft, esbuild, and Tailwind CSS; Solid Queue/Cache/Cable; SQLite for development/test and MariaDB/MySQL for production. The browser is a trust boundary for NIP-07 and file input; Rails sessions and MCP bearer tokens authenticate requests; Rails communicates with Nostr relays over WebSockets, Amber remote signers through NIP-46 relays, Venice/OpenAI-compatible APIs over HTTPS, and Blossom servers over HTTPS (`Gemfile`, `package.json`, `config/database.yml`, `app/controllers/application_controller.rb`, `app/controllers/mcp/base_controller.rb`).
- Languages and platforms: Ruby 4.0.1 and JavaScript, HTML/ERB, CSS, YAML, and SQL schema/migrations. Development documentation targets Homebrew Ruby on macOS; CI runs on Ubuntu; the production image targets Linux amd64, while documented production uses AlmaLinux, Puma, Nginx, MariaDB, and in-process Solid Queue (`.ruby-version`, `.node-version`, `.github/workflows/ci.yml`, `Dockerfile`, `AGENTS.md`).
- Sensitive data: Rails master key and encrypted credentials, AI API keys, database password, session cookies, MCP bearer tokens and their digests, Nostr public identities, unpublished content, signed/unsigned events, account `app_privkey`, signer metadata, temporary NIP-46 private keys and secrets, uploaded media, and user/account settings (`.env.example`, `config/deploy.yml`, `db/schema.rb`). The product requirement forbids storing user nsecs server-side (`SPECIFICATION.md`).
- Operational constraints: Nostr events are signed before publication and publication to relays is externally visible and effectively irreversible. Background jobs run every five minutes and may publish due posts. MCP scheduling can enqueue automatic signing without a human confirmation step. Blossom upload may prompt Amber, uploads bytes externally, and can persist server capability state. AI calls transmit prompts/content and consume a secret-backed external API (`README.md`, `config/recurring.yml`, `app/jobs/publish_post_job.rb`, `app/services/ai/client.rb`).
- Supported browser scope: modern browsers only; exact browser/version matrix is Unknown (`app/controllers/application_controller.rb`).
- Automated application test suite: a Minitest suite now exists under `test/`, including controller, model, and Nostr service tests. It is currently untracked worktree content and CI still runs only static security and Ruby style checks (`test/`, `.github/workflows/ci.yml`, `config/ci.rb`).

## Project Commands

Prefix Ruby commands on the documented macOS development environment with:

```bash
export PATH="/opt/homebrew/opt/ruby/bin:/opt/homebrew/lib/ruby/gems/3.4.0/bin:$PATH"
```

Safe unattended checks when dependencies are already present:

```bash
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
yarn audit
```

Asset builds, only when the audit requires them and existing `node_modules` is available:

```bash
yarn build
yarn build:css
```

Repository CI entry point, not approved unattended because its setup step may install dependencies and prepares a database:

```bash
bin/ci
```

Documented local setup and runtime commands, not approved unattended because they install, mutate local state, start servers/workers, or can contact external services:

```bash
bin/setup
bin/rails db:prepare
bin/rails db:migrate
bin/rails console
bin/dev
```

The conventional Rails test command is `bin/rails test`, but the current local bundle could not load because `net-imap-0.6.2` is not installed. Do not install dependencies solely to run unattended checks.

## Audit Priorities

1. Authentication and cryptographic protocol correctness: NIP-07/NIP-46 challenge binding, relay message validation, replay/expiry handling, event validation, key lifecycle, and accidental logging or exposure of `app_privkey`, temporary private keys, auth secrets, signatures, tokens, or credentials.
2. Authorization and tenant isolation: every session, account, post, repost, action, API token, and MCP tool must remain scoped to the owning user; scrutinize API-only MCP endpoints, shallow routes, background jobs, retries, and record lookups.
3. Irreversible external effects: prevent unintended, duplicate, early, stale, or attacker-controlled signing, scheduling, rebroadcasting, media upload, and Nostr publication; verify state transitions, idempotency, concurrency, time handling, relay selection, and failure recovery.
4. Input and output safety: validate relay/Blossom/AI endpoints, uploaded files, JSON-RPC arguments, event JSON, profile/content rendering, URL handling, and SSRF/XSS/CSRF/resource-exhaustion boundaries.
5. Data integrity and privacy: protect drafts, personalities, interaction data, signed events, API usage, uploads, and database migrations; preserve the rule that user nsecs are never stored server-side.
6. Availability and operations: inspect network timeouts, job retries, queue races, synchronous 120-second signing/upload paths, cache refresh fan-out, database differences between SQLite and MariaDB, and PWA cache/version behavior.
7. Dependency, configuration, and maintainability risks after higher-impact security and correctness concerns.

## Constraints

- Use repository evidence only. Do not browse the web, install or update dependencies, modify lockfiles, or assume undocumented commands.
- Default audit work is read-only. Modify files only when an item is explicitly placed in `Approved Work` or `Safe Auto-fix Queue`; initialization itself may modify only this file.
- Never access, print, copy, rotate, decrypt, or alter `.env*`, `config/master.key`, `config/credentials.yml.enc`, `.kamal/secrets`, production environment files, database contents, or live credentials. Treat the tracked `config/master.key` path as highly sensitive even though `.gitignore` ignores `config/*.key` (`.gitignore`).
- Do not start Rails, Solid Queue, or `bin/dev`: authenticated GETs can enqueue refresh work, recurring jobs can publish due posts, and runtime paths contact external relays and APIs (`app/controllers/application_controller.rb`, `config/recurring.yml`).
- Do not invoke controllers, jobs, services, Rails console snippets, or MCP tools that sign, schedule, publish, rebroadcast, synchronize, refresh, upload, call AI, or mutate records. In particular avoid `SignPostJob`, publish/rebroadcast jobs, Nostr actions, NIP-46 services, `EventPublisherService`, `BlossomUploaderService`, fetchers, AI services, and MCP create/schedule tools.
- Do not run `bin/setup`, database prepare/migrate/reset/schema load, seeds, destructive rake tasks, or the full `bin/ci` unattended. SQLite state under `storage/` is local data, not a disposable fixture unless explicitly approved (`bin/setup`, `config/database.yml`).
- Do not deploy, publish artifacts, push branches/tags, create releases, connect by SSH, operate services, or run Kamal/Docker production commands. `git push production main` auto-deploys and migrates/restarts production (`AGENTS.md`); `bin/kamal` aliases can open production shells/consoles and expose database credentials (`config/deploy.yml`).
- `yarn audit` and `bin/bundler-audit` perform advisory/network checks; run only when the audit runner permits network access. `bin/brakeman` and `bin/rubocop` are preferred offline checks with installed dependencies.
- Do not add or change dependencies during unattended audits. Propose dependency updates under `Needs Your Decision` with affected manifests and lockfiles.
- Keep fixes minimal and preserve Rails/Hotwire conventions. Do not add compatibility layers without repository evidence of a shipped compatibility requirement.
- Preserve current unrelated worktree changes. Never revert or overwrite changes outside an approved finding.

## Paths To Avoid

- Generated/build/cache/runtime data: `app/assets/builds/`, `public/assets/`, `node_modules/`, `log/`, `tmp/`, `storage/`, `.bundle/` (`.gitignore`, `package.json`).
- Generated database definitions: `db/schema.rb`, `db/cache_schema.rb`, `db/queue_schema.rb`, and `db/cable_schema.rb`; change migrations only when explicitly approved, then let Rails regenerate schemas (`db/schema.rb`).
- Vendored or generated dependency metadata: `vendor/`, `Gemfile.lock`, and `yarn.lock` unless a dependency change is explicitly approved; `yarn.lock` identifies itself as autogenerated.
- Secrets and deployment state: `.env*`, `config/master.key`, `config/credentials.yml.enc`, `.kamal/`, and production databases or server paths.
- Repository instruction files and product documentation are context, not auto-fix targets, unless an approved item specifically requests documentation changes.

## Approved Work

## Safe Auto-fix Queue

## Needs Your Decision

## Rejected Or Deferred

## Audit Findings

### Design And UX

- **UX-001 (completed): No public product landing preview.** Before product commit `4338c5e`, unauthenticated visitors were sent directly to the Nostr login screen (`root` is authentication-protected and `/auth/nostr` renders `app/views/sessions/new.html.erb`), which explains sign-in mechanics but not the core project-to-established-account repost workflow. The requested self-contained preview now exists at `public/landing-preview.html`; application routing remains unchanged until a later wiring decision.

## Failed Approaches

- Do not validate ordinary HTML with Ruby `REXML`; HTML void elements such as `<meta>` are valid without XML self-closing syntax and produce false parser failures.
- Bundled Ruby validation was unavailable on 2026-07-16 because the local bundle lacked `net-imap-0.6.2`. No dependency installation was attempted.

## Completed Work

- **UX-001:** Added a self-contained, responsive light/dark landing-page preview with an accessible theme toggle, product-specific scheduling/repost visuals, and launch links to `/auth/nostr` (`4338c5e`).

## Decisions

- Emanator is a Rails/Hotwire Nostr scheduling and publishing application with NIP-07/NIP-46 authentication, remote signing, Solid Queue publication, Blossom uploads, AI assistance, and bearer-authenticated MCP automation (`README.md`, `AGENTS.md`).
- Publication, rebroadcast, signing, scheduling, media upload, AI generation, relay synchronization, deployment, and production operations are never safe unattended because they mutate state, contact external systems, consume secrets, or create public effects (`config/routes.rb`, `app/services/nostr/event_publisher_service.rb`, `app/services/nostr/blossom_uploader_service.rb`, `AGENTS.md`).
- The supported CI checks are Brakeman, bundler-audit, and RuboCop; `config/ci.rb` additionally defines `yarn audit`, but `bin/ci` first runs dependency-aware setup and database preparation (`.github/workflows/ci.yml`, `config/ci.rb`, `bin/setup`).
- The exact supported browser matrix remains Unknown (`app/controllers/application_controller.rb`).
- The requested pre-existing `.night-agent/NIGHT_AGENT.md` template was absent from the working tree and tracked files at initialization; therefore only the top-level queue and audit headings explicitly named in the initialization request could be preserved. Original template-only headings are Unknown.
- The landing preview is intentionally a dependency-free static artifact under `public/`; it follows Emanator's amber/neutral palette and operational card language while using a relay/ripple motif to explain coordinated distribution. It does not change the public root route or authenticated application behavior (`public/landing-preview.html`, `app/assets/stylesheets/application.tailwind.css`).
