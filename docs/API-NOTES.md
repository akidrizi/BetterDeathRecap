# C_DeathRecap — API notes

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
