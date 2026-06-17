# CLAUDE.md — BetterDeathRecap

Single source of truth for this project. **Update this file on every meaningful
change** — new modules, API decisions, data-shape changes, scope changes.
(Derived from `PLAN.md`; keep both consistent but prefer this file for the
current state of the code.)

---

## What this addon is

A World of Warcraft (retail / *Midnight*) addon that replaces Blizzard's poor
built-in death recap with a clean, readable custom UI.

It is a **display layer** on top of Blizzard's `C_DeathRecap` API. Blizzard
collects the death data; we render it well. We do **not** parse the combat log
— addons cannot access CLEU on Midnight, which is why the dominant addon (Death
Note, 755K downloads) went dark and why this niche is open.

`C_DeathRecap` does not provide a health-over-time curve directly, so we
**reconstruct** it from the recap's per-event `currentHP` (see `Analyzer.BuildRecapCurve`).
We do **not** sample `UNIT_HEALTH` — an earlier `HealthTracker` module did, but
`UnitHealth` is "secret" on Midnight (unusable for math) and the recap already
carries the health readings, so that module was removed.

### Non-negotiable design principles
- **Near-zero performance cost.** Always-on events are limited to
  `PLAYER_DEAD`, `PLAYER_ENTERING_WORLD`, `PLAYER_ALIVE`, and `PLAYER_UNGHOST`.
  No `UNIT_HEALTH` sampling, no CLEU, no per-frame polling timers.
- **Read-only.** Only reads data Blizzard explicitly exposes. No protected
  actions, ban-safe.
- **Self-contained.** No dependency on Details! or any other addon.
- **Small.** Target ~300–400 lines total across modules.

---

## Repository layout

Mirrors the sibling **SmartLFG** project (same tooling: luacheck, BigWigsMods
packager, `pkgmeta.yaml`, Makefile-driven local packaging). Addon Lua lives
under `src/`; the `.toc` stays at the repo root.

```
BetterDeathRecap/
├── .github/workflows/{ci.yml, release.yml}
├── dist/                       -- packaged output (git-ignored, produced by package.sh)
├── docs/API-NOTES.md           -- verified C_DeathRecap field shapes
├── media/                      -- addon art (icon, minimap, banner)
├── src/
│   ├── Constants.lua           -- window seconds, colors, death-icon, defaults
│   ├── Locale.lua              -- all user-facing strings (enUS base + 7 locales)
│   ├── Analyzer.lua            -- C_DeathRecap data -> DeathReport (+ sample report)
│   ├── Display.lua             -- renders the frame incl. the HP graph + hover
│   ├── RecapButton.lua         -- "Better Recap" button on the death dialog
│   ├── Minimap.lua             -- minimap skull button (no lib); click = /bdr
│   ├── Options.lua             -- Settings panel (Options → AddOns → BetterDeathRecap)
│   ├── Commands.lua            -- /bdr slash commands
│   └── Core.lua                -- bootstrap, event registration, orchestration
├── BetterDeathRecap.toc        -- AT REPO ROOT. Interface 120000 (Midnight)
├── {.editorconfig, .gitattributes, .gitignore, .luacheckrc}
├── {Makefile, package.sh, pkgmeta.yaml}
├── {CHANGELOG.md, LICENSE.md (MIT), README.md, CLAUDE.md, PLAN.md}
```

### `.toc` load order
`Constants → Locale → Analyzer → Display → RecapButton →
Minimap → Options → Commands → Core` (Locale loads early so `BDR.L` exists before
any module reads it — Display even aliases `local L = BDR.L` at load time.
Minimap/Options load before Core so it can call their `:Init()` on `ADDON_LOADED`.
Core is last so everything it orchestrates is already defined.) `.toc` paths use
backslashes (`src\Core.lua`).

### Minimap button + Options (Minimap.lua, Options.lua)
`Minimap.lua` hand-rolls a minimap button (a skull, `INV_Misc_Bone_HumanSkull_01`,
`SetMask`'d round) — **no LibDBIcon**, to stay dependency-free. **Left-click =
`/bdr`**, **right-click = Options**; draggable around the ring (angle in
`DB.minimapAngle`). It is **shape-aware** (`GetMinimapShape()` + the LibDBIcon quad
table) so it hugs square/rectangular minimaps too. Because a square-minimap addon
can define `GetMinimapShape()` *after* our `ADDON_LOADED`, Core calls
`Minimap:Reposition()` on **PLAYER_ENTERING_WORLD** (when all addons are loaded) so
the position is correct on every reload. Hover highlight uses the button's own
`SetHighlightTexture` (a manual HIGHLIGHT texture showed a stray blue square).

`Options.lua` registers a **canvas Settings panel** under Options → AddOns →
BetterDeathRecap: a **big branded title left** (`GameFontNormalHuge`, `Better` red +
`DeathRecap` cream) + **version small gray right**, a **divider**, then **one toggle:
"Minimap Icon"** (`DB.minimapShown`). The toggle is a plain `UICheckButtonTemplate`;
if **ElvUI** is loaded it is re-skinned via a **soft, dependency-free** call
(`E:GetModule("Skins"):HandleCheckBox`, pcall-guarded, deferred to PLAYER_LOGIN).
Both modules init from Core's `ADDON_LOADED`. Open via `/bdr options` too.

### Localization (Locale.lua)
All user-facing strings live in `src/Locale.lua`. **enUS is the authoritative
base — add new keys there only.** Other locales (`deDE`, `frFR`, `esES`/`esMX`,
`ruRU`, `ptBR`, `itIT`) are `setmetatable`'d with `__index = L_enUS`, so any
untranslated key falls back to English automatically (no nil errors). Access via
`BDR.L.KEY`; format with `BDR.L.KEY:format(...)`. **Locale strings are plain
text** — colour escapes (`|cff…|r`) are applied in calling code, and brand text
("BetterDeathRecap") + slash tokens (`/bdr …`) are never translated.
Environmental death labels are locale keys (`ENV_*`); `Constants.ENVIRONMENT`
maps sentinel spellIDs → those keys and `Constants.ENV_ICONS` maps the type →
a stock icon (Blizzard has no spell for Falling/Drowning/Fatigue/Fire/Lava/Slime,
so there's no spell icon). `Analyzer.ResolveEnvironment` returns `(label, icon)`;
environmental events carry `isEnv` + `iconOverride` and use the label as both the
**Event** name and the source.

### Tooling conventions (match SmartLFG)
- **`package.sh`** is the single source of truth for what ships. `make build`
  → `dist/<version>.zip`; `make deploy` installs into the live client. The
  packaged tree is `dist/BetterDeathRecap/` (the addon-folder root the user
  drops into `Interface/AddOns/`), containing the `.toc`, `media/`, and `src/`.
- **Keep the EXCLUDES list in `package.sh` in sync with `ignore:` in
  `pkgmeta.yaml`.**
- **`.luacheckrc`** whitelists the WoW globals `src/` references. Keep it in
  sync with actual usage.
- **CI** (`ci.yml`) runs luacheck + validates `## Version:` (semver) and
  `## Interface:` (6-digit). **Release** (`release.yml`) is semver-tag-triggered
  and delegates packaging to `package.sh`.

---

## The addon table & globals

Each file starts with `local addonName, BDR = ...`. The shared addon table is
`BDR`; modules hang themselves off it (`BDR.Analyzer`, `BDR.Display`,
`BDR.Commands`, plus `BDR.Print`, `BDR.COLOR`, `BDR.CONFIG`).

SavedVariables global: **`BetterDeathRecapDB`** (account-wide). Stores SETTINGS
account-wide — window position, lock state, `scale`, `sourcesCollapsed`,
`minimapShown` / `minimapAngle`. The **last death report is PER-CHARACTER** under
`deaths[name-realm]` (so each character sees only its own latest death, not whoever
died most recently account-wide) — accessed via `BDR.GetLastReport()` /
`BDR.SetLastReport()`, never `DB.lastReport`. Declared in the `.toc` via
`## SavedVariables: BetterDeathRecapDB`.

---

## Data source — `C_DeathRecap`

**Real API — confirmed in-game via `/bdr debug` (enumerated `C_DeathRecap`):**
```
C_DeathRecap.HasRecapEvents(recapID)     -- whether recap id exists (probe 1..N, id 1 = newest)
C_DeathRecap.GetRecapEvents(recapID)     -- event list (we also try arg-less as a fallback)
C_DeathRecap.GetRecapMaxHealth(recapID)  -- max health for the recap → scales the HP curve
C_DeathRecap.GetRecapLink(recapID)       -- chat link (unused for now)
OpenDeathRecapUI(recapID)                -- Blizzard's own UI (global; reference only)
```
Earlier guesses (`HasNewDeathRecap`, `GetCombatants`, `GetDeathRecapEvents`) do
**not** exist on this client — that's why the first builds read nothing. All
recap calls go through `Analyzer.SafeCall` (pcall) so a wrong arity can't error.
Event field names are still being confirmed: `NormalizeEvent` takes `|amount|`
(sign-agnostic), reads `spellId`/`spellID`, `overkill`, `absorbed`, `timestamp`,
`name`/`hideCaster`. **`/bdr debug` dumps the first raw event's fields** — use it
to verify/adjust names. Spell names resolve via `C_Spell.GetSpellName`/`GetSpellInfo`.

**HP curve is reconstructed from the recap, not UnitHealth.** Because
`UnitHealth` is "secret" on Midnight (see below), `BuildRecapCurve` plots each
event's `currentHP` (the player's health when the hit landed) directly, or — if
no `currentHP` is present — rebuilds the curve from per-hit damage, working
backward from death (0 HP): health-before-a-hit = health-after + that hit's
effective damage (the killing blow only removed `amount − overkill`). Event times
are relative to death; if the recap gives no usable timestamps they're spaced
evenly. The window grows to fit the oldest hit. (The old `HealthTracker`
`UNIT_HEALTH` sampler has been **removed** — the recap's `currentHP` is the curve
source, and `UnitHealth` is secret on Midnight anyway.)

**Curve normalisation — the fix for "always starts at 100%".** The curve is
normalised to the player's **real max health** (`realMax`), NOT to the peak
observed HP. `realMax` = `GetRecapMaxHealth` (reliable on the *newest* recap id —
the old "implausible" values came from reading a stale id) cross-checked against
`UnitHealthMax("player")` (non-secret on Midnight); if the recap max looks
implausible (> 1.5× the unit max) we use the unit max, and we never let the
denominator fall below the peak observed HP. Normalising to `realMax` is what
makes a fight that *opened below full health* read e.g. 60% at the start instead
of a false 100%. Only when no real max is available at all do we fall back to the
old peak-normalisation (last resort). This is "as Blizzard does it":
`remaining% = currentHP / maxHP`.

Cautions (see `docs/API-NOTES.md`):
- Field availability (especially `overkill`, `absorbed`) varies by patch — code
  defensively, hide a field rather than erroring.
- Environmental deaths may have a nil source — label by environmental type
  (Falling, Drowning, Fire, Lava, Slime, Fatigue).
- `OpenDeathRecapUI()` / `Blizzard_DeathRecap` are reference only — do not
  depend on them for our UI.
- Spell texture: prefer `C_Spell.GetSpellTexture(spellID)`, fall back to the
  global `GetSpellTexture(spellID)`.

### Midnight "secret values" — health math must be guarded
On Midnight, some content makes `UnitHealth("player")` return a **secret/
protected number**: addon (tainted) code may *store* it but doing arithmetic on
it raises `attempt to perform arithmetic … (a secret number value, while
execution tainted by 'BetterDeathRecap')`. **We therefore never read
`UnitHealth` for the curve** — it comes from the recap's per-event `currentHP`.
`UnitHealthMax` was observed non-secret and is used (pcall-guarded) only as the
`realMax` cross-check. The curve math lives entirely in `BuildRecapCurve`, which
is **`pcall`'d** in `Analyzer:Build`; if it can't build, Display shows
`L.HP_UNAVAILABLE` instead of erroring. **Never do bare arithmetic on a
`UnitHealth` result anywhere in this addon.** The recap data (timeline/sources/
banner) is unaffected — it comes from `C_DeathRecap`.

### DeathReport shape (Analyzer output → Display input)
```lua
DeathReport = {
  killedAt     = <timestamp>,
  killingBlow  = { sourceName, sourceGUID, spellName, spellID, amount, overkill },
  events       = { { t, sourceName, spellName, spellID, amount, absorbed, isKillingBlow }, ... }, -- chronological
  sources      = { { name, total, pct }, ... },  -- sorted desc, for damage-source bars
  healthCurve  = { { t, pct }, ... },            -- normalised to realMax (currentHP/maxHP), NOT peak HP
  context      = { difficulty, zone, windowSeconds },
}
```
`t` is **relative seconds to death** (negative, e.g. `-7.2`), so Display never
deals in epoch timestamps.

---

## Event wiring (Core.lua)

```
frame:RegisterEvent("ADDON_LOADED")                 -- InitDB + Options/Minimap :Init
frame:RegisterEvent("PLAYER_ENTERING_WORLD")        -- reposition the minimap button
frame:RegisterEvent("PLAYER_DEAD")                  -- build + store the report
frame:RegisterEvent("PLAYER_ALIVE"/"PLAYER_UNGHOST")-- hide the on-death button

PLAYER_DEAD:           C_Timer.After({0.3,1.0,2.0,3.5}, BuildAndStore)  -- recap populates a beat late
                       -- BuildAndStore: Analyzer:Build() -> keep NEWEST by killedAt -> DB;
                       --   Display:RefreshIfShown; RecapButton:OnDeath()
                       -- (we do NOT auto-open the window — it'd cover the release dialog)
PLAYER_ENTERING_WORLD: Minimap:Reposition()  -- all addons loaded → GetMinimapShape() is final
PLAYER_ALIVE/UNGHOST:  RecapButton:OnAlive()
```

The window is opened by the player — the **Better Recap** button (RecapButton.lua,
anchored right of Blizzard's Recap button on the death dialog) or `/bdr`. Opening
rebuilds from the live recap, falling back to the stored report. `/bdr` no longer
falls back to the demo; only `/bdr test` does.

**The Better Recap button is a real element of the death dialog, themed like it.**
It is `UIPanelButtonTemplate` **soft-skinned via ElvUI** (`E:GetModule("Skins"):
HandleButton`, pcall-guarded, once per button) — ElvUI doesn't auto-skin a custom
addon button, so without this it kept the classic look beside a themed dialog.
`Anchor` parents it to the StaticPopup, sizes/levels it to match the Recap button,
sits it in the button row, then **`ExtendDialog` grows the popup's width** so our
button is contained inside the dialog instead of floating off the right edge
(best-effort + guarded; converges across the OnDeath re-anchor retries). Because
StaticPopups are **recycled for other prompts**, the original width is tracked and
**restored on `OnAlive`** (and in `Anchor`'s no-dialog fallback).

---

## UI / display spec (Display.lua)

**Canonical spec: the `design.png` mockup** (supersedes the older `DESIGN.png` /
`BetterDeathRecap_UI_v2.png`) — "Dragonflight-era" theme: near-black bg, gold
accents, red damage / green heal / blue absorb — exact hex in `Constants.lua`
`BDR.UI`. Vertical stack; the window auto-sizes its height on every `Show()`.
The **one intentional deviation** from `design.png`: it shows the combat table
above the graph; **we keep the graph above the table**. `/bdr test` renders the
sample report (`Analyzer:SampleReport`), whose data (Mephisto · Soulfire, the hit
list, the four damage sources) is tuned to reproduce `design.png` for UI iteration.

> **Data caveat:** PLAN.md lists `COMBAT_LOG_EVENT_UNFILTERED` as a source, but
> CLEU is unavailable on Midnight — the addon stays on `C_DeathRecap` (see top of
> this file). The UI implements PLAN's *interaction model*; it does not switch
> data layers. The **absorb line** therefore renders only if an absorb-over-time
> series exists (we don't have one yet), so it's a legend entry that stays dark.

The canonical layout is **`design.png`**. Its section ORDER has the combat table
above the graph — that is the one intentional deviation: **we keep the graph
above the table** (the rest matches `design.png`). The frame has **square corners**
(1px straight border, no rounded tooltip edge), **background alpha 0.7** (`BDR.UI.BG`),
and a **rebaselined scale**: the slider shows 0.9–2.0 (default **1.0**) but the
applied frame scale is `DB.scale × CONFIG.SCALE_BASE` (1.3), so slider 1.0 renders
at the old 1.3 size. A one-time `scaleRebased` migration resets a saved scale once
so it isn't double-applied.

Sections top→bottom:
1. **Header** — dark strip with a **gray** bottom divider (`BORDER_GRAY`); title
   **left-aligned** (`Better` red, `DeathRecap` primary text). Right side: a **scale
   slider** (rectangular track, thumb shows the value; 0.9–2.0 step 0.1, persisted as
   `DB.scale`, applied via `f:SetScale` **only on mouse-up**) then the **standard
   `UIPanelCloseButton`**. That "×" is the **legacy** close widget, which ElvUI does
   **not** auto-skin on a custom frame, so we re-skin it ourselves via a **soft,
   dependency-free** call (`E:GetModule("Skins"):HandleCloseButton(close)`, pcall-
   guarded, no-op when ElvUI is absent) — same pattern as the Options checkbox. All
   items are **vertically centred** on `headerBg`'s midline. The **slider is anchored
   directly to `headerBg`** (RIGHT −36, NOT chained off the close button) and the close
   button's anchor is **re-asserted after ElvUI skinning** — so a skin re-anchoring the
   close button can no longer drag the slider/label off-centre.
2. **Death summary banner** — dark-red bar: 32px **SOURCE** icon with a dark-outer +
   red-inner outline and left padding — environmental → its stock icon, a creature →
   its **STATIC portrait** (`bannerSourceModel`, a `PlayerModel` over the icon,
   `FreezeAnimation`'d so it's a frozen face not an animated 3D; pcall-guarded
   `SetCreature` from the `kb.sourceGUID` creatureID), else the spell icon as a
   fallback. **Two blocks**: left = `KILLED BY` (red, banner top) over `<killer>(WoW
   yellow `NAME_YELLOW`) • <spell>(text)`; right = the **killing blow's own damage**
   `(red, large, signed with a leading −)` over its `(Xk overkill)(gray)` — NOT the
   window total. `KILLED BY` and the Damage number are **top-anchored**; the **killer•
   spell line and the overkill line are BOTH bottom-anchored to the banner** so they
   share one baseline (Source/Spell aligned with the overkill text).
   An invisible `bannerSpellBtn` over **only the killer•spell text** shows the spell
   tooltip (`SetSpellByID`, `ANCHOR_TOP` = above the centre of that text, like the
   table rows). (There is **no big right-side portrait model** — a 3D model rendered
   OVER the 2D amount/overkill text and hid it.)
3. **Health-timeline graph (hero) — the selling point.** X axis = **seconds
   BEFORE death** (`… -4s -2s`, with `DEATH` red at the death point `X(0)`);
   `GRAPH_PAD` (0.1s) of breathing room is added **before the first hit AND after
   death** so neither end is flush to an edge; **both margins show a dashed fading
   line** (`tailPool`) — at HP=0 after death, and at the first sample's HP level
   before combat. **Mouse-wheel over the graph ZOOMS** the time window in/out around
   the cursor (`F.zoomMin/zoomMax`; tightest zoom = `MIN_ZOOM_SPAN` **0.5s** visible
   window, enforced in every zoom path — graph wheel, overview wheel, brush resize;
   wheeling fully out restores the full view; reset on every
   `Show`) and **click-drag PANS** the zoomed window (or, when fully zoomed out, moves
   the whole window like the title bar) — both on `F.graphOverlay` (`EnableMouse` +
   `RegisterForDrag`; `overlay.panning`/`movingWindow` flags; `GraphTrack` does the
   pan math in its OnUpdate so it continues even off-frame; `RenderGraph` is
   forward-declared so `GraphTrack` can re-render). A top-right **`GRAPH_HINT`**
   FontString (`f.graphHint`, **"SCROLL TO ZOOM"** only — drag-pan still works, just
   isn't advertised) sits at the graph header. The graph
   `SetClipsChildren(true)` so off-range line/dots can't spill, and the axis labels +
   tombstone live on `f` (not `graph`) to dodge the clip. X-tick labels adapt to the
   visible span (down to 0.25s when zoomed in) via `xtickPool`; times render to
   **3 decimals** (`%.3fs`) everywhere (table, graph tooltip, row tip). Y axis = HP%,
   mapped into `[Y_AXIS_MIN(-5%)..100]`
   so the death line isn't flush at the bottom; **0/25/50/75/100% labels only — NO
   gridlines** (and **no area fill, no legend, no minor ticks**: "keep only the
   line"). **Stepped** HP line — HP holds flat between hits and drops **vertically**
   on a hit (a diagonal would falsely imply HP bleeding down gradually). **Gradient
   `HpColor`** green→amber(30–50%)→red. Markers + cursor tooltip read the line via
   `StepPctAt` (stepped); HP% is **rounded to nearest** (NOT ceil — the "1% above to
   match Blizzard" ceil read HP wrong and was reverted). After death, a short **dashed
   fading tail** at HP=0 (`tailPool`). The death point on the x-axis is marked with a
   **grave/death marker** (`f.deathMarker`) **in place of a "DEATH" label** — the
   `tt=0` x-tick is skipped; it uses the **`poi-graveyard-neutral` atlas** (a
   tombstone, reliably present) and falls back to the `BDR.DEATH_ICON` texture. (The
   literal `inv_misc_coffin_01` texture rendered blank in the client, hence the atlas.)
   **Event markers = a school-coloured DOT per hit** (`dotPool`: a solid `fill` inside
   a thin dark `border` ring, heals green; radius 5, **KB 7**). NOT spell icons — dots
   were reverted to for a cleaner, consistent timeline (the icons-on-line read as
   clutter). `F.markerPos[ev]` records each. Time mapping lives in `F.mapT`
   (`xMinT`/`span`/`fullMin`/`fullMax`), used by `GraphX` + `GraphTrack`.
   - **Continuous cursor tooltip** (`GraphTrack` on `graphOverlay`'s `OnUpdate`):
     a transparent overlay maps the cursor X → time, finds the nearest hit by X, and
     shows a `GameTooltip` (`ANCHOR_CURSOR_RIGHT`) that follows the cursor with no dead
     zones. **Minimal line** (default **yellow**): `%.3f sec before death at NN% health.`
     (`TIP_BEFORE_DEATH`) — or, on the killing blow, `Killing blow at NN% health.`
     (`TIP_KB_AT`). NOT "seconds into combat" (that was wrong/removed). **On a dot** it
     expands with an `|T icon|t Spell Name` line then `Source:` / `School:` / `Hit:`
     (signed) / `Hit %:` (its `% Max HP` delta) double-lines. The displayed HP/time use
     the **hit's own** `hpPct`/`t` (so the KB reads its real ~2%, not 0% at death). It
     also drives the scrubber line + marker glow + table-row sync.
   - **Dotted vertical cursor crosshair** (`ShowCrosshair`/`HideCrosshair` over
     `f.crosshairPool`): a column of short dashes at the cursor X (a solid texture can't
     be dashed, so it's pooled dashes — same trick as `tailPool`), redrawn each hover
     frame. Shown by both `GraphTrack` and the table-row hover sync.
   - **Table→graph sync**: `HoverEvent`/`UnhoverEvent` (table-row hover) light the
     crosshair + marker glow via `GraphX`/`F.markerPos`.
   - **Overview / zoom-scroll strip** (`f.overview`, height `OVERVIEW_H`, between the
     x-axis and the table): a compressed stepped HP curve over the **full** extent
     (`f.ovLinePool`, red) with a draggable **brush** (`f.ovBrush`) over the visible
     `[zoomMin..zoomMax]` window and dimming (`ovDimL/ovDimR`) on the out-of-view sides.
     **Drag the brush body to SCROLL (pan), drag an edge grip to ZOOM, or scroll-wheel
     over the strip to ZOOM** (centred on the cursor, `ov:OnMouseWheel`); if the brush
     ends up spanning everything, zoom clears (full view). The brush carries centred
     **◄ ► move-handles** (`ovArrowL/ovArrowR`, atlas `common-icon-back/forwardarrow`
     with a rotated-arrow fallback) shown only when it's wide enough. The drag modes
     share `OverviewDrag`, run from an OnUpdate installed only while a drag is live (set
     in `OverviewDragStart`, cleared in `OverviewDragStop`), re-rendering each frame so
     the brush tracks the cursor. `RenderOverview` (called at the end of `RenderGraph`)
     draws the strip + positions the brush, so it mirrors every wheel-zoom too. Hidden
     when there's no curve.
4. **Combat event table** — scrollable `UIPanelScrollFrameTemplate`,
   `TL_VISIBLE_ROWS` (**5**) tall (matches `SRC_VISIBLE_ROWS`), **newest first**,
   **damage-only** (heals are filtered out — they stay on the graph). A **borderless
   grid: every column (header AND value) is LEFT-aligned at its own x** (titles all the
   way left). Columns: `Time · [tombstone on KB] · icon Event · Source · Damage · Remaining
   Health`. The viewport **reserves the scrollbar width** (`needScroll → rowW = WINDOW_W
   − 2·PAD − SCROLLBAR_W`, full width otherwise; `C_SOURCE_W` 122 so the HP bar ends
   ≈509, clearing the bar) — an earlier "full-width rows, scrollbar overlays the margin"
   experiment was reverted. The **killing-blow row shows a tombstone** (`row.deathIcon`,
   `ApplyDeathIcon`) right of its time. **Source is wide**; **Remaining Health** = `NN%`
   **right-aligned tight to a flat bar** (`pctBar`). The **Event icon is always shown**
   (melee = spell 88163). **Source** = the attacker name (`ev.sourceName`, dim).
   **Damage** = the raw number **signed with a leading `-`** (the table is damage-only),
   red (brighter on the KB). **Remaining Health** = the HP the player had WHEN the hit
   landed (`ev.hpPct` = the hit's own `currentHP / realMax`, set in Analyzer; falls back
   to `PctAtT` for the sample) — this makes the **KB show its real pre-hit HP (e.g. 2%)
   instead of 0**; rounded to nearest; the graph dot uses the same `ev.hpPct`. **All row
   text uses `SetWordWrap(false)`**. **Hover split**: the **Event cell** (a
   `row.eventBtn` overlay) shows the **spell tooltip** (`SetSpellByID`, `ANCHOR_TOP`);
   **everywhere else** shows a **Blizzard-style Time/Damage/HP tooltip** (`ShowRowTip`).
   KB row = strong red wash. **No "scroll for more" hint** — the scrollbar itself
   signals overflow. Scrollbars are restyled to the **modern thin look**
   (`StyleScrollbar`: thin track, chevron arrows from the minimal atlas).
   - **Event ORDER matches Blizzard's recap exactly**, including same-tick
     melee+spell: `GatherRecap` tags each event with its `recapIndex` (newest-first
     position) and `Build` sorts by timestamp with a **stable recapIndex tiebreaker**
     — an unstable sort previously scrambled equal-timestamp events.
5. **Damage sources** — **COLLAPSIBLE** (`DB.sourcesCollapsed`, default **true**).
   Collapsed: just a clickable **`Total Damage <grand>`** line on top (**no ▶/▼ icon**;
   the grand total is **red**, `BDR.UI.DAMAGE`, like the overkill). A **hover tooltip**
   on `srcTotalBtn` explains the click: `SRC_EXPAND` ("Click to expand damage sources")
   when collapsed, `SRC_COLLAPSE` ("Click to collapse…") when expanded. Clicking it
   expands → the **meter list** appears and the `Total Damage` line drops below it (the
   full layout); clicking again re-collapses. Each meter row (`srcScroll`,
   `SRC_VISIBLE_ROWS` 5): one **FAT bar covering the whole row** (width ∝ share of total)
   with the **source PORTRAIT** (`row.portrait`, a frozen `PlayerModel` from the source's
   GUID, env/spell icon underneath) · name · raw total ON TOP (no per-row %), sorted
   desc, primary brightest.
6. **Footer** — preceded by a **divider**; `DIFFICULTY • ZONE • NS WINDOW`
   (uppercase, **gray**) + `/bdr` hint. **Half-height** (`FOOTER_H` 10) with the text
   **vertically centred** in the band.

The Analyzer puts **heals** in `report.hits` (with `kind`) so the graph can show
HP rising; the table filters them out. Each source carries a representative
`spellID` for its icon.

> Still not faked: the **absorb shield line** (no absorb-over-time data) and the
> "click an event to scroll/select the row" affordance (hover-sync is implemented;
> click-to-scroll is not).

---

## Slash commands (Commands.lua)
- `/bdr` — toggle the window (shows last report if one exists).
- `/bdr test` — render the built-in sample report (UI iteration without dying).
- `/bdr history` — show the most recent saved death.
- `/bdr options` (or `config`) — open the Settings panel.
- `/bdr lock` / `/bdr unlock` — toggle drag-to-move.
- `/bdr debug` — print which `C_DeathRecap` API is present + events read (diagnostics).

---

## Edge cases (handle from the start)
- No new recap on `PLAYER_DEAD` → do nothing, don't error.
- Missing `overkill` / `absorbed` → hide gracefully.
- Environmental death with nil source → label by environmental type.
- Repeated deaths while already dead → `PLAYER_DEAD` fires once; ignore extras.
- Empty combatant/event list → minimal "No recap data" state.
- **Instant-death effects** (`SPELL_INSTAKILL`, e.g. Atomize) carry **no amount** —
  `NormalizeEvent` flags `isInstaKill`, treats them as damage (so they're the killing
  blow, not dropped), and Build sets their "damage" to the HP removed (`currentHP`,
  else `realMax`). The banner shows `(instant kill)` instead of an overkill line.

---

## Status / build order
1. ✅ Repo scaffolded (SmartLFG layout + tooling).
2. ✅ CLAUDE.md written.
3. ✅ `.toc` + Constants + Core skeleton.
4. ✅ Analyzer (C_DeathRecap → DeathReport + sample report).
5. ✅ Display (banner, HP graph, timeline, sources, footer) — HP graph included.
6. ✅ Commands (`/bdr`, `/bdr test`, `/bdr history`, lock/unlock).
7. ✅ SavedVariables (position, lock, last report) — see `DB_DEFAULTS` in Core.lua.
8. ✅ `make lint` clean (luacheck, 0 warnings). `make build` produces a correct
   `dist/BetterDeathRecap/` staging tree (zip step needs `zip`; present on CI).

v1 is feature-complete and lint-clean. **Not yet verified in the live client** —
the `C_DeathRecap` field shapes (esp. `overkill`/`absorbed` and combatant→event
association) still need confirming in-game; code is defensive so a mismatch
degrades gracefully rather than erroring. (Update markers as that lands.)

### Known follow-ups
- Verify in-game with `/bdr test` (UI) and a real death (data path).
- Confirm `C_DeathRecap.GetCombatants`/`GetEvents` shapes match `docs/API-NOTES.md`.
- Real art in `media/` (icon, minimap, banner) — addon loads fine without it.

## Reminders
- Verify every `C_DeathRecap` field against the live API before relying on it.
- Keep it tiny and dependency-free.
- Update this file whenever structure, data shapes, or scope change.
