local _, BDR = ...

-- ── Tuning ──────────────────────────────────────────────────────────────────
-- The HP-curve window and sampling behaviour. Kept small and event-driven so
-- the addon stays near-zero cost (see CLAUDE.md design principles).
BDR.CONFIG = {
    WINDOW_SECONDS = 8,    -- length of the HP curve / timeline window shown
    MAX_SAMPLES    = 240,  -- hard cap on the rolling health buffer (safety bound)
    MAX_TIMELINE   = 8,    -- max hit rows rendered in the timeline (oldest dropped;
                           -- bounded so the right column can't run past the graph)
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
-- Killing blow = red; heavy non-lethal hit = amber; normal hits = neutral gray.
BDR.UI = {
    BG          = { 0.05, 0.05, 0.06, 0.92 },  -- frame background
    BORDER_GOLD = { 0.65, 0.55, 0.25, 1.00 },

    KILL_RED    = { 0.90, 0.20, 0.20, 1.00 },
    HEAVY_AMBER = { 0.95, 0.70, 0.20, 1.00 },
    NORMAL_GRAY = { 0.70, 0.70, 0.72, 1.00 },

    SOURCE_PRIMARY = { 0.55, 0.35, 0.85, 1.00 },  -- primary attacker bar (purple)
    SOURCE_OTHER   = { 0.45, 0.45, 0.48, 1.00 },  -- secondary attacker bars

    -- HP curve colour stops (line shifts green → amber → red as health drops).
    HP_GOOD = { 0.30, 0.85, 0.35 },  -- >= 50%
    HP_MID  = { 0.95, 0.70, 0.20 },  -- 25–50%
    HP_LOW  = { 0.90, 0.20, 0.20 },  -- < 25%

    GRID    = { 1.00, 1.00, 1.00, 0.08 },  -- 25/50/75% gridlines
    FILL    = { 0.40, 0.55, 0.80, 0.18 },  -- area beneath the HP curve
}

-- ── Environmental death labels ──────────────────────────────────────────────
-- Blizzard exposes environmental deaths with sentinel (negative) spellIDs and a
-- nil source. Map what we can; fall back to a generic label otherwise. The
-- numeric keys mirror COMBATLOG environmental subtypes where known — verify
-- against the live API (see docs/API-NOTES.md) before trusting specific IDs.
BDR.ENVIRONMENT = {
    [-2] = "Drowning",
    [-3] = "Falling",
    [-4] = "Fatigue",
    [-5] = "Fire",
    [-6] = "Lava",
    [-7] = "Slime",
}
BDR.ENVIRONMENT_FALLBACK = "Environment"
