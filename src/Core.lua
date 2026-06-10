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
-- Build a report from the live C_DeathRecap data + our health snapshot, persist
-- it, and show the window. Guarded so a missing/empty recap is a no-op, never an
-- error (PLAYER_DEAD can fire without a fresh recap).
local function OnPlayerDead()
    if not (C_DeathRecap and C_DeathRecap.HasNewDeathRecap) then return end
    if not C_DeathRecap.HasNewDeathRecap() then return end

    local report = BDR.Analyzer:Build(BDR.HealthTracker:Snapshot())
    if not report then return end

    BDR.DB.lastReport = report
    BDR.Display:Show(report)
end

-- ── Event wiring ────────────────────────────────────────────────────────────
local frame = CreateFrame("Frame", "BetterDeathRecapCore", UIParent)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterUnitEvent("UNIT_HEALTH", "player")

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then
            InitDB()
            BDR.Print(BDR.COLOR.GRAY .. "v" .. BDR.GetVersion()
                .. " loaded. Type /bdr for the window, /bdr test for a demo." .. BDR.COLOR.RESET)
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- New world/instance: any buffered health is stale relative to the
        -- fresh fight, so start clean.
        BDR.HealthTracker:Clear()

    elseif event == "UNIT_HEALTH" then
        BDR.HealthTracker:Sample()

    elseif event == "PLAYER_DEAD" then
        OnPlayerDead()
    end
end)
