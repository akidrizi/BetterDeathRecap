local addonName, BDR = ...

-- ── Small shared utilities ──────────────────────────────────────────────────
function BDR.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(
        BDR.COLOR.ADDON .. "[BetterDeathRecap]" .. BDR.COLOR.RESET .. " " .. tostring(msg)
    )
end

function BDR.GetVersion()
    return (C_AddOns and C_AddOns.GetAddOnMetadata
        and C_AddOns.GetAddOnMetadata(addonName, "Version")) or "dev"
end

-- ── SavedVariables ──────────────────────────────────────────────────────────
-- Account-wide for SETTINGS (window position, lock, scale, minimap). The last
-- death report is stored PER-CHARACTER under `deaths[name-realm]` so each character
-- sees only its own latest death (not whoever died most recently account-wide).
local DB_DEFAULTS = {
    locked           = false,
    point            = { "CENTER", "UIParent", "CENTER", 0, 80 },
    scale            = 1.0,   -- slider baseline (applied as scale × CONFIG.SCALE_BASE)
    sourcesCollapsed = true,  -- Damage Sources list starts collapsed (Total Damage only)
    minimapShown     = true,  -- show the minimap button
    minimapAngle     = 200,   -- minimap button position (degrees around the ring)
}

-- Per-character key for the saved death report.
local function CharKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

-- The current character's last death report (per-character; not account-wide).
function BDR.GetLastReport()
    local d = BetterDeathRecapDB and BetterDeathRecapDB.deaths
    return d and d[CharKey()]
end

function BDR.SetLastReport(report)
    if not BetterDeathRecapDB then return end
    BetterDeathRecapDB.deaths = BetterDeathRecapDB.deaths or {}
    BetterDeathRecapDB.deaths[CharKey()] = report
end

local function InitDB()
    BetterDeathRecapDB = BetterDeathRecapDB or {}
    for k, v in pairs(DB_DEFAULTS) do
        if BetterDeathRecapDB[k] == nil then
            BetterDeathRecapDB[k] = v
        end
    end
    BetterDeathRecapDB.deaths = BetterDeathRecapDB.deaths or {}
    -- Drop the old account-wide death report (now per-character) so it can't leak
    -- another character's death into this one.
    BetterDeathRecapDB.lastReport = nil
    -- One-time scale rebaseline: the slider's 1.0 now renders at the old 1.3 size
    -- (Display multiplies by CONFIG.SCALE_BASE). Reset a previously-saved scale once
    -- so it isn't double-applied.
    if not BetterDeathRecapDB.scaleRebased then
        BetterDeathRecapDB.scale = 1.0
        BetterDeathRecapDB.scaleRebased = true
    end
    BDR.DB = BetterDeathRecapDB
end

-- ── Death handling ──────────────────────────────────────────────────────────
-- Build a report from the live C_DeathRecap data, persist it, surface the
-- "Better Recap" button, and refresh the window if it's open. We do NOT auto-open
-- the window (it would cover the release dialog) — the player opens it via the
-- button or /bdr.
--
-- The recap can take a moment to populate after PLAYER_DEAD (and a second death
-- after resurrecting must replace the first), so we rebuild several times and
-- keep the NEWEST death (compared by killedAt) — never letting a stale earlier
-- recap overwrite a newer one.
local function BuildAndStore()
    local report = BDR.Analyzer:Build()
    if report and not report.empty then
        local prev = BDR.GetLastReport()
        if not (prev and prev.killedAt) or (report.killedAt or 0) >= prev.killedAt then
            BDR.SetLastReport(report)
            if BDR.Display and BDR.Display.RefreshIfShown then
                BDR.Display:RefreshIfShown(report)
            end
        end
    end
    if BDR.RecapButton then BDR.RecapButton:OnDeath() end
    return report
end

local function OnPlayerDead()
    -- Rebuild a few times as the recap populates; BuildAndStore keeps the newest.
    if C_Timer and C_Timer.After then
        for _, delay in ipairs({ 0.3, 1.0, 2.0, 3.5 }) do
            C_Timer.After(delay, BuildAndStore)
        end
    else
        BuildAndStore()
    end
end

-- ── Event wiring ────────────────────────────────────────────────────────────
local frame = CreateFrame("Frame", "BetterDeathRecapCore", UIParent)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("PLAYER_ALIVE")
frame:RegisterEvent("PLAYER_UNGHOST")
frame:RegisterUnitEvent("UNIT_HEALTH", "player")

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then
            InitDB()
            if BDR.Options then BDR.Options:Init() end
            if BDR.Minimap then BDR.Minimap:Init() end
            BDR.Print(BDR.COLOR.GRAY .. BDR.L.WELCOME:format(BDR.GetVersion()) .. BDR.COLOR.RESET)
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- New world/instance: any buffered health is stale relative to the
        -- fresh fight, so start clean.
        BDR.HealthTracker:Clear()
        -- Re-place the minimap button now that ALL addons have loaded (a square-
        -- minimap addon may define GetMinimapShape() only after our ADDON_LOADED).
        if BDR.Minimap then BDR.Minimap:Reposition() end

    elseif event == "UNIT_HEALTH" then
        BDR.HealthTracker:Sample()

    elseif event == "PLAYER_DEAD" then
        OnPlayerDead()

    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        -- Resurrected / released and back up: drop the on-death button.
        if BDR.RecapButton then BDR.RecapButton:OnAlive() end
    end
end)
