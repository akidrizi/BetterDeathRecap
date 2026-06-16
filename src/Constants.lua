local _, BDR = ...

-- ── Tuning ──────────────────────────────────────────────────────────────────
-- The HP-curve window and sampling behaviour. Kept small and event-driven so
-- the addon stays near-zero cost (see CLAUDE.md design principles).
BDR.CONFIG = {
    WINDOW_SECONDS = 8,    -- minimum HP-curve / timeline window (grows to fit the fight)
    MAX_SAMPLES    = 240,  -- hard cap on the rolling health buffer (safety bound)
    MAX_TIMELINE   = 8,    -- max hit rows rendered in the timeline (oldest dropped;
                           -- bounded so the right column can't run past the graph)
    -- The death recap is a fixed-COUNT buffer of the last N damage events, so it
    -- can include hits from an earlier fight. We keep only the most-recent
    -- contiguous cluster: a gap between consecutive events larger than this many
    -- seconds is treated as the boundary of the fight that actually killed you.
    FIGHT_GAP_SECONDS = 10,

    -- Title-bar scale slider. The slider shows 0.9–2.0; the value is MULTIPLIED by
    -- SCALE_BASE before being applied, so the comfortable baseline (slider 1.0)
    -- renders at 1.3× — i.e. "1.0 on the slider" == the old 1.3 size.
    SCALE_MIN  = 0.9,
    SCALE_MAX  = 2.0,
    SCALE_BASE = 1.3,
}

-- ── Chat colour escapes ─────────────────────────────────────────────────────
BDR.COLOR = {
    ADDON = "|cffff5555",  -- addon brand red (death theme)
    WARN  = "|cffffcc00",
    OK    = "|cff00ff00",
    GRAY  = "|cff999999",
    RESET = "|r",
}

-- ── UI palette (RGB 0–1, for textures / FontStrings) ────────────────────────
-- "Dragonflight-era" theme from PLAN.md / DESIGN: near-black bg, gold accents,
-- red damage, green heal, blue absorb. (Hex values noted per token.)
BDR.UI = {
    BG          = { 0.039, 0.039, 0.051, 0.70 },  -- frame background  (#0A0A0D, alpha 0.7)
    GOLD        = { 0.784, 0.635, 0.353, 1.00 },  -- borders / headers / separators (#C8A25A)
    BORDER_GOLD = { 0.784, 0.635, 0.353, 1.00 },  -- (alias of GOLD, used by backdrop)
    BORDER_GRAY = { 0.420, 0.420, 0.450, 1.00 },  -- frame edge + header divider (gray)
    TEXT        = { 0.941, 0.902, 0.824, 1.00 },  -- primary text  (#F0E6D2)
    TEXT_DIM    = { 0.659, 0.639, 0.604, 1.00 },  -- secondary text / section headers (gray)
    NAME_YELLOW = { 1.000, 0.820, 0.000, 1.00 },  -- WoW unit-name yellow (killer name)
    DIVIDER     = { 0.231, 0.216, 0.196, 1.00 },  -- thin section divider lines

    DAMAGE      = { 0.890, 0.290, 0.290, 1.00 },  -- damage  (#E34A4A)
    HEAL        = { 0.278, 0.839, 0.420, 1.00 },  -- healing (#47D66B)
    ABSORB      = { 0.325, 0.659, 1.000, 1.00 },  -- absorb  (#53A8FF)

    KILL_RED    = { 0.890, 0.290, 0.290, 1.00 },
    HEAVY_AMBER = { 0.95, 0.70, 0.20, 1.00 },
    NORMAL_GRAY = { 0.70, 0.70, 0.72, 1.00 },

    SOURCE_PRIMARY = { 0.890, 0.290, 0.290, 1.00 },  -- primary attacker bar (red, brightest)
    SOURCE_OTHER   = { 0.62, 0.26, 0.26, 1.00 },     -- secondary attacker bars (dim red)

    -- HP curve colour: green normally, deep red only below 25% (no mid stop).
    HP_GOOD = { 0.278, 0.839, 0.420 },  -- >= 25%
    HP_MID  = { 0.94, 0.62, 0.15 },     -- tooltip accent only (not used on the curve)
    HP_LOW  = { 0.74, 0.12, 0.12 },     -- < 25% (deep red)

    -- Theming tokens.
    TITLE_GOLD   = { 0.784, 0.635, 0.353 },  -- killer name (gold)
    SPELL_PURPLE = { 0.78, 0.60, 1.00 },     -- spell names
    ABSORB_BLUE  = { 0.325, 0.659, 1.000 },  -- absorb shield overlay
    HEAL_GREEN   = { 0.278, 0.839, 0.420 },  -- heal markers

    -- One unified panel background shared by the graph canvas AND the table rows
    -- (~15% darker than the old per-element darks), so they read as one surface.
    PANEL_BG     = { 0.047, 0.047, 0.064, 1.00 },
    CANVAS_BG    = { 0.055, 0.055, 0.075, 1.00 },  -- (kept; PANEL_BG is used now)
    ROW_ALT      = { 0.075, 0.075, 0.090, 1.00 },  -- (kept; PANEL_BG is used now)
    ROW_KB_BG    = { 0.200, 0.055, 0.055, 1.00 },  -- killing-blow table row
}

-- Tombstone marker shown at the death point on the graph. We tried the brown
-- `inv_misc_coffin_01` texture but it rendered blank in the live client, so this
-- skull icon is the guaranteed-present fallback. Swap the path here to use a
-- different texture; a wrong/missing path renders blank rather than erroring.
BDR.DEATH_ICON      = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01"
-- Size (px) of the tombstone marker on the graph x-axis. Change here to resize.
BDR.DEATH_ICON_SIZE = 18

-- ── Environmental death labels ──────────────────────────────────────────────
-- Blizzard exposes environmental deaths with sentinel (negative) spellIDs and a
-- nil source. Map the sentinel to a locale key (resolved via BDR.L in the
-- Analyzer); unmapped sentinels fall back to L.ENV_UNKNOWN. The numeric keys
-- mirror COMBATLOG environmental subtypes where known — verify against the live
-- API (see docs/API-NOTES.md) before trusting specific IDs.
BDR.ENVIRONMENT = {
    [-2] = "ENV_DROWNING",
    [-3] = "ENV_FALLING",
    [-4] = "ENV_FATIGUE",
    [-5] = "ENV_FIRE",
    [-6] = "ENV_LAVA",
    [-7] = "ENV_SLIME",
}

-- Environmental deaths have NO spell (so no spell icon), but Blizzard still shows
-- a representative icon. We map each environmental type (the UPPERCASED CLEU token,
-- e.g. "FALLING") to a stock icon. UNKNOWN is the catch-all. (Verify the texture
-- paths in-game; a wrong path renders blank rather than erroring.)
BDR.ENV_ICONS = {
    DROWNING = "Interface\\Icons\\Spell_Shadow_DemonBreath",
    FALLING  = "Interface\\Icons\\Spell_Magic_FeatherFall",
    FATIGUE  = "Interface\\Icons\\Spell_Nature_Sleep",
    FIRE     = "Interface\\Icons\\Spell_Fire_Fire",
    LAVA     = "Interface\\Icons\\Spell_Fire_Volcano",
    SLIME    = "Interface\\Icons\\Spell_Nature_CorrosiveBreath",
    UNKNOWN  = "Interface\\Icons\\Ability_Creature_Cursed_05",
}

-- ── Damage-school colours (graph dots + tooltip school name) ─────────────────
-- Keyed by WoW's SCHOOL_MASK_* single-bit values. Combined schools (multi-bit)
-- are resolved by Display:SchoolInfo, which falls back to a representative bit.
-- (School names are English here; they are niche tooltip text, not localized.)
BDR.SCHOOL = {
    [1]  = { name = "Physical", color = { 1.00, 0.90, 0.40 } },
    [2]  = { name = "Holy",     color = { 1.00, 0.95, 0.55 } },
    [4]  = { name = "Fire",     color = { 1.00, 0.48, 0.20 } },
    [8]  = { name = "Nature",   color = { 0.35, 0.95, 0.40 } },
    [16] = { name = "Frost",    color = { 0.50, 0.90, 1.00 } },
    [32] = { name = "Shadow",   color = { 0.62, 0.45, 0.92 } },
    [64] = { name = "Arcane",   color = { 0.95, 0.55, 1.00 } },
}
