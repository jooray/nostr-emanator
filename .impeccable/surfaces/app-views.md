---
version: 1
slug: "app-views"
primary_target: "app/views"
related_targets: []
---

---
version: 1
slug: "app-views"
primary_target: "app/views"
related_targets: []
---

---
version: 1
slug: "app-views"
primary_target: "app/views"
related_targets: ["app/views/dashboard/index.html.erb","app/views/layouts/_navigation.html.erb","app/views/posts","app/assets/stylesheets/application.tailwind.css"]
---

Scope: the signed-in Emanator application UI (every route behind login). Visitor mode: Operate.
Audience: a protocol-fluent operator running ~19 Nostr identities, composing at a desk, approving on a phone, checking later whether things actually went out.
Task: know what went wrong unattended, what is waiting on a human right now, and what goes out next — and act on each without leaving the row.
Constraints: no nsec ever server-side; must keep working as an installed PWA with auto-refresh; per-user system/light/dark preference must survive.

## Direction contract

THESIS: Emanator is a control console for events its operator already signed. It refuses the stat-card dashboard and the category's counter-row-then-table arrangement: the first screen is the press run — what is held, what needs a human, what went short — never four vanity numbers. Publishing to N relays is a poll of N stations, so a partial answer is the normal answer and is never rendered as an unqualified green tick. Nominal states do not illuminate; only an exception carries colour.

OWN-WORLD: A warm graphite chassis (#211F1C) with the working field as a lighter panel face (#2E2B27) set into it, seam #171512. Structure is hairline rule (#403B34) and engraved legend, never cards, never rounded containers, never drop shadows. Legends are Barlow Condensed caps in bone (#B7AEA1), cut in with a dark shadow above and a light lip below. Lamps are the only lit elements: a recessed well (#413C35) reads as off, bone (#CFC7BB) as nominal, signal red (#D93B1E) as a short pull, orange amber (#F0A017) as "a human must tap". Those two are the entire chromatic system — colour appears only where an action or an alarm lives. Identity is an industrial wire-marker rule whose hue derives from the account's pubkey, so it can never reshuffle. Type: Barlow Condensed engraved caps for legend and identity, Barlow for prose, JetBrains Mono tabular for times, tallies, npubs, event ids and relay results. All three self-hosted; font-src is :self.

STORY: The operator opens the app and learns in one viewport whether anything went wrong while they slept, what is waiting on their phone, and what goes out next. They understand that a published note may have reached only some relays, and that the app will tell them which. They act from the row — retry, rebroadcast, approve, reschedule — without navigating away.

FIRST VIEWPORT: No counters. A left chassis rail carries the seven routes as engraved caps with an unlit indicator per item, and a station-status lamp bank pinned to its foot (identities, awaiting signature, short pulls, failed). The field opens on an engraved kicker-free header — "PRESS RUN · NEXT 24 HOURS" as a legend plate above "34 HELD" in Barlow Condensed at display scale — with a red-ruled alarm block top right carrying the count of posts that reached fewer relays than they were sent to, present only when that count is non-zero. Beneath it, the press run as rules-separated rows: release hour in tabular mono at 23px with its day label engraved under it, the account's wire rule and chop, two lines of the note, and at the right end either a poll strip of per-relay lamps with its tally, or a status slug. The awaiting-signature row is the only amber thing on screen and carries its elapsed counter and the identity being asked.

FORM: The Console — mission-control station-by-station GO/NO-GO polling. Candidate 3 of my ordered grounded list; reached via the safer-register re-roll (round 1) where the assignment was suspended and the user picked outright. Seed key 026c156a. Palette settled with the user as annunciator semantics on a warm lighter chassis, after the first rendition was rejected as reading AI-generated (mint/coral/gold semantic trio).

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Rejected, and why it stays rejected

The first rendition of this direction was **mint #7BE0A0 / coral #E04B3C / gold
#E8B84B on a grey-green ground** — effectively Tailwind's emerald/red/amber
semantic trio on a dark dashboard. The user rejected it in those words: "it
looks very AI generated". That palette is the category's default status-colour
set, it has nothing to do with annunciator hardware, and reaching for it again
would reproduce exactly the complaint this whole build answers.

Two rules follow, and they outlive this session:

- **Nominal does not illuminate.** A lamp is dark until something is wrong. Green
  for "fine" is forbidden; it is why the green/emerald/indigo/blue ramps are
  remapped to the neutral scale at token level rather than left available.
- **Amber and red are reserved.** Amber means a human must tap something; red
  means something did not land. Nothing else in the product may wear either —
  not identity inks, not avatars, not decoration.

Also rejected: a light "painted panel grey" chassis, attempted as a token swap
and abandoned because converting a dark-designed layout that way produces a
muddy, low-contrast result.

**The light theme is settled and approved.** It is a warm stock ground
(#efebe4) with the same engraved legend, lamps and rules as the dark chassis —
ink on paper rather than a lit panel. The user approved it in those terms ("the
cream is nice") after being told it sits close to the landing page's warm-paper
world they rejected for the app. That closeness is accepted deliberately: the
dark chassis is the primary identity and the light end is its printed twin, not
a second world.

## Contract amendment

FIRST VIEWPORT specifies an engraved "PRESS RUN · NEXT 24 HOURS" legend plate
above the heading. That is a kicker, which the craft floor bans outright and no
brief earns back. The plate is not built; the heading carries itself and the
scope line sits below it. The FIRST VIEWPORT block is amended accordingly rather
than the ban being overridden.
