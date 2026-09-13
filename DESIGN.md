---
name: Emanator Console
description: A warm-graphite control console for Nostr events the operator already signed — nominal states stay dark, only an exception carries colour.
colors:
  chassis: "#211f1c"
  panel: "#2e2b27"
  panel-hi: "#353128"
  seam: "#171512"
  well: "#413c35"
  rule-dark: "#403b34"
  bone: "#cfc7bb"
  legend: "#c4bbac"
  warm-stock: "#efebe4"
  paper-white: "#faf7f2"
  neutral-100: "#e4dfd6"
  neutral-200: "#d3ccc1"
  neutral-300: "#bbb3a6"
  neutral-400: "#a49b8c"
  neutral-500: "#6e665a"
  neutral-600: "#554e44"
  neutral-700: "#383430"
  ink-dark: "#ede8e0"
  contact-black: "#1a1714"
  amber-signal: "#f0a017"
  amber-lift: "#f5b950"
  amber-deep: "#d98a0c"
  amber-ink: "#b8720a"
  red-signal: "#d93b1e"
  red-lift: "#e8614a"
  red-deep: "#c22f14"
  red-ink: "#a02610"
typography:
  display:
    fontFamily: "Barlow Condensed, Barlow, ui-sans-serif, system-ui, sans-serif"
    fontSize: "38px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "0.06em"
  headline:
    fontFamily: "Barlow Condensed, Barlow, ui-sans-serif, system-ui, sans-serif"
    fontSize: "33px"
    fontWeight: 700
    lineHeight: 1.05
    letterSpacing: "0.06em"
  title:
    fontFamily: "Barlow Condensed, Barlow, ui-sans-serif, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "0.1em"
  body:
    fontFamily: "Barlow, ui-sans-serif, system-ui, -apple-system, sans-serif"
    fontSize: "17px"
    fontWeight: 400
    lineHeight: 1.6
    letterSpacing: "normal"
  body-dense:
    fontFamily: "Barlow, ui-sans-serif, system-ui, -apple-system, sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.55
    letterSpacing: "normal"
  label:
    fontFamily: "Barlow Condensed, Barlow, ui-sans-serif, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: "0.16em"
  slug:
    fontFamily: "Barlow Condensed, Barlow, ui-sans-serif, system-ui, sans-serif"
    fontSize: "11.5px"
    fontWeight: 600
    lineHeight: 1
    letterSpacing: "0.18em"
  hour:
    fontFamily: "JetBrains Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "25px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "-0.02em"
    fontFeature: "tabular-nums"
  readout:
    fontFamily: "JetBrains Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "15px"
    fontWeight: 700
    lineHeight: 1.3
    letterSpacing: "normal"
    fontFeature: "tabular-nums"
rounded:
  none: "0px"
  lamp: "2px"
  focus: "1px"
  full: "9999px"
spacing:
  hair: "3px"
  tight: "6px"
  snug: "10px"
  row: "14px"
  panel: "16px"
  section: "28px"
components:
  button-primary:
    backgroundColor: "{colors.amber-signal}"
    textColor: "{colors.contact-black}"
    typography: "{typography.slug}"
    rounded: "{rounded.none}"
    padding: "10px 16px"
  button-primary-hover:
    backgroundColor: "{colors.amber-lift}"
    textColor: "{colors.contact-black}"
  button-slug:
    backgroundColor: "transparent"
    textColor: "{colors.neutral-500}"
    typography: "{typography.slug}"
    rounded: "{rounded.none}"
    padding: "5px 8px"
  button-slug-hover:
    textColor: "{colors.amber-deep}"
  slug-wait:
    backgroundColor: "rgba(240, 160, 23, 0.09)"
    textColor: "{colors.amber-deep}"
    typography: "{typography.slug}"
    rounded: "{rounded.none}"
    padding: "5px 8px"
  slug-short:
    backgroundColor: "rgba(217, 59, 30, 0.08)"
    textColor: "{colors.red-deep}"
    typography: "{typography.slug}"
    rounded: "{rounded.none}"
    padding: "5px 8px"
  input-field:
    backgroundColor: "{colors.paper-white}"
    textColor: "{colors.neutral-700}"
    typography: "{typography.body-dense}"
    rounded: "{rounded.none}"
    padding: "8px 12px"
  input-field-focus:
    backgroundColor: "{colors.paper-white}"
    textColor: "{colors.neutral-700}"
  lamp:
    backgroundColor: "{colors.well}"
    rounded: "{rounded.lamp}"
    width: "9px"
    height: "9px"
  lamp-lit:
    backgroundColor: "{colors.bone}"
  lamp-wait:
    backgroundColor: "{colors.amber-signal}"
  lamp-alarm:
    backgroundColor: "{colors.red-signal}"
  poll-cell:
    backgroundColor: "{colors.well}"
    rounded: "{rounded.none}"
    width: "13px"
    height: "17px"
  poll-cell-ok:
    backgroundColor: "{colors.bone}"
  poll-cell-short:
    backgroundColor: "{colors.red-signal}"
  alarm-block:
    backgroundColor: "rgba(217, 59, 30, 0.08)"
    textColor: "{colors.red-signal}"
    rounded: "{rounded.none}"
    padding: "9px 14px"
  nav-item:
    backgroundColor: "transparent"
    textColor: "{colors.neutral-400}"
    typography: "{typography.title}"
    rounded: "{rounded.none}"
    padding: "10px 12px 10px 16px"
  nav-item-active:
    backgroundColor: "rgba(240, 160, 23, 0.08)"
    textColor: "{colors.ink-dark}"
---

# Design System: Emanator Console

## Overview

**Creative North Star: "The Annunciator Panel"**

Emanator is a control console for events its operator already signed. The
surface is built like the front of a rack-mounted station panel: a warm graphite
chassis (`chassis`) with the working field as a lighter panel face (`panel`) set
into it, structure carried by hairline rule and engraved legend, and a small
population of indicator lamps that are dark until something needs a person.
There are no cards, no rounded containers, no drop shadows on structure, no
stat tiles, and no icons in the rail — a console labels a control with engraved
type and an indicator, not a glyph.

The governing doctrine is chromatic scarcity. **Nominal does not illuminate.**
The product has exactly two chromatic values: amber (`amber-signal`) means a
human must tap something, red (`red-signal`) means something did not land.
Everything else — every "published", every "scheduled", every "success" — is
bone or steel. This is enforced at token level, not by convention: the
green, emerald, teal, indigo, blue, sky, cyan, pink and purple ramps in
`app/assets/stylesheets/application.tailwind.css` are **remapped onto the warm
neutral scale**, so a `text-green-500` left anywhere in the markup resolves to
`#a79e91` and simply stops shouting. The same trick squares the world: every
`--radius-*` token except `--radius-full` is `0px`, so a legacy `rounded-lg`
renders as a right angle. The system works by redefining Tailwind's own tokens
rather than overriding its classes — there is no `!important` layer and no
per-view patching.

An earlier rendition of this world used a mint/coral/gold semantic trio on a
grey-green ground, and was rejected in the user's own words as reading
"AI generated". That palette is the category default; reaching for it again
reproduces exactly the complaint this world answers. It stays rejected, and so
does a light "painted panel grey" chassis (attempted as a token swap, abandoned
as muddy). **Both shipped themes are approved:** the dark chassis is the primary
identity and the light theme is its printed twin — the same engraved legend,
lamps and rules rendered as ink on warm stock (`warm-stock`), not a second
world. Per-user system/light/dark preference is a product constraint and must
survive any change here.

**Key Characteristics:**

- Nominal states are dark; only an exception carries colour.
- Exactly two chromatic values, reserved absolutely: amber = act, red = short.
- Zero corner radius everywhere except avatars (`--radius-full` is kept because
  faces are round).
- Structure is hairline rule and engraved legend — never a card, never a shadow.
- Delivery is a poll of N stations, rendered as a strip of lamps and a tally,
  never as a boolean tick.
- Warm neutrals throughout; no cool grey, no pure white, no pure black.
- Three self-hosted families (`font-src :self`): condensed caps for legend,
  Barlow for prose, mono tabular for every measurement.

## Colors

Two signal hues on a wholly warm neutral ground; the neutrals do all the
structural work and the signals are spent only on action and alarm.

### Primary

- **Signal Amber** (`#f0a017`): the only invitation in the product. It marks the
  single primary button per screen, the awaiting-signature lamp and slug, the
  elapsed counter on a row waiting for approval, the active rail item's 3px
  inset spine, the selected calendar day, today's cell tint, the text caret,
  `::selection`, the focus ring, the skip link, and the single lit `a` in the
  "Emanator" wordmark. Amber-on-amber-fill always sets its text in
  `contact-black` (`#1a1714`), never white.
- **Signal Red** (`#d93b1e`): the only alarm. It marks an alarming delivery
  grade (`:thin` or `:none`), a failed publish, the alarm block border and its
  8%-opacity wash, red poll-strip cells, and the per-relay failure reasons.

### Neutral

- **Chassis Graphite** (`#211f1c`): the rail and the ground behind the panel in
  dark mode; also the darkest step of the ramp (`gray-900`).
- **Panel Face** (`#2e2b27`): the working field set into the chassis — the dark
  `body` background and the `gray-800` step.
- **Panel Highlight** (`#353128`): raised inner surfaces (editor body, active
  toolbar button).
- **Seam** (`#171512`): the cut between chassis and field; the rail's right
  border and the `gray-950` step.
- **Well** (`#413c35`): an unlit lamp and an unlit poll cell — a recess, not a
  coloured dot. Also the dark scrollbar thumb and hover fills inside vendored
  widgets.
- **Rule (dark)** (`#403b34`): every hairline divider in dark mode. Its light
  counterpart is `neutral-200` (`#d3ccc1`).
- **Bone** (`#cfc7bb`): lit-and-nominal. A lit lamp, an accepted poll cell. Warm
  rather than white, because an incandescent lamp behind a clear cap is never
  blue.
- **Legend** (`#c4bbac`): engraved caps on the dark chassis.
- **Warm Stock** (`#efebe4`): the light theme's ground — printed paper, not a
  lit panel. `paper-white` (`#faf7f2`) is the raised surface on top of it.
- **Dark Ink** (`#ede8e0`): body text on the dark panel. Mid steps
  `neutral-300`…`neutral-600` carry secondary prose, disabled dates and
  unlit legend in whichever theme needs them.

### Tertiary

- **Wire Inks** (eight fixed values: `#2e6e8c`, `#7a8085`, `#6e4b2a`, `#3f7d6e`,
  `#4f5d75`, `#6b5b95`, `#5f7a3e`, `#8a6f8c`): identity only. The ink is derived
  from the account's pubkey (`Account#ink`, SHA-256 modulo the list), so it can
  never reshuffle when a new account is paired. It appears as a 3px vertical
  wire-marker rule in the row's own flow, as the chop's border, and as the
  calendar's per-account key. All eight are deliberately desaturated and none is
  near amber or red.

### Named Rules

**The Nominal Does Not Illuminate Rule.** A lamp is dark until something is
wrong. Green for "fine" is forbidden — which is why the green/emerald/indigo/
blue/purple ramps are remapped onto the neutral scale at token level rather than
left available.

**The Two Chromatics Rule.** Amber means a human must tap something; red means
something did not land. Nothing else in the product may wear either — not
identity inks, not avatars, not filter states, not step markers, not unread
counts. Each of those was a real violation found and removed during finish
review.

**The Poll Is Not A Boolean Rule.** Publishing to N relays is a poll of N
stations, so a partial answer is the normal answer. `:partial` delivery is
information, never an alarm; only `:thin` (1 of ≥4) and `:none` light red. An
alarm that fires on the ordinary case is an alarm the operator learns to ignore.

## Typography

**Display Font:** Barlow Condensed (500/600/700, self-hosted woff2)
**Body Font:** Barlow (400/500/600, self-hosted woff2)
**Label/Mono Font:** JetBrains Mono (400/700, self-hosted woff2)

All three ship from `public/fonts/` because the app's CSP is `font-src :self`;
no font may be added from a CDN. Base size is **17px / 1.6**, and the whole ramp
sits two steps above stock — Barlow runs small for its point size, and this is a
console read at arm's length on a desk monitor, not a phone held close.

The ramp is defined by **redefining Tailwind's own `--text-*` tokens** in
`@theme`, the same mechanism that squares the radii and defangs the semantic
colour ramps. This is load-bearing: the app sets its size from utilities on
nearly every element, so `body` alone governs almost nothing and raising it
changes nothing visible. The shipped steps are xs 14 / sm 16 / base 17.5 /
lg 20 / xl 22.5 / 2xl 27 / 3xl 33 / 4xl 40, each with its own line-height,
because Tailwind's fixed rem leading would keep 14px spacing under 16px text.

**Character:** Engraved industrial signage over a humanist working text.
Condensed caps do all the labelling, as if struck into the panel; Barlow carries
the operator's own prose; monospace tabular numerals are reserved for anything
that is a measurement and must line up between rows.

### Hierarchy

- **Display** (Barlow Condensed 700, 38px, line-height 1, +0.06em, uppercase):
  the dashboard heading — "34 HELD". One per screen, carrying itself with no
  kicker plate above it.
- **Headline** (Barlow Condensed 700, 33px, 1.05, +0.06em, uppercase): section
  page titles, e.g. the calendar's month. `main h1` is set globally in the
  stylesheet rather than respelled per view.
- **Title** (Barlow Condensed 600, 15px, 1.2, +0.1em, uppercase): the identity
  name in the `identity` block, wrapping to two lines rather than truncating.
  `main h2` picks up the same condensed uppercase treatment at +0.09em.
- **Body** (Barlow 400, 17px, 1.6): all prose. Note copy runs at 16.5px with a
  62ch measure and a two-line clamp in the forme row; the measure is in `ch`, so
  it tracks the size rather than fighting it. Explanatory paragraphs use
  `max-w-prose`.
- **Label / Engraved Legend** (`.eng`, Barlow Condensed 600, 13px, +0.16em,
  uppercase): every legend in the product — section heads, day labels under an
  hour, relay verdicts, the station-status heading. On the dark chassis it
  carries a cut-in shadow (dark above, a 5% light lip below).
- **Slug** (Barlow Condensed 600, 11.5px, +0.18em, uppercase, 1px
  `currentColor` border, 6×9px): the status chip. Never a rounded pill.
- **Hour** (JetBrains Mono 700, 25px, 1, −0.02em, tabular): the release hour at
  display scale in the forme row.
- **Readout** (JetBrains Mono 700, 15px, tabular): elapsed counters, delivery
  tallies, calendar day numbers, npubs and relay URLs.

### Named Rules

**The Measurement Is Mono Rule.** Times, tallies, counters, npubs, event ids and
relay results are set in JetBrains Mono with `font-variant-numeric: tabular-nums`
(applied via `.tabular`, `.display`, `time`, `[data-tabular]`). Prose is never
mono; a number that must be compared between rows is never proportional.

**The Scale Lives In The Token Rule.** The size ramp is changed by editing
`--text-*` in `@theme`, never by sweeping `text-sm` to `text-base` across the
markup and never by raising `body` alone. `body` is the inherited size and
governs only the elements carrying no size utility, which in this app is almost
none of them — an earlier attempt to make the surface more readable moved it and
nothing on screen changed. Tracking comes down as size goes up: the legend lost
0.02em when it gained 2px, because condensed caps that are already wide enough
to read do not need to be spaced apart to be read.

**The No Kicker Rule.** No eyebrow, no kicker plate, no label strip above a
heading. The direction contract's FIRST VIEWPORT specified an engraved
"PRESS RUN · NEXT 24 HOURS" plate above the display heading; it was deliberately
not built, and the contract was amended rather than the ban overridden. A
heading carries itself and its scope line sits below it.

## Layout

A fixed 240px chassis rail on the left at `lg` and above, with the field beside
it in a `max-w-6xl` centred column. Below `lg` the rail becomes a fixed top bar
plus a slide-out panel of the same 240px width, both rendered from one
`layouts/_nav_items` partial so the seven routes cannot drift between the two
surfaces. Mobile is a true 390px target.

The rail's own stack is fixed: wordmark and theme toggle at the head, the route
list in the scrolling middle, the **station status** lamp bank pinned above the
foot, and the signed-in identity at the very bottom. The bank carries four
readings in the order they matter — identities, awaiting signature, barely out,
never went out — and every reading is a link to the filtered list it counts,
including the zero ones.

The field is a vertical run of rules-separated rows, not a grid of cards. The
forme row is a two-column stack on mobile (`auto minmax(0,1fr)`) that becomes
four columns at `sm` (`96px / minmax(0,172px) / minmax(0,1fr) / auto`): hour,
identity, copy, state-and-its-action. The action belonging to a state sits in
the row with it, so the operator never navigates to act.

Rhythm is tight and consistent: 3px between poll cells, 10px between a lamp and
its legend, 14px row padding, 16px panel padding (with `row-wait` bleeding
−16px/+16px so its tint spans the full field), 28px between sections. The
calendar is a 7-column grid of 132px-minimum cells, five events deep with a
"+N more" legend beneath.

## Elevation & Depth

**This system has no elevation.** Nothing in the console floats. Structure is
conveyed entirely by tonal layering and hairline rule: the seam is darker than
the chassis, the chassis is darker than the panel, the panel-highlight is
lighter still, and every division between regions is a 1px `rule` line. There
are no card shadows, no hover lifts, and no ambient glows on containers.

Shadows exist for exactly two purposes, both of them physical rather than
spatial: an **inset** shadow that makes an unlit lamp or poll cell read as a
recess drilled into the panel, and a small **outward glow** that makes a lit one
read as a bulb behind a cap. Engraved legend uses the same trick in text form:
a dark shadow above and a 5%-white lip below.

### Shadow Vocabulary

- **Lamp recess** (`inset 0 1.5px 2px rgba(0,0,0,0.75), 0 1px 0 rgba(255,255,255,0.05)`):
  an unlit indicator, dark theme. Light theme uses `inset 0 1.5px 2px rgba(0,0,0,0.3)`.
- **Cell recess** (`inset 0 1.5px 3px rgba(0,0,0,0.7), 0 1px 0 rgba(255,255,255,0.05)`):
  an unlit poll-strip cell, dark theme.
- **Bone bulb** (`inset 0 1px 0 rgba(255,255,255,0.35), 0 0 5px rgba(207,199,187,0.22)`):
  a lit nominal lamp. A lit cell drops the glow and keeps the lip.
- **Alarm bulb** (`inset 0 1px 0 rgba(255,180,160,0.45), 0 0 9px rgba(217,59,30,0.5)`):
  a red lamp. The amber equivalent is `inset 0 1px 0 rgba(255,225,170,0.4), 0 0 9px rgba(240,160,23,0.5)`.
- **Engraving** (`text-shadow: 0 -1px 0 rgba(0,0,0,0.55), 0 1px 0 rgba(255,255,255,0.05)`):
  legend cut into the dark panel.
- **Popover drop** (`0 14px 34px rgba(0,0,0,0.55)` dark / `0 12px 28px rgba(33,31,28,0.18)` light):
  the *only* true drop shadow in the system, carried by the vendored flatpickr
  calendar because a detached overlay needs to separate from the field beneath.

### Named Rules

**The Flat Chassis Rule.** Surfaces never lift. If a region needs to read as
distinct, change its tone or draw a rule — never add a shadow. Shadows belong to
lamps, cells and engraving, plus the one detached popover.

**The Recess-Before-Colour Rule.** An off state is a well, not a grey dot. An
unlit poll cell already says "this relay did not take it"; red is spent only
when the delivery as a whole is alarming.

## Shapes

Right angles throughout. `--radius-xs` through `--radius-3xl` are all `0px`, so
every `rounded-*` utility still present in the markup renders square without any
per-view edit. `--radius-full` is preserved on purpose — avatars are round
because faces are round — and two micro-exceptions exist for physical
plausibility: a lamp has a 2px radius (a moulded cap, not a pixel) and the
focus ring has 1px.

The recurring silhouettes are: the **hairline rule** (1px, `rule-dark` on dark /
`neutral-200` on light) as the only divider; the **bordered slug** (1px
`currentColor`, never filled except by a 8–9% signal wash); the **3px vertical
wire** in the row's own flow as the identity mark — not a border-left on a
container, which is the lazy accent this world refuses; the **26px square chop**
with a 1px `currentColor` border; and the **13×17px poll cell**, a portrait
rectangle so a strip of them reads as a bank of indicators rather than a
progress bar. Buttons and inputs are plain rectangles; the primary button is a
filled amber plate with a matching border.

## Components

### Buttons

- **Shape:** square (0px), 1px border matching the fill.
- **Primary:** amber plate (`amber-signal`) with `contact-black` text, condensed
  600 caps at 12px/+0.16em, padding 10×16px. One per screen — it is the thing
  the operator came to do.
- **Hover / Focus:** primary lifts to `amber-lift`; focus is the global 2px
  amber outline at 2px offset. Transitions are colour-only, ~150ms.
- **Slug button:** the default action shape — a bordered condensed-caps chip
  identical to a status slug, in neutral ink, hovering to amber. "Rebroadcast",
  "Open", "Out" and the calendar's "Today" all use it. Destructive-adjacent
  actions (Retry on a failed post) take `slug--short` and read red.

### Cards / Containers

There are no cards. A bounded region is `border rule px-4 py-3.5` — a hairline
rectangle on the field's own background, with no fill and no shadow. The only
filled regions are the alarm block (`red-signal` border over an 8% red wash) and
the awaiting-signature block (`amber-signal` border over a 6% amber wash).

### Inputs / Fields

- **Style:** 1px neutral stroke on `paper-white` (dark: chassis), square, padded
  8×12px, body text at 16px.
- **Focus:** border shifts to `amber-signal` with a 40%-amber ring; the caret is
  amber everywhere in the product, including contenteditable and the markdown
  editor.
- **Vendored widgets are themed in both modes.** flatpickr and EasyMDE are
  re-skinned from the same tokens for light *and* dark; a selected day is amber
  in both. A widget themed only under `.dark` is the same control being two
  different products.

### Navigation

Seven engraved routes, no icons. Each item is condensed 500 caps at
12px/+0.16em with an indicator lamp at its head; the active item takes an
`inset 3px 0 0` amber spine, an 8% amber wash, and its lamp lit amber. A
`.skip-link` on amber precedes the rail so a keyboard user does not walk seven
links to reach the work.

### Indicator Lamp (signature)

A 9×9px moulded cap with four states and one doctrine: `off` is the default.
`off` is a recessed well; `on` is bone; `wait` is amber; `alarm` is red. Lamps
appear in the rail, in the station bank, beside every section heading on the
dashboard, on every relay line of the publish readout, and on every row of the
signing queue. The lamp is always `aria-hidden` — its meaning is carried by the
text beside it.

### Poll Strip (signature)

One 13×17px cell per relay the event was sent to: filled bone for a relay that
accepted, recessed for one that did not, red only when the delivery as a whole
grades `:thin` or `:none`. The tally ("5/6") is spelled out beside it in mono
bold, red only when alarming. The cells are `aria-hidden` and a screen reader
gets the sentence instead — "Reached 5 of 6 relays, which is a normal publish."

### Identity Mark (signature)

Wire + chop + name, stated identically on every surface: a 3px pubkey-derived
wire rule in the row's flow, the account's 26px avatar (or a bordered letter
chop in the same ink when there is no picture), then the display name in
condensed caps clamped to two lines. No npub — a truncated `npub14lu…`
identifies nothing, since the leading characters are a shared prefix.

### Status Slug

Bordered condensed caps, 10px/+0.2em. Nominal states ("Held", "Sending") are
neutral and unfilled. `slug--wait` ("Approve on phone") is amber over a 9%
amber wash; `slug--short` ("Barely out 1/6", "Failed") is red over an 8% red
wash. A `:partial` delivery gets no slug at all — it is a normal publish.

### Waiting Row

A row awaiting a human takes a 6% amber tint bled to the full field width via
negative margins, plus its amber lamp and amber slug and a mono elapsed counter.
It is explicitly **not** marked by a 3px coloured border-left: that accent is
refused for identity two rules above it in the stylesheet, and it is refused
here for the same reason.

## Do's and Don'ts

### Do:

- **Do** leave nominal dark. A published, scheduled or completed thing gets bone
  or neutral ink and no lamp glow.
- **Do** change the world by redefining a token in `@theme`, not by adding an
  override class. That is how the neutral ramp, the squared radii and the
  defanged semantic ramps all work.
- **Do** spend amber on exactly one thing per screen: the action a human must
  take.
- **Do** render delivery as a poll — a strip and a tally — and grade it from
  `publish_results` via `RelayDelivery`, never from `status`.
- **Do** put the action that belongs to a state inside the row that shows it.
- **Do** set every measurement (time, tally, npub, relay, event id) in JetBrains
  Mono with tabular numerals.
- **Do** carry both themes on every new surface, including vendored widgets, and
  keep the per-user system/light/dark preference working.
- **Do** self-host any new font file under `public/fonts/`; the CSP is
  `font-src :self`.
- **Do** use hairline rule and tone to divide regions.

### Don't:

- **Don't** use green, emerald, teal, blue, indigo, sky, cyan, pink or purple.
  They are remapped to neutral at token level; reaching for one produces a dead
  grey, which is the intended answer.
- **Don't** put amber or red on anything that is not an action or an alarm — not
  identity inks, not avatars, not filter chips, not step markers, not unread
  counts.
- **Don't** treat a `:partial` delivery as a failure. 5 of 6 is a successful
  publish and must read as one.
- **Don't** render an unqualified success tick for a publish. The tally always
  accompanies the verdict.
- **Don't** introduce a card, a rounded container, or a drop shadow on
  structure. Radius stays 0 except `--radius-full` for avatars.
- **Don't** add a kicker, eyebrow or label plate above a heading.
- **Don't** mark a row with a 3px coloured border-left; use a tint, a lamp and a
  slug.
- **Don't** add icons to the rail, or use a glyph where an engraved legend and a
  lamp will label the control.
- **Don't** reintroduce the rejected mint `#7BE0A0` / coral `#E04B3C` / gold
  `#E8B84B` trio, or any variant of the category's default semantic status set.
- **Don't** theme a control under `.dark` only.
- **Don't** truncate an npub as an identity label; the name is the identifier.
