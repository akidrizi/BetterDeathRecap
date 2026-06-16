local _, BDR = ...

-- Options panel — registered under Options → AddOns → BetterDeathRecap. A canvas
-- layout: the branded "BetterDeathRecap" title on the left, the version in small
-- gray on the right, and a single "Minimap Icon" toggle. Uses the modern Settings
-- API (no libraries).

local Options = {}
BDR.Options = Options

local panel

function Options:Init()
    if panel or not (Settings and Settings.RegisterCanvasLayoutCategory) then return end
    local L = BDR.L

    panel = CreateFrame("Frame")

    -- Header (the standard canvas-settings pattern: a big title, then a divider
    -- before the options). Branded title left: "Better" red + "DeathRecap" cream.
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("|cffff5555Better|r|cfff0e6d2DeathRecap|r")

    -- Version, small gray, baseline-aligned with the title on the right.
    local ver = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    ver:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    ver:SetPoint("BOTTOM", title, "BOTTOM", 0, 1)
    ver:SetText("|cff999999v" .. BDR.GetVersion() .. "|r")

    -- Divider under the header, before the options.
    local sep = panel:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    sep:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    if sep.SetAtlas and C_Texture and C_Texture.GetAtlasInfo
        and C_Texture.GetAtlasInfo("Options_HorizontalDivider") then
        sep:SetAtlas("Options_HorizontalDivider")
    else
        sep:SetColorTexture(0.4, 0.4, 0.42, 0.7)   -- plain line fallback
    end

    -- Only option: Minimap Icon. Sized snug with the label flush to the box (the
    -- default template leaves a left gap).
    local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", -2, -14)
    local label = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", cb, "RIGHT", 0, 0)
    label:SetText(L.OPT_MINIMAP_ICON)
    cb:SetHitRectInsets(0, -(label:GetStringWidth() + 4), 0, 0)  -- label is clickable too
    cb:SetChecked(BDR.DB.minimapShown ~= false)
    cb:SetScript("OnClick", function(box)
        BDR.DB.minimapShown = box:GetChecked() and true or false
        if BDR.Minimap then BDR.Minimap:SetShown(BDR.DB.minimapShown) end
    end)
    panel.minimapCheck = cb

    -- If ElvUI is present, let it re-skin the checkbox so it matches the rest of the
    -- UI (soft — no dependency). Deferred to PLAYER_LOGIN since ElvUI loads after us.
    local skinEv = CreateFrame("Frame")
    skinEv:RegisterEvent("PLAYER_LOGIN")
    skinEv:SetScript("OnEvent", function(ev)
        ev:UnregisterAllEvents()
        if _G.ElvUI then
            pcall(function()
                local E = unpack(_G.ElvUI)
                local S = E and E.GetModule and E:GetModule("Skins")
                if S and S.HandleCheckBox then S:HandleCheckBox(cb) end
            end)
        end
    end)

    local category = Settings.RegisterCanvasLayoutCategory(panel, "BetterDeathRecap")
    Settings.RegisterAddOnCategory(category)
    Options.category = category
end

-- Open the panel (right-click the minimap button, or /bdr options).
function Options:Open()
    if Options.category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(Options.category:GetID())
    end
end
