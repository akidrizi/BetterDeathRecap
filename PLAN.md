# BetterDeathRecap — Build Plan for Claude Code

## Your task

Build the initial version of **BetterDeathRecap**, a World of Warcraft (retail / Midnight) addon
that replaces Blizzard's poor built-in death recap with a clean, readable custom UI.

Before writing any code, **create a `CLAUDE.md`** in the project root capturing all the context
below. **Update `CLAUDE.md` on every meaningful change** — new modules, API decisions, data-shape
changes, scope changes. Treat it as the single source of truth for future sessions.

---

## What this addon is

A **display layer** on top of Blizzard's `C_DeathRecap` API. Blizzard collects the death data;
we render it well. We do **not** parse the combat log — addons cannot access CLEU on Midnight, which
is exactly why the dominant addon (Death Note, 755K downloads) has gone dark and why this niche is open.

The one thing `C_DeathRecap` does not provide is a health-over-time curve, so we supplement it with
lightweight `UNIT_HEALTH` sampling (event-driven, not polled).

### Non-negotiable design principles
- **Near-zero performance cost.** Only one always-on event: `PLAYER_DEAD`. `UNIT_HEALTH` is registered
  per-unit for `player` and is event-driven. No CLEU. No timers polling every frame.
- **Read-only.** We only read data Blizzard explicitly exposes. No protected actions, ban-safe.
- **Self-contained.** No dependency on Details! or any other addon.
- **Small.** Target ~300–400 lines total across modules.

---

## Data source — the API

```
C_DeathRecap.HasNewDeathRecap()         -- true after PLAYER_DEAD when a recap is available
C_DeathRecap.GetCombatants()            -- list of attackers (name, guid, etc.)
C_DeathRecap.GetEvents(combatantIndex)  -- per-attacker events
  -- each event includes: spellID, spellName, amount, timestamp, type, isCritical, overkill (when available)
```

Notes / cautions to verify against the live API during development:
- Field availability (especially `overkill` and absorb data) can vary by patch. Code defensively:
  fall back to "unknown source" / hide a field rather than erroring.
- Environmental deaths may have a nil source — label by environmental type (Falling, Drowning, Fire, Lava, Slime).
- `OpenDeathRecapUI()` and `Blizzard_DeathRecap` exist as the native reference — do not depend on them
  for our UI, but they are useful to inspect for the data shape.

---

## Repository structure

Mirror the existing SmartLFG project layout (same tooling: luacheck, BigWigsMods packager,
`pkgmeta.yaml`, Makefile-driven local packaging). Do not flatten the Lua into the repo root —
all addon code lives under `src/`.

```
BetterDeathRecap/
├── .github/
│   └── workflows/
│       ├── ci.yml             -- luacheck lint on push / PR
│       └── release.yml        -- tag-triggered build via BigWigsMods packager
├── dist/                      -- packaged .zip output (git-ignored, produced by package.sh)
├── docs/                      -- design notes, API notes, screenshots-for-docs
├── media/                     -- addon art: logo, minimap icon (TGA/PNG), banner for CurseForge
├── src/                       -- addon Lua only (the .toc stays at repo root)
│   ├── Core.lua               -- bootstrap, event registration, orchestration
│   ├── Constants.lua          -- HP window seconds, sample cap, colors, config defaults
│   ├── HealthTracker.lua      -- UNIT_HEALTH sampling -> rolling {time, hp, hpMax} buffer
│   ├── Analyzer.lua           -- C_DeathRecap data -> structured DeathReport table
│   ├── Display.lua            -- renders the frame from a DeathReport (includes the HP graph)
│   └── Commands.lua           -- /bdr slash commands
├── .editorconfig
├── .gitattributes
├── .gitignore                 -- ignores dist/ and editor cruft
├── .luacheckrc                -- WoW globals whitelist for luacheck
├── BetterDeathRecap.toc       -- AT REPO ROOT. Interface: 120000 (Midnight); references src\*.lua; SavedVariables
├── CHANGELOG.md
├── LICENSE.md                 -- MIT
├── Makefile                   -- `make`, `make lint`, `make package`, `make clean`
├── package.sh                 -- local packaging into dist/ (mirrors release.yml)
├── pkgmeta.yaml               -- BigWigsMods packager manifest
└── README.md
```

### Notes on the tooling files (match SmartLFG conventions)
- **The `.toc` lives at the repo root** (next to `README.md`/`Makefile`), NOT inside `src/`. It lists the
  Lua files with the `src\` path prefix, e.g. `src\Core.lua`, `src\Constants.lua`, etc. (WoW `.toc`
  files use backslashes for paths.) Load order in the `.toc`:
  `Constants → HealthTracker → Analyzer → Display → Commands → Core`.
- **The packager** assembles `BetterDeathRecap.toc`, `media/`, and `src/` together into
  `dist/BetterDeathRecap/` — that folder is the addon root the user drops into `Interface/AddOns/`.
- **`.luacheckrc`** must whitelist WoW globals used here: `C_DeathRecap`, `UnitHealth`, `UnitHealthMax`,
  `GetSpellTexture` (and `C_Spell.GetSpellTexture` for newer API), `CreateFrame`, `GetTime`,
  `UnitGUID`, plus the SavedVariables global.
- **`release.yml`** uses the BigWigsMods packager with semver tags (same pattern as SmartLFG's
  `ci.yml` + `release.yml`), publishing to CurseForge/Wago.
- **`media/`** holds the logo and a 64px minimap icon (TGA/PNG), same as SmartLFG.
- **`docs/`** is where API notes (verified `C_DeathRecap` field shapes) and the agreed UI mockup live.

### DeathReport shape (Analyzer output -> Display input)
```lua
DeathReport = {
  killedAt     = <timestamp>,
  killingBlow  = { sourceName, spellName, spellID, amount, overkill },
  events       = { { t, sourceName, spellName, spellID, amount, absorbed, isKillingBlow }, ... }, -- chronological
  sources      = { { name, total, pct }, ... },  -- sorted desc, for the damage-source bars
  healthCurve  = { { t, pct }, ... },            -- from HealthTracker, normalized to the window
  context      = { difficulty, zone, windowSeconds },
}
```

---

## Event wiring (Core.lua)

```lua
frame:RegisterEvent("PLAYER_ENTERING_WORLD")   -- clear stale health buffer
frame:RegisterEvent("PLAYER_DEAD")             -- build + show report
frame:RegisterUnitEvent("UNIT_HEALTH", "player")  -- lightweight sampling

-- PLAYER_DEAD:
--   if C_DeathRecap.HasNewDeathRecap() then
--     report = Analyzer:Build(C_DeathRecap, HealthTracker:Snapshot())
--     Display:Show(report)
--   end
-- UNIT_HEALTH:        HealthTracker:Sample()
-- PLAYER_ENTERING_WORLD: HealthTracker:Clear()
```

---

## UI / display spec

The window should be a clean, dark, WoW-styled frame with a gold border. Sections top to bottom:

1. **Title bar** — addon name + small utility actions: `History`, `Pin`, close (`X`).
2. **Killing blow banner** — pinned at top, red-accented. One line:
   `Source · Spell · Amount (Xk overkill)`. This answers "what killed me" at a glance.
3. **Body — two columns:**
   - **Left: HP curve** ("HP · last 8s"). A polyline of health % over the window with a filled area
     beneath. Line color shifts green → amber → red as health drops. Gridlines at 25/50/75%.
     A dot marks the death point. x-axis labels: `-8s` … `death`.
   - **Right: hit timeline.** Columns: `t` (relative time, e.g. -7.2s), `source · ability` (with a small
     spell-icon swatch via `GetSpellTexture(spellID)`), `dmg` (right-aligned). Chronological,
     oldest at top. The killing blow row is pinned at the bottom, highlighted red, with a
     `KILLING BLOW` tag and `+Xk overkill`. Show absorbed amounts as a small secondary line when present.
4. **Damage sources** — horizontal bars per attacker: name, `pct% · total`, proportional bar.
   Shows whether one mob or a pile-on killed you.
5. **Footer** — context line (`Difficulty · Zone · Xs window`) and a `/bdr toggle` hint.

Visual reference (colors/layout used in the agreed mockup):
- Killing blow: red family. Setup/heavy non-lethal hit: amber. Normal hits: neutral gray text.
- Primary attacker bar can use a purple accent; secondary attackers gray.
- Spell-icon swatches are small bordered squares.

---

## Build order for v1

1. **Scaffold the repo** in the SmartLFG layout above: create `.github/workflows/`, `dist/`, `docs/`,
   `media/`, `src/`, and all root tooling files (`.editorconfig`, `.gitattributes`, `.gitignore`,
   `.luacheckrc`, `Makefile`, `package.sh`, `pkgmeta.yaml`, `CHANGELOG.md`, `LICENSE.md`, `README.md`).
   `ci.yml` (luacheck) and `release.yml` (BigWigsMods packager, semver tags) following SmartLFG.
2. `CLAUDE.md` at repo root — write it first from this plan.
3. `BetterDeathRecap.toc` (repo root) + `src/Constants.lua` + `src/Core.lua` skeleton that registers
   events and prints debug on `PLAYER_DEAD`. Confirm it lints clean (`make lint`) and loads in-game.
4. `src/HealthTracker.lua` — sampling + snapshot, normalized to the window.
5. `src/Analyzer.lua` — turn `C_DeathRecap` data into a `DeathReport`. Include a hardcoded **sample
   report** so Display can be built and tested without dying (drive it via `/bdr test`).
6. `src/Display.lua` — full frame: banner, timeline, damage sources, footer.
7. **HP graph** inside Display — implement this in v1 (do not defer it).
8. `src/Commands.lua` — `/bdr` (toggle), `/bdr test` (sample report), `/bdr history` (last death).
9. SavedVariables: window position, lock/pin state, last death report.
10. Verify `make package` produces `dist/BetterDeathRecap/` containing the `.toc`, `media/`, and `src/`
    at the addon-folder root (same as SmartLFG's `dist/SmartLFG/`), then zipped for release.

### Edge cases to handle from the start
- No new recap on `PLAYER_DEAD` → do nothing, don't error.
- Missing `overkill` / absorb fields → hide gracefully.
- Environmental death with nil source → label by environmental type.
- Repeated deaths while already dead → ignore (PLAYER_DEAD fires once).
- Empty combatant/event list → show a minimal "No recap data" state.

---

## Slash commands
- `/bdr` — toggle the window (show last report if one exists).
- `/bdr test` — render the built-in sample report (for UI iteration without dying).
- `/bdr history` — show the most recent saved death.
- `/bdr lock` / `/bdr unlock` — toggle drag-to-move.

---

## Deliverables for this first session
1. Repo scaffolded in the SmartLFG layout (`.github/`, `dist/`, `docs/`, `media/`, `src/`, tooling files).
2. `CLAUDE.md` written from this plan, and kept updated thereafter.
3. A working, loadable addon with all modules under `src/`.
4. The HP graph implemented (not deferred).
5. `/bdr test` producing the full UI from sample data so it can be reviewed without dying in-game.
6. `ci.yml` linting clean, and `make package` producing a valid zip in `dist/`.

## Reminders for you, Claude Code
- Verify every `C_DeathRecap` field against the live API before relying on it; code defensively.
- Keep it tiny and dependency-free.
- **Update `CLAUDE.md` whenever you change structure, data shapes, or scope.**
