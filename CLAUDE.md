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
│   ├── HealthTracker.lua       -- UNIT_HEALTH sampling -> rolling {t, hp, hpMax}
│   ├── Analyzer.lua            -- C_DeathRecap data -> DeathReport (+ sample report)
│   ├── Display.lua             -- renders the frame incl. the HP graph
│   ├── Commands.lua            -- /bdr slash commands
│   └── Core.lua                -- bootstrap, event registration, orchestration
├── BetterDeathRecap.toc        -- AT REPO ROOT. Interface 120000 (Midnight)
├── {.editorconfig, .gitattributes, .gitignore, .luacheckrc}
├── {Makefile, package.sh, pkgmeta.yaml}
├── {CHANGELOG.md, LICENSE.md (MIT), README.md, CLAUDE.md, PLAN.md}
```

### `.toc` load order
`Constants → HealthTracker → Analyzer → Display → Commands → Core`
(Core is last so every module it orchestrates is already defined.)
`.toc` paths use backslashes (`src\Core.lua`).

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

```
C_DeathRecap.HasNewDeathRecap()         -- true after PLAYER_DEAD when a recap is available
C_DeathRecap.GetCombatants()            -- list of attackers (name, guid, …)
C_DeathRecap.GetEvents(combatantIndex)  -- per-attacker events
  -- event fields (all possibly-nil, verify per patch):
  --   spellID, spellName, amount, timestamp, school, isCritical, overkill, absorbed
```

Cautions (see `docs/API-NOTES.md`):
- Field availability (especially `overkill`, `absorbed`) varies by patch — code
  defensively, hide a field rather than erroring.
- Environmental deaths may have a nil source — label by environmental type
  (Falling, Drowning, Fire, Lava, Slime, Fatigue).
- `OpenDeathRecapUI()` / `Blizzard_DeathRecap` are reference only — do not
  depend on them for our UI.
- Spell texture: prefer `C_Spell.GetSpellTexture(spellID)`, fall back to the
  global `GetSpellTexture(spellID)`.

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
frame:RegisterEvent("PLAYER_ENTERING_WORLD")     -- clear stale health buffer
frame:RegisterEvent("PLAYER_DEAD")               -- build + show report
frame:RegisterUnitEvent("UNIT_HEALTH", "player") -- lightweight sampling

PLAYER_DEAD:           if C_DeathRecap.HasNewDeathRecap() then
                         report = Analyzer:Build(HealthTracker:Snapshot())
                         Display:Show(report); persist to DB
                       end
UNIT_HEALTH:           HealthTracker:Sample()
PLAYER_ENTERING_WORLD: HealthTracker:Clear()
```

---

## UI / display spec (Display.lua)

Dark, WoW-styled frame with a gold border. Sections top→bottom:
1. **Title bar** — addon name + utility actions (History, Pin/Lock, close X).
2. **Killing-blow banner** — red-accented, pinned at top:
   `Source · Spell · Amount (Xk overkill)`.
3. **Body, two columns:**
   - **Left: HP curve** ("HP · last Ns"). Polyline of health % over the window
     with a filled area beneath; line colour shifts green → amber → red as
     health drops. Gridlines at 25/50/75%. A dot marks the death point. x-axis
     labels `-Ns … death`.
   - **Right: hit timeline.** Columns: `t` (relative), `source · ability` (with
     a small spell-icon swatch), `dmg` (right-aligned). Chronological, oldest at
     top. Killing-blow row pinned at the bottom, highlighted red, tagged
     `KILLING BLOW` with `+Xk overkill`. Absorbed amounts as a small secondary
     line when present.
4. **Damage sources** — horizontal bars per attacker: name, `pct% · total`,
   proportional bar. Primary attacker purple accent; others gray.
5. **Footer** — context line (`Difficulty · Zone · Ns window`) + `/bdr` hint.

Colour families: killing blow = red; heavy non-lethal hit = amber; normal hits
= neutral gray. Spell-icon swatches are small bordered squares.

The **HP graph is implemented in v1** (not deferred). Drawn with a pool of
`Line` objects (curve), textures (fill columns + gridlines), and a death dot.

---

## Slash commands (Commands.lua)
- `/bdr` — toggle the window (shows last report if one exists).
- `/bdr test` — render the built-in sample report (UI iteration without dying).
- `/bdr history` — show the most recent saved death.
- `/bdr lock` / `/bdr unlock` — toggle drag-to-move.

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
