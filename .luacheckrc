-- .luacheckrc
-- Luacheck configuration for BetterDeathRecap
-- https://luacheck.readthedocs.io/en/stable/config.html

-- WoW embeds Lua 5.1
std = "lua51"

-- Maximum line length (matches .editorconfig)
max_line_length = 120

-- Ignore warnings we explicitly don't care about:
--   212/self — our singleton modules expose a colon API (Analyzer:Build,
--              Display:Show, …) for a consistent call site, but the methods
--              reference module upvalues rather than `self`. Silence only the
--              unused-`self` case, not unused arguments in general.
ignore = { "212/self" }

-- ── WoW API globals ────────────────────────────────────────────────────────
-- Everything the WoW client injects into the global environment.
-- Listed here so luacheck doesn't flag them as undefined globals.
-- Keep this list in sync with what src/ actually references.
globals = {
    -- Addon saved variable (declared in BetterDeathRecap.toc)
    "BetterDeathRecapDB",

    -- Death Recap API — the data source this addon renders
    "C_DeathRecap",

    -- Unit / health queries (HealthTracker sampling)
    "UnitHealth",
    "UnitHealthMax",
    "UnitGUID",
    "UnitName",
    "UnitExists",

    -- Spell info (icon swatches in the timeline)
    "C_Spell",
    "GetSpellTexture",

    -- World / context info (footer line)
    "GetRealZoneText",
    "GetInstanceInfo",
    "GetDifficultyInfo",

    -- Lua/WoW table helpers injected globally by the client
    "wipe",

    -- UI / frame
    "CreateFrame",
    "UIParent",
    "GameTooltip",
    "DEFAULT_CHAT_FRAME",
    "GetTime",
    "UISpecialFrames",
    "GameFontNormal",
    "GameFontNormalLarge",
    "GameFontHighlight",
    "GameFontHighlightSmall",
    "GameFontDisableSmall",
    "NORMAL_FONT_COLOR",
    "BackdropTemplateMixin",

    -- C_* namespaces
    "C_AddOns",
    "C_Timer",

    -- Slash command registration
    "SLASH_BETTERDEATHRECAP1",
    "SLASH_BETTERDEATHRECAP2",
    "SlashCmdList",
}

-- ── Per-file overrides ─────────────────────────────────────────────────────
files = {
    ["src/Constants.lua"] = {
        -- Constants intentionally uses the addon table from vararg, which
        -- luacheck sees as an implicit global write. Suppress that warning.
        ignore = { "111" },
    },
}
