# C_DeathRecap — API notes

## CONFIRMED in-game (Midnight, via `/bdr debug` enumeration)

Functions actually present on `C_DeathRecap`:
```
C_DeathRecap.HasRecapEvents(recapID)     -- bool; recap id 1 = most recent
C_DeathRecap.GetRecapEvents(recapID)     -- array of events (ordered newest-first)
C_DeathRecap.GetRecapMaxHealth(recapID)  -- number (⚠ observed implausibly large — don't trust as 100%)
C_DeathRecap.GetRecapLink(recapID)       -- chat link
-- global OpenDeathRecapUI(recapID), global frame DeathRecapFrame
```
The previously-assumed `HasNewDeathRecap`/`GetCombatants`/`GetDeathRecapEvents`
do **not** exist.

### Real event shape (dump of one SWING_DAMAGE event)
```
amount=41099            -- damage (positive here; we take |amount|)
currentHP=1219          -- player's health AT this hit (use for the HP curve)
overkill=39880          -- on the killing blow
absorbed=<n>            -- when present
event=SWING_DAMAGE      -- CLEU subevent: SWING_* = melee (no spell),
                        --   SPELL_*/RANGE_* = spell (spellId/spellName),
                        --   ENVIRONMENTAL_* = environment (environmentalType)
sourceName=Normal Tank Dummy   -- ATTACKER (field is sourceName, NOT name)
sourceGUID / sourceFlags / destName / destGUID / destFlags
school=1  critical=false  crushing=false  glancing=false  isOffHand=false
hideCaster=false
timestamp=1781110132.094  -- epoch seconds (real; sort by this)
-- spell events additionally carry spellId (and possibly spellName)
```
`currentHP` is the health the player had when the hit landed (KB example:
1219 HP, hit of 41099 with 39880 overkill → effective 1219 → 0/death).
**Curve is normalised to peak observed `currentHP`**, since `GetRecapMaxHealth`
returned ~420k against a ~179.5k real max.

### What a "recap" IS (confirmed) — a fixed-COUNT buffer, not a time window
`GetRecapEvents` returns the **last N damage events** the player took (observed
N=10), **not** a time window and **not** combat-bounded. If the fatal fight had
fewer than N damage events, the buffer is padded with leftovers from an EARLIER
fight — seen as a large time gap (e.g. 6 events at 0…-6s, then a 73s jump to 4
events at -79…-82s from a previous death). Blizzard's own UI avoids this by only
showing the last ~5 and assuming they're recent.
→ We trim to the fatal fight via gap detection: keep only the most-recent
contiguous cluster, cutting at the first inter-event gap > `FIGHT_GAP_SECONDS`
(Constants, default 10s). See `Analyzer:Build`.

### More confirmed field details
- `overkill` / `absorbed` use **-1 as a "none" sentinel** (also: only treat > 0
  as real). Heal events carry `event` containing `HEAL` (e.g. SPELL_HEAL,
  SPELL_PERIODIC_HEAL) and must be excluded from the damage timeline/sources but
  kept for the HP curve.
- **Recap ids INCREMENT per death** (observed id 9, then 10, …) and the kept set
  slides upward — the newest death is the **HIGHEST valid id**, NOT id 1 and NOT
  a fixed 1..N range. A scan capped at 10 goes permanently stale once the death
  count passes 10 ("same recap forever / 47k 13k-overkill every time"). Find the
  newest by scanning upward for the highest id where `HasRecapEvents(id)` is true
  (`MostRecentRecapID`). `DEATHRECAP_NUM_RECAPS` appears nil on this client.
- `GetRecapMaxHealth` is reliable when the *right* (newest) recap id is read
  (176060, matching the player); implausible values came from reading a stale id.
- `currentHP` = the player's health **immediately BEFORE that hit** (verified by
  the chain: KB `hp − (amount − overkill) = 0`, and each hit's `hp − amount` =
  the next hit's `hp`). Drives the HP curve directly.
- A recap may contain **only damage events** (no SPELL_HEAL rows) yet `currentHP`
  still rises between hits when a heal occurred — so the curve shows heal bumps
  even though there's no heal row to list. Don't assume heals appear as events.

---

# (historical notes below — superseded by the confirmed section above)

Working notes on the `C_DeathRecap` data shapes this addon depends on. **Verify
every field against the live client before relying on it** — availability
(especially `overkill` and absorb data) varies by patch. Code defensively:
fall back to "unknown source" / hide a field rather than erroring.

## Functions

```
C_DeathRecap.HasNewDeathRecap()         -- bool; true after PLAYER_DEAD when a recap exists
C_DeathRecap.GetCombatants()            -- list of attacker entries
C_DeathRecap.GetEvents(combatantIndex)  -- per-attacker event list
OpenDeathRecapUI()                      -- Blizzard's native UI (reference only; do not depend on)
```

`Blizzard_DeathRecap` (the stock addon) is the canonical reference for the data
shape — inspect it in-game with `/dump` or an addon like `BugSack`/`!BugGrabber`.

## Event entry fields (per `GetEvents`)

Observed / expected fields on each event. **Treat all as possibly-nil.**

| Field        | Type    | Notes                                                       |
| ------------ | ------- | ----------------------------------------------------------- |
| `spellID`    | number  | Use with `C_Spell.GetSpellTexture` (or `GetSpellTexture`).  |
| `spellName`  | string  | May be nil for melee / environmental.                       |
| `amount`     | number  | Damage amount (negative for some healing entries?).         |
| `timestamp`  | number  | Epoch-ish; used only for relative ordering.                 |
| `school`     | number  | Spell school bitmask (optional, for colouring later).       |
| `isCritical` | bool    | Optional.                                                   |
| `overkill`   | number  | **Patch-variable.** Hide if nil/negative.                   |
| `absorbed`   | number  | **Patch-variable.** Show as a secondary line when present.  |

## Combatant entry fields (per `GetCombatants`)

| Field        | Type    | Notes                                              |
| ------------ | ------- | -------------------------------------------------- |
| `name`       | string  | Attacker name; nil → environmental / unknown.      |
| `guid`       | string  | Optional.                                          |
| `unit`       | string  | Optional unit token.                               |

## Environmental deaths

When the source is nil, label by environmental type. Blizzard exposes these as
negative/sentinel spell IDs in the stock UI; we map by name where possible and
otherwise fall back to a generic "Environment" label. Known types to handle:
**Falling, Drowning, Fire, Lava, Slime, Fatigue.**

## Health-over-time curve

`C_DeathRecap` does **not** provide HP-over-time. We reconstruct it from our own
`UNIT_HEALTH` samples (see `HealthTracker.lua`): a rolling buffer of
`{ t, hp, hpMax }` over the configured window, normalised to health % and the
window length at report time.

## Verification checklist (do this in-game)

- [ ] Confirm `GetEvents` returns chronological or reverse-chronological order.
- [ ] Confirm whether `overkill` is present on the killing blow this patch.
- [ ] Confirm whether `absorbed` is present and its sign.
- [ ] Confirm combatant `name` is nil for environmental deaths.
- [ ] Confirm `C_Spell.GetSpellTexture` exists (newer API) vs `GetSpellTexture`.
