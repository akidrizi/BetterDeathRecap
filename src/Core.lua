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
-- Account-wide. Holds window position, lock state, and the last death report so
-- /bdr history works across sessions.
local DB_DEFAULTS = {
    locked     = false,
    point      = { "CENTER", "UIParent", "CENTER", 0, 80 },
    scale      = 1.0,   -- window scale (0.9–2.0), driven by the title-bar slider
    lastReport = nil,
}

local function InitDB()
    BetterDeathRecapDB = BetterDeathRecapDB or {}
    for k, v in pairs(DB_DEFAULTS) do
        if BetterDeathRecapDB[k] == nil then
            BetterDeathRecapDB[k] = v
        end
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
        local prev = BDR.DB.lastReport
        if not (prev and prev.killedAt) or (report.killedAt or 0) >= prev.killedAt then
            BDR.DB.lastReport = report
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
            BDR.Print(BDR.COLOR.GRAY .. BDR.L.WELCOME:format(BDR.GetVersion()) .. BDR.COLOR.RESET)
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- New world/instance: any buffered health is stale relative to the
        -- fresh fight, so start clean.
        BDR.HealthTracker:Clear()

    elseif event == "UNIT_HEALTH" then
        BDR.HealthTracker:Sample()

    elseif event == "PLAYER_DEAD" then
        OnPlayerDead()

    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        -- Resurrected / released and back up: drop the on-death button.
        if BDR.RecapButton then BDR.RecapButton:OnAlive() end
    end
end)
