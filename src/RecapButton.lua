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
-- The death dialog we grew: its original width + anchor points, so we can put it back
-- (StaticPopups are recycled for other prompts).
local widenedPopup, widenedBase, widenedPoints

-- Make our button adopt the active theme. ElvUI does NOT auto-skin a custom addon
-- button, so it would otherwise keep the "classic" look while the rest of the dialog
-- is themed. We soft-skin it ourselves via ElvUI's own Skins module — dependency-free,
-- pcall-guarded, no-op without ElvUI, and only once per button.
local function SkinButton()
    if not btn or btn.__bdrSkinned or not _G.ElvUI then return end
    btn.__bdrSkinned = true
    pcall(function()
        local E = unpack(_G.ElvUI)
        local S = E and E.GetModule and E:GetModule("Skins")
        if S and S.HandleButton then S:HandleButton(btn) end
    end)
end

-- Put the recycled StaticPopup back to its original width AND anchor points (else a
-- later "Delete item?" box shows oversized / mis-positioned).
local function RestoreDialog()
    if widenedPopup then
        pcall(function()
            if widenedBase then widenedPopup:SetWidth(widenedBase) end
            if widenedPoints then
                widenedPopup:ClearAllPoints()
                for _, p in ipairs(widenedPoints) do widenedPopup:SetPoint(unpack(p)) end
            end
        end)
    end
    widenedPopup, widenedBase, widenedPoints = nil, nil, nil
end

-- Grow the dialog's width just enough to contain our button. Re-applied every tick
-- (see EnsureButton's OnUpdate) because the release countdown re-sizes the dialog as
-- its text changes, which would otherwise snap the width back and re-expose the button.
-- A sanity cap stops runaway growth if the dialog ever loses our left-edge pin.
local function EnforceDialogWidth()
    if not (btn and widenedPopup) then return end
    pcall(function()
        local r, pr = btn:GetRight(), widenedPopup:GetRight()
        if not (r and pr) then return end
        local overflow = r + 12 - pr
        if overflow > 0 and widenedPopup:GetWidth() + overflow <= (widenedBase or 0) + 240 then
            widenedPopup:SetWidth(widenedPopup:GetWidth() + overflow)
        end
    end)
end

-- Make our button sit INSIDE the dialog. StaticPopups are TOP-anchored, so a plain
-- SetWidth grows them SYMMETRICALLY — the button (anchored within the dialog) moves
-- out with it and the overflow never closes. So we PIN the dialog's left edge once
-- (re-anchor its TOPLEFT to its current screen position); after that, growth is purely
-- rightward and `EnforceDialogWidth` can close the gap. Guarded so a quirk can't error.
local function ExtendDialog(popup)
    if not (btn and popup and popup.GetWidth) then return end
    pcall(function()
        if widenedPopup ~= popup then
            local l, t = popup:GetLeft(), popup:GetTop()
            if not (l and t) then return end   -- not positioned yet; a retry will pin it
            RestoreDialog()
            local pts = {}
            for i = 1, (popup.GetNumPoints and popup:GetNumPoints() or 0) do
                pts[i] = { popup:GetPoint(i) }
            end
            widenedPopup, widenedBase, widenedPoints = popup, popup:GetWidth(), pts
            popup:ClearAllPoints()
            popup:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)   -- pin left → grow right
        end
        EnforceDialogWidth()
    end)
end

-- Build (once) the freshest report we can and show the window. Prefers a live
-- rebuild from the current recap + the death-time health snapshot, falling back
-- to the stored report, and finally to a friendly "no death" message.
local function OpenReport()
    local report = BDR.GetLastReport()
    local fresh  = BDR.Analyzer:Build()
    if fresh and not fresh.empty then
        BDR.SetLastReport(fresh)
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
    -- While shown, keep the dialog wide enough to contain us (throttled) — the release
    -- countdown re-sizes the dialog as its text ticks, which would otherwise re-expose
    -- the button. OnUpdate only fires while shown, so it idles after OnAlive hides us.
    btn:SetScript("OnUpdate", function(self, elapsed)
        self.bdrEnforceT = (self.bdrEnforceT or 0) + elapsed
        if self.bdrEnforceT >= 0.1 then self.bdrEnforceT = 0; EnforceDialogWidth() end
    end)
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

-- Does this button text name Blizzard's death-recap button? Matches known
-- localized labels, then falls back to an English "recap" substring. Excludes our
-- own "Better Recap" text so we never anchor to ourselves.
local function looksLikeRecap(txt)
    if type(txt) ~= "string" or txt == "" then return false end
    if txt == BDR.L.BTN_RECAP then return false end       -- our own button
    for _, l in ipairs({ _G.RECAP, _G.DEATHRECAP, _G.DEATH_RECAP }) do
        if l and txt == l then return true end
    end
    return txt:lower():find("recap") ~= nil
end

-- Within the death popup, find Blizzard's "Recap" button so we can sit just to its
-- right. Checks the standard StaticPopup buttons (button1..4) and any visible child
-- button; returns nil if none found (caller then anchors to the popup edge).
local function FindRecapButton(popup)
    local name = popup:GetName()
    for n = 1, 4 do
        local b = popup["button" .. n] or (name and _G[name .. "Button" .. n])
        if b and b.GetText and b:IsShown() and looksLikeRecap(b:GetText()) then return b end
    end
    for _, child in ipairs({ popup:GetChildren() }) do
        if child.GetText and child:IsShown() and looksLikeRecap(child:GetText()) then
            return child
        end
    end
    return nil
end

-- Position the button: right of Blizzard's Recap button if we can pin it,
-- else off the right edge of the death popup, else a fixed screen fallback.
local function Anchor()
    EnsureButton()
    SkinButton()           -- adopt the ElvUI theme (idempotent; no-op without ElvUI)
    btn:ClearAllPoints()

    local popup = FindDeathPopup()
    if popup then
        local recap = FindRecapButton(popup)   -- find BEFORE reparenting (so we don't match ourselves)
        btn:SetParent(popup)
        btn:SetFrameStrata("FULLSCREEN_DIALOG")
        if recap then
            -- Sit in the dialog's button row as the next button: match the Recap
            -- button's size/level and use the same small inter-button gap so the
            -- row reads Release | Reincarnation | Recap | Better Recap, then grow the
            -- dialog so our button is contained WITHIN it (not floating off the edge).
            local w, h = recap:GetSize()
            if w and w > 0 then btn:SetSize(w, h) end
            btn:SetFrameLevel(recap:GetFrameLevel())
            btn:SetPoint("LEFT", recap, "RIGHT", 4, 0)
            ExtendDialog(popup)
        else
            btn:SetPoint("TOPLEFT", popup, "TOPRIGHT", 6, -10)
        end
        return true
    end

    -- Fallback: a fixed spot near the lower-middle of the screen (no dialog to attach
    -- to, so nothing to extend).
    RestoreDialog()
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
    RestoreDialog()   -- put the recycled StaticPopup back to its original width
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
