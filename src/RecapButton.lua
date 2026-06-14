local _, BDR = ...

-- RecapButton — a small "Better Recap" button shown on death, sitting to the
-- RIGHT of Blizzard's own "Recap" button so it doesn't overlap the self-res
-- (Soulstone / Reincarnation) controls on the release dialog. Clicking it opens
-- our window with the freshly-built report.
--
-- The release dialog is a recycled StaticPopup (which == "DEATH"). We anchor to
-- it when we can find it; otherwise we fall back to a fixed on-screen spot so
-- the button is always usable. (The exact Blizzard "Recap" sub-button frame name
-- can vary by patch — see docs/API-NOTES.md; verify in-game with /fstack.)

local RecapButton = {}
BDR.RecapButton = RecapButton

local btn

-- Build (once) the freshest report we can and show the window. Prefers a live
-- rebuild from the current recap + the death-time health snapshot, falling back
-- to the stored report, and finally to a friendly "no death" message.
local function OpenReport()
    local report = BDR.DB.lastReport
    local fresh  = BDR.Analyzer:Build()
    if fresh and not fresh.empty then
        BDR.DB.lastReport = fresh
        report = fresh
    end
    if report then
        BDR.Display:Show(report)
    else
        BDR.Print(BDR.COLOR.WARN .. BDR.L.NO_DEATH .. BDR.COLOR.RESET)
    end
end

local function EnsureButton()
    if btn then return btn end
    btn = CreateFrame("Button", "BetterDeathRecapOpenButton", UIParent, "UIPanelButtonTemplate")
    btn:SetSize(104, 22)
    btn:SetText(BDR.L.BTN_RECAP)
    btn:SetFrameStrata("FULLSCREEN_DIALOG")
    btn:Hide()
    btn:SetScript("OnClick", OpenReport)
    return btn
end

-- Find the visible death-release StaticPopup, if one is up. We accept any
-- visible popup whose `which` looks death-related (varies by client), and as a
-- fallback any visible popup that contains a button labelled like "Recap".
local function FindDeathPopup()
    local recapLabel = _G.RECAP or "Recap"
    for i = 1, (STATICPOPUP_NUMDIALOGS or 8) do
        local f = _G["StaticPopup" .. i]
        if f and f:IsShown() then
            local which = tostring(f.which or "")
            if which:find("DEATH") or which:find("RECAP") then
                return f
            end
            for _, child in ipairs({ f:GetChildren() }) do
                if child.GetText and child:IsShown() and child:GetText() == recapLabel then
                    return f
                end
            end
        end
    end
    return nil
end

-- Within the death popup, try to find Blizzard's "Recap" button specifically so
-- we can sit just to its right. Matches by the localized RECAP label when that
-- global exists; otherwise returns nil (caller anchors to the popup edge).
local function FindRecapButton(popup)
    local label = _G.RECAP or "Recap"
    for _, child in ipairs({ popup:GetChildren() }) do
        if child.GetText and child:GetText() == label and child:IsShown() then
            return child
        end
    end
    return nil
end

-- Position the button: right of Blizzard's Recap button if we can pin it,
-- else off the right edge of the death popup, else a fixed screen fallback.
local function Anchor()
    EnsureButton()
    btn:ClearAllPoints()

    local popup = FindDeathPopup()
    if popup then
        btn:SetParent(popup)
        btn:SetFrameStrata("FULLSCREEN_DIALOG")
        local recap = FindRecapButton(popup)
        if recap then
            -- Sit in the dialog's button row as a 4th button: match the Recap
            -- button's size/level and use the same small inter-button gap so the
            -- row reads Release | Reincarnation | Recap | Better Recap.
            local w, h = recap:GetSize()
            if w and w > 0 then btn:SetSize(w, h) end
            btn:SetFrameLevel(recap:GetFrameLevel())
            btn:SetPoint("LEFT", recap, "RIGHT", 4, 0)
        else
            btn:SetPoint("TOPLEFT", popup, "TOPRIGHT", 6, -10)
        end
        return true
    end

    -- Fallback: a fixed spot near the lower-middle of the screen.
    btn:SetParent(UIParent)
    btn:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
    return false
end

-- Called shortly after death. The release dialog can appear a beat late, so we
-- (re)anchor a couple of times before settling.
function RecapButton:OnDeath()
    EnsureButton()
    Anchor()
    btn:Show()
    if C_Timer and C_Timer.After then
        C_Timer.After(0.5, function() if btn:IsShown() then Anchor() end end)
        C_Timer.After(1.5, function() if btn:IsShown() then Anchor() end end)
    end
end

function RecapButton:OnAlive()
    if btn then btn:Hide() end
end

-- ── Diagnostic (/bdr btn) — run it WHILE the death dialog is up ───────────────
-- Reports what death UI is visible so we can pin the button's anchor precisely.
function RecapButton:Diagnose()
    local out = {}
    out[#out + 1] = "STATICPOPUP_NUMDIALOGS = " .. tostring(STATICPOPUP_NUMDIALOGS)
    for i = 1, (STATICPOPUP_NUMDIALOGS or 8) do
        local f = _G["StaticPopup" .. i]
        if f and f:IsShown() then
            local btns = {}
            for _, child in ipairs({ f:GetChildren() }) do
                if child.GetText and child:IsShown() then
                    local txt = child:GetText()
                    if txt and txt ~= "" then btns[#btns + 1] = txt end
                end
            end
            out[#out + 1] = ("StaticPopup%d which=%s buttons=[%s]"):format(
                i, tostring(f.which), table.concat(btns, ", "))
        end
    end
    local dr = _G.DeathRecapFrame
    out[#out + 1] = "DeathRecapFrame: " .. (dr and (dr:IsShown() and "SHOWN" or "hidden") or "nil")
    out[#out + 1] = "our button: " .. (btn and (btn:IsShown() and "shown" or "hidden") or "not created")
    if #out == 1 then out[#out + 1] = "(no visible StaticPopup — die first, then run this while the dialog is up)" end
    return out
end
