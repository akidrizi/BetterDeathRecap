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

`C_DeathRecap` does not provide a health-over-time curve, so we supplement it
with lightweight, event-driven `UNIT_HEALTH` sampling.

### Non-negotiable design principles
- **Near-zero performance cost.** Always-on events are limited to
  `PLAYER_DEAD`, `PLAYER_ENTERING_WORLD`, and `UNIT_HEALTH` (registered per-unit
  for `player`, event-driven). No CLEU. No per-frame polling timers.
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
│   ├── Constants.lua           -- window seconds, sample cap, colors, defaults
│   ├── Locale.lua              -- all user-facing strings (enUS base + 7 locales)
│   ├── HealthTracker.lua       -- UNIT_HEALTH sampling -> rolling {t, hp, hpMax}
│   ├── Analyzer.lua            -- C_DeathRecap data -> DeathReport (+ sample report)
│   ├── Display.lua             -- renders the frame incl. the HP graph + hover
│   ├── RecapButton.lua         -- "Better Recap" button on the death dialog
│   ├── Commands.lua            -- /bdr slash commands
│   └── Core.lua                -- bootstrap, event registration, orchestration
├── BetterDeathRecap.toc        -- AT REPO ROOT. Interface 120000 (Midnight)
├── {.editorconfig, .gitattributes, .gitignore, .luacheckrc}
├── {Makefile, package.sh, pkgmeta.yaml}
├── {CHANGELOG.md, LICENSE.md (MIT), README.md, CLAUDE.md, PLAN.md}
```

### `.toc` load order
`Constants → Locale → HealthTracker → Analyzer → Display → Commands → Core`
(Locale loads early so `BDR.L` exists before any module reads it — Display even
aliases `local L = BDR.L` at load time. Core is last so everything it
orchestrates is already defined.) `.toc` paths use backslashes (`src\Core.lua`).

### Localization (Locale.lua)
All user-facing strings live in `src/Locale.lua`. **enUS is the authoritative
base — add new keys there only.** Other locales (`deDE`, `frFR`, `esES`/`esMX`,
`ruRU`, `ptBR`, `itIT`) are `setmetatable`'d with `__index = L_enUS`, so any
untranslated key falls back to English automatically (no nil errors). Access via
`BDR.L.KEY`; format with `BDR.L.KEY:format(...)`. **Locale strings are plain
text** — colour escapes (`|cff…|r`) are applied in calling code, and brand text
("BetterDeathRecap") + slash tokens (`/bdr …`) are never translated.
Environmental death labels are locale keys (`ENV_*`); `Constants.ENVIRONMENT`
maps sentinel spellIDs → those keys, resolved in `Analyzer.ResolveSource`.

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
`BDR`; modules hang themselves off it (`BDR.HealthTracker`, `BDR.Analyzer`,
`BDR.Display`, `BDR.Commands`, plus `BDR.Print`, `BDR.COLOR`, `BDR.CONFIG`).

SavedVariables global: **`BetterDeathRecapDB`** (account-wide). Stores window
position, lock state, and the last death report. Declared in the `.toc` via
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
`UnitHealth` is "secret" on Midnight (see below), `BuildRecapCurve` rebuilds the
curve from `GetRecapMaxHealth` + per-hit damage, working backward from death
(0 HP): health-before-a-hit = health-after + that hit's effective damage (the
killing blow only removed `amount − overkill`). Event times are relative to
death; if the recap gives no usable timestamps they're spaced evenly. The window
grows to fit the oldest hit. **HealthTracker is now effectively unused for the
curve** (it still samples but those values are secret/unused — candidate for
removal).

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
execution tainted by 'BetterDeathRecap')`. `UnitHealthMax` was observed
non-secret. So: `HealthTracker:Sample()` only **stores** raw `hp`/`hpMax` (no
math — safe), and **all** health-percentage math goes through `Analyzer.SafePct`
(a `pcall`'d `hp/hpMax`). A secret value → `SafePct` returns nil → that sample is
skipped. If the whole curve comes back empty, Display shows
`L.HP_UNAVAILABLE` instead of erroring. **Never do bare arithmetic on a
`UnitHealth` result anywhere in this addon.** The recap data (timeline/sources/
banner) is unaffected — it comes from `C_DeathRecap`, not `UnitHealth`.

### DeathReport shape (Analyzer output → Display input)
```lua
DeathReport = {
  killedAt     = <timestamp>,
  killingBlow  = { sourceName, spellName, spellID, amount, overkill },
  events       = { { t, sourceName, spellName, spellID, amount, absorbed, isKillingBlow }, ... }, -- chronological
  sources      = { { name, total, pct }, ... },  -- sorted desc, for damage-source bars
  healthCurve  = { { t, pct }, ... },            -- from HealthTracker, normalised to the window
  context      = { difficulty, zone, windowSeconds },
}
```
`t` is **relative seconds to death** (negative, e.g. `-7.2`), so Display never
deals in epoch timestamps.

---

## Event wiring (Core.lua)

```
frame:RegisterEvent("PLAYER_ENTERING_WORLD")        -- clear stale health buffer
frame:RegisterEvent("PLAYER_DEAD")                  -- freeze snapshot, build report
frame:RegisterEvent("PLAYER_ALIVE"/"PLAYER_UNGHOST")-- hide the on-death button
frame:RegisterUnitEvent("UNIT_HEALTH", "player")    -- lightweight sampling

PLAYER_DEAD:           BDR.lastDeathSnapshot = HealthTracker:Snapshot()  -- freeze curve
                       C_Timer.After(0.3, BuildAndStore)  -- recap populates a beat later
                       -- BuildAndStore: Analyzer:Build(snapshot) -> DB; RecapButton:OnDeath()
                       -- (we do NOT auto-open the window — it'd cover the release dialog)
UNIT_HEALTH:           HealthTracker:Sample()
PLAYER_ENTERING_WORLD: HealthTracker:Clear()
PLAYER_ALIVE/UNGHOST:  RecapButton:OnAlive()
```

The window is opened by the player — the **Better Recap** button (RecapButton.lua,
anchored right of Blizzard's Recap button on the death dialog) or `/bdr`. Opening
rebuilds from the live recap + the frozen death snapshot, falling back to the
stored report. `/bdr` no longer falls back to the demo; only `/bdr test` does.

---

## UI / display spec (Display.lua)

**Canonical spec: the `DESIGN.png` mockup** (supersedes the older
`BetterDeathRecap_UI_v2.png`) — "Dragonflight-era" theme: near-black bg, gold
accents, red damage / green heal / blue absorb — exact hex in `Constants.lua`
`BDR.UI`. Vertical stack; the window auto-sizes its height on every `Show()`.
`/bdr test` renders the sample report (`Analyzer:SampleReport`), whose data
(Mephisto · Soulfire, the hit list, the four damage sources) is tuned to
reproduce `DESIGN.png` for UI iteration.

> **Data caveat:** PLAN.md lists `COMBAT_LOG_EVENT_UNFILTERED` as a source, but
> CLEU is unavailable on Midnight — the addon stays on `C_DeathRecap` (see top of
> this file). The UI implements PLAN's *interaction model*; it does not switch
> data layers. The **absorb line** therefore renders only if an absorb-over-time
> series exists (we don't have one yet), so it's a legend entry that stays dark.

Sections top→bottom:
1. **Header** — dark strip with a **gray** bottom divider (`BORDER_GRAY`); title
   **centred** (`Better` red, `DeathRecap` primary text). Right side: a **scale
   slider** `Scale: [ [1.0] ]` (rectangular track, the thumb shows the value;
   0.9–2.0 step 0.1, persisted as `DB.scale`, applied via `f:SetScale` **only on
   mouse-up** — `OnValueChanged` just updates the thumb label) then the **standard
   `UIPanelCloseButton`**. No Pin/History.
2. **Death summary banner** — dark-red bar: 32px killing-blow spell icon with a
   dark-outer + red-inner outline and left padding; `KILLED BY` (red) +
   `<killer>(WoW yellow `NAME_YELLOW`) • <spell>(text)`; large **total-damage**
   number `(red)` on the right (sum of `report.sources` totals — the same figure
   as the "Total Damage" row; falls back to the killing-blow amount if no sources)
   with the killing blow's `(Xk overkill)(gray)` beneath. An invisible
   `bannerSpellBtn` over the icon+name shows the **real spell tooltip**
   (`GameTooltip:SetSpellByID(kb.spellID)`) on hover.
3. **Health-timeline graph (hero) — the selling point.** X axis = **seconds into
   combat** (0 = first event → death at `duration`, then `TAIL_SECONDS` of padding);
   whole-second labels (`xtickPool`) + 0.5s minor ticks (`xminorPool`). Y axis =
   HP%, mapped into `[Y_AXIS_MIN(-5%)..100]` so the death line isn't flush at the
   bottom; **0/20/40/60/80/100% labels + low-opacity gridlines**. **Stepped** HP
   line (no interpolation), **gradient `HpColor`** green→amber(30–50%)→red, with a
   matching low-opacity **area fill**. After death, a **dashed fading tail** at
   HP=0 (`tailPool`) keeps the killing-blow dot hoverable. **Event markers = dots
   on the line coloured by damage school** (`SchoolInfo`, heals green), white
   outline, KB bigger; `F.markerPos[ev]` records each.
   - **Continuous cursor tooltip** (`GraphTrack` on `graphOverlay`'s `OnUpdate`):
     a transparent overlay maps the cursor X → time, finds the nearest hit by X,
     and shows a `GameTooltip` (`ANCHOR_CURSOR_RIGHT`) that follows the cursor with
     no dead zones — `Xs into combat`, color-coded `% HP remaining`, then for a hit:
     spell, source, signed damage, school, `% Max HP` delta, and a `KILLING BLOW`
     badge. It also drives the scrubber line + dot glow + table-row sync.
   - **Table→graph sync**: `HoverEvent`/`UnhoverEvent` (table-row hover) light the
     scrubber + dot glow via `GraphX`/`F.markerPos`.
4. **Combat event table** — scrollable `UIPanelScrollFrameTemplate`,
   `TL_VISIBLE_ROWS` (6) tall, **newest first**, full event list (`report.hits`,
   **damage + heals**). **Gray** column headers. Columns: `Time · icon Ability ·
   Type pill · Amount · % Max HP`. The **Ability icon is always shown** — the spell
   icon by ID; **melee carries spell 88163** (the "Melee" auto-attack: real icon +
   tooltip). **Hovering a row shows the spell tooltip** (`GameTooltip:SetSpellByID`,
   anchored `ANCHOR_TOP` = top-center of the row). Spell **names re-resolve at render
   time** (`SpellNameAt`). **Amount is signed** — `-` for damage, `+` for heals —
   coloured red / green (`FormatFull`). **`% Max HP` = the HP level at that moment**
   (`PctAtT`, same value as the graph curve there), number on the LEFT + a flat bar
   of that length (green heal / red damage). The **Type pill** is **semantic**:
   `Hit`/`DoT` red, `Heal`/`HoT` green (periodic = `ev.periodic`). KB row = strong
   red. `▼ Scroll for more` hint when it overflows. Both scrollbars are restyled
   thin/gray with chevron arrows + a chunky thumb (`StyleScrollbar`).
5. **Damage sources** — preceded by a **divider**; **gray** caps header. A
   **scrollable** list (`srcScroll`, `SRC_VISIBLE_ROWS` 5) of one **flat bar per
   attacker** (icon · name · bar · pct · raw total), sorted desc; primary
   brightest. Then a **divider** and a **centered** `Total Damage <grand> 100%` row.
6. **Footer** — preceded by a **divider**; `DIFFICULTY • ZONE • NS WINDOW`
   (uppercase, **gray**) + `/bdr` hint.

Marker pins use spell-icon textures; the on-curve dot, the death dot + glow use
`Interface\COMMON\Indicator-Gray` / `Interface\Buttons\UI-ActionButton-Border`.
`% Max HP` per row = `before% − after%` off the curve (no `maxHP` field needed) —
that share also drives the row's mini-bar width. The Analyzer puts **heals** in
`report.hits` (with `kind`) and a representative `spellID` on each source.

> Still not faked: the **absorb shield line** (no absorb-over-time data) and the
> "click an event to scroll/select the row" affordance (hover-sync is implemented;
> click-to-scroll is not).

---

## Slash commands (Commands.lua)
- `/bdr` — toggle the window (shows last report if one exists).
- `/bdr test` — render the built-in sample report (UI iteration without dying).
- `/bdr history` — show the most recent saved death.
- `/bdr lock` / `/bdr unlock` — toggle drag-to-move.
- `/bdr debug` — print which `C_DeathRecap` API is present + events read (diagnostics).

---

## Edge cases (handle from the start)
- No new recap on `PLAYER_DEAD` → do nothing, don't error.
- Missing `overkill` / `absorbed` → hide gracefully.
- Environmental death with nil source → label by environmental type.
- Repeated deaths while already dead → `PLAYER_DEAD` fires once; ignore extras.
- Empty combatant/event list → minimal "No recap data" state.

---

## Status / build order
1. ✅ Repo scaffolded (SmartLFG layout + tooling).
2. ✅ CLAUDE.md written.
3. ✅ `.toc` + Constants + Core skeleton.
4. ✅ HealthTracker (sampling + snapshot).
5. ✅ Analyzer (C_DeathRecap → DeathReport + sample report).
6. ✅ Display (banner, HP graph, timeline, sources, footer) — HP graph included.
7. ✅ Commands (`/bdr`, `/bdr test`, `/bdr history`, lock/unlock).
8. ✅ SavedVariables (position, lock, last report) — see `DB_DEFAULTS` in Core.lua.
9. ✅ `make lint` clean (luacheck, 0 warnings). `make build` produces a correct
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
