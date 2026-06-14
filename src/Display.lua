local _, BDR = ...

-- Display — the recap window. Built once, lazily, then re-populated from a
-- DeathReport on every Show(). Layout follows PLAN.md / BetterDeathRecap_UI_v2:
--   Header (title + scale control + close)
--   Death summary banner (who/what killed you + amount + overkill)
--   Health-timeline graph (the hero; curve + event markers + hover sync)
--   Combat event table (scrollable; Time/Ability/Type/Amount/% Max HP, newest top)
--   Damage sources (per-attacker bars + total)
--   Encounter footer (difficulty · zone · window)
-- Variable-count visuals come from small object pools so we never leak frames.

local Display = {}
BDR.Display = Display

local L = BDR.L  -- Locale.lua loads before Display.lua, so BDR.L is ready here.

-- ── layout constants (vertical stack, top → bottom) ──────────────────────────
local WINDOW_W   = 560
local PAD        = 12
local GUTTER     = 32          -- left margin reserved for the health-% axis labels
local TITLE_H    = 26
local BANNER_H   = 46
local HDR_GAP    = 12
local GRAPH_HDR  = 28          -- header+legend row height; clears the canvas top below it
local GRAPH_H    = 152         -- HP-graph canvas height (the hero)
local XAXIS_H    = 14
local Y_AXIS_MIN   = -5        -- y-axis floor (%) so the death line isn't flush at the bottom
local TAIL_SECONDS = 1.5       -- post-death padding (the dashed fading tail), in combat seconds
local TBL_HDR    = 16          -- table column-header row
local ROW_H      = 18
local ROW_GAP    = 1
local SRC_HDR    = 16
local SRC_ROW_H  = 18
local SRC_TOTAL_H = 20
local FOOTER_H   = 18

local TL_VISIBLE_ROWS  = 6     -- combat-table viewport height (rows); the rest scrolls
local SRC_VISIBLE_ROWS = 5     -- damage-sources viewport height (rows); the rest scrolls
local SCROLLBAR_W      = 22

-- Table column geometry (shared by the header and the rows).
local C_TIME_X  = 6
local C_TIME_W  = 38
local C_ICON_W  = 16
local C_NAME_X  = C_TIME_X + C_TIME_W + 2 + C_ICON_W + 6
local C_PCT_PAD   = 6          -- "% Max HP" bar, inset from the row's right edge
local C_PCT_BAR_W = 78         -- the big flat "% Max HP" bar (right of the number)
local C_PCT_GAP   = 6          -- gap between the % number and the bar
local C_PCT_NUM_W = 34         -- width of the "37%" number (sits LEFT of the bar)
local C_DMG_W   = 60
local C_TYPE_W  = 44

-- ── tiny helpers ─────────────────────────────────────────────────────────────

local function SpellIcon(spellID)
    if not spellID then return nil end
    if C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(spellID)
    end
    if GetSpellTexture then
        return GetSpellTexture(spellID)
    end
    return nil
end

-- Resolve an event's display label. Prefer the name the recap/Analyzer captured,
-- but RE-RESOLVE from the spellID at render time — spell data loads async, so a
-- name that wasn't cached when the report was built often is by the time we draw.
-- Only a real melee swing (no spellID) falls back to "Melee".
local function SpellNameAt(ev)
    if ev.spellName and ev.spellName ~= "" then return ev.spellName end
    local id = ev.spellID
    if id then
        local n = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id))
            or (GetSpellInfo and (GetSpellInfo(id)))
        if n and n ~= "" then return n end
        return L.UNKNOWN
    end
    return L.MELEE
end

local function FormatAmount(n)
    n = n or 0
    if n >= 1e6 then return string.format("%.1fm", n / 1e6) end
    if n >= 1e3 then return string.format("%.0fk", n / 1e3) end
    return tostring(math.floor(n + 0.5))
end

-- Full grouped number: 331954 -> "331,954".
local function FormatFull(n)
    local s = tostring(math.floor((n or 0) + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- RGB table -> "|cffRRGGBB" chat escape, for colouring FontStrings inline.
local function ColorOf(c)
    return string.format("|cff%02x%02x%02x",
        math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

-- Curve colour gradient by HP: green high, amber 30–50%, red approaching death.
-- Cosmetic urgency only — it carries no data meaning beyond "how bad is it".
local function HpColor(pct)
    local c = BDR.UI
    if pct > 50 then return c.HP_GOOD end
    if pct >= 30 then return c.HP_MID end
    return c.HP_LOW
end

-- Resolve a damage-school mask to (colour, name). A single-bit mask maps directly;
-- a combined mask falls back to a representative school; unknown/absent → red.
local function SchoolInfo(mask)
    if type(mask) ~= "number" or mask <= 0 then return BDR.UI.DAMAGE, "" end
    local s = BDR.SCHOOL[mask]
    if s then return s.color, s.name end
    for _, bit in ipairs({ 4, 32, 16, 8, 64, 2, 1 }) do
        if (mask % (bit + bit)) >= bit and BDR.SCHOOL[bit] then
            return BDR.SCHOOL[bit].color, BDR.SCHOOL[bit].name
        end
    end
    return BDR.UI.DAMAGE, ""
end

local function PctAtT(curve, t)
    if #curve == 0 then return 0 end
    if t <= curve[1].t then return curve[1].pct end
    if t >= curve[#curve].t then return curve[#curve].pct end
    for i = 2, #curve do
        local a, b = curve[i - 1], curve[i]
        if t <= b.t then
            local span = b.t - a.t
            local f = span > 0 and (t - a.t) / span or 0
            return a.pct + (b.pct - a.pct) * f
        end
    end
    return curve[#curve].pct
end

-- Stepped HP value at time `t`: the latest curve point at or before `t` (HP holds
-- constant between events and drops instantly on a hit — no interpolation).
local function StepPctAt(curve, t)
    if #curve == 0 then return 0 end
    local v = curve[1].pct
    for i = 1, #curve do
        if curve[i].t <= t then v = curve[i].pct else break end
    end
    return v
end

-- HP% just before/after the sample at time `t`; before−after ≈ the hit's share
-- of max HP, which the table's "% Max HP" column and the tooltip both want.
local function HpStep(curve, t)
    local after = PctAtT(curve, t)
    local before = after
    for i = 1, #curve do
        if curve[i].t < t then before = curve[i].pct else break end
    end
    return before, after
end

-- ── object pools ─────────────────────────────────────────────────────────────

local function NewPool(factory)
    return { items = {}, used = 0, factory = factory }
end

local function PoolReset(p)
    for i = 1, p.used do p.items[i]:Hide() end
    p.used = 0
end

local function PoolNext(p, parent)
    p.used = p.used + 1
    local it = p.items[p.used]
    if not it then
        it = p.factory(parent)
        p.items[p.used] = it
    end
    it:Show()
    return it
end

-- ── frame construction (runs once) ───────────────────────────────────────────

local F  -- the main frame, built on first Show()

local function SavePosition()
    local point, _, relPoint, x, y = F:GetPoint()
    BDR.DB.point = { point, "UIParent", relPoint, x, y }
end

local function ApplyLockState(f)
    f = f or F
    f:EnableMouse(true)
end

local function MakeFontString(parent, template, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    if justify then fs:SetJustifyH(justify) end
    return fs
end

-- Restyle a UIPanelScrollFrameTemplate scrollbar to the modern Blizzard look:
-- thin, gray, a chunky (~60%) thumb and simple gray chevron arrows. Everything is
-- guarded so a missing piece degrades gracefully rather than erroring; the modern
-- chevron atlas is used only if the client actually has it.
local function AtlasExists(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local function StyleScrollbar(barName)
    local bar = _G[barName]
    if not bar then return end
    bar:SetWidth(8)

    -- Thin gray thumb (~60% of a typical viewport).
    local thumb = (bar.GetThumbTexture and bar:GetThumbTexture()) or _G[barName .. "ThumbTexture"]
    if thumb then
        thumb:SetColorTexture(0.50, 0.50, 0.53, 0.85)
        thumb:SetSize(5, 64)
    end

    -- Drop the chunky default track art if it's present.
    for _, suffix in ipairs({ "Track", "Background", "Top", "Bottom", "Middle" }) do
        local t = _G[barName .. suffix]
        if t and t.SetAlpha then t:SetAlpha(0) end
    end

    -- Simple gray chevron arrows (modern atlas when available; else tint the default).
    local function styleArrow(btn, atlas)
        if not btn then return end
        btn:SetSize(14, 14)
        if btn.SetNormalAtlas and AtlasExists(atlas) then
            btn:SetNormalAtlas(atlas); btn:SetPushedAtlas(atlas); btn:SetDisabledAtlas(atlas)
        end
        local n = btn.GetNormalTexture and btn:GetNormalTexture()
        local p = btn.GetPushedTexture and btn:GetPushedTexture()
        local d = btn.GetDisabledTexture and btn:GetDisabledTexture()
        local h = btn.GetHighlightTexture and btn:GetHighlightTexture()
        if n then n:SetVertexColor(0.62, 0.62, 0.66) end
        if p then p:SetVertexColor(0.85, 0.85, 0.90) end
        if d then d:SetVertexColor(0.32, 0.32, 0.34) end
        if h then h:SetAlpha(0) end
    end
    styleArrow(_G[barName .. "ScrollUpButton"],   "minimal-scrollbar-arrow-top")
    styleArrow(_G[barName .. "ScrollDownButton"], "minimal-scrollbar-arrow-bottom")
end

-- Apply a new window scale (buttons commit immediately), persist + refresh label.
local function SetWindowScale(v)
    v = math.max(BDR.CONFIG.SCALE_MIN, math.min(BDR.CONFIG.SCALE_MAX, math.floor(v * 10 + 0.5) / 10))
    BDR.DB.scale = v
    F:SetScale(v)
end

-- ── Continuous cursor-tracking tooltip (the graph's "foolproof" hover) ───────
-- A transparent overlay over the graph; its OnUpdate maps the cursor X to a time,
-- finds the nearest hit, and shows a tooltip that follows the cursor with no dead
-- zones. F.mapT (set by RenderGraph) holds the time/HP mapping + the hit list.

local function GraphTrackStop()
    if not (F and F.tracking) then return end
    F.tracking = false
    F.graphHL:Hide(); F.markerGlow:Hide()
    if F.trackRow then F.trackRow.hl:Hide(); F.trackRow = nil end
    if GameTooltip:GetOwner() == F.graphOverlay then GameTooltip:Hide() end
end

local function GraphTrack(overlay)
    local m = F and F.mapT
    if not m then return end
    if not overlay:IsMouseOver() then GraphTrackStop(); return end
    F.tracking = true

    local scale = overlay:GetEffectiveScale()
    local gx = (GetCursorPosition() / scale) - F.graph:GetLeft()
    if gx < 0 then gx = 0 elseif gx > m.gw then gx = m.gw end

    local combatT = gx / m.gw * m.xMax
    local relT = combatT + m.first              -- back to relative-to-death seconds
    if relT > 0 then relT = 0 end

    -- Nearest hit by X-axis proximity.
    local nearest, nd
    for _, ev in ipairs(m.hits) do
        local ex = (ev.t - m.first) / m.xMax * m.gw
        local d = math.abs(ex - gx)
        if not nd or d < nd then nd, nearest = d, ev end
    end

    -- Scrubber line at the cursor.
    F.graphHL:ClearAllPoints()
    F.graphHL:SetPoint("BOTTOMLEFT", F.graph, "BOTTOMLEFT", gx - 0.5, 0)
    F.graphHL:SetSize(1, m.gh); F.graphHL:Show()

    local hp = StepPctAt(m.curve, relT)
    local onHit = nearest and nd <= 14
    local newRow = (onHit and F.rowOf) and F.rowOf[nearest] or nil
    if F.trackRow and F.trackRow ~= newRow then F.trackRow.hl:Hide(); F.trackRow = nil end
    if onHit then
        local pos = F.markerPos and F.markerPos[nearest]
        if pos then
            F.markerGlow:ClearAllPoints()
            F.markerGlow:SetPoint("CENTER", F.graph, "BOTTOMLEFT", pos.x, pos.y)
            F.markerGlow:SetSize(pos.r + 14, pos.r + 14); F.markerGlow:Show()
        else
            F.markerGlow:Hide()
        end
        if newRow then newRow.hl:Show(); F.trackRow = newRow end
    else
        F.markerGlow:Hide()
    end

    GameTooltip:SetOwner(overlay, "ANCHOR_CURSOR_RIGHT")
    GameTooltip:AddLine(string.format("%.1fs into combat", combatT), 1, 1, 1)
    local hc = (hp > 50 and BDR.UI.HP_GOOD) or (hp >= 25 and BDR.UI.HP_MID) or BDR.UI.HP_LOW
    GameTooltip:AddLine(string.format("%d%% HP remaining", math.floor(hp + 0.5)), hc[1], hc[2], hc[3])
    if onHit then
        local isHeal = nearest.kind == "heal"
        local dc = isHeal and BDR.UI.HEAL or BDR.UI.DAMAGE
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(SpellNameAt(nearest), BDR.UI.TEXT[1], BDR.UI.TEXT[2], BDR.UI.TEXT[3])
        GameTooltip:AddDoubleLine(L.TIP_SOURCE, nearest.sourceName or L.UNKNOWN,
            0.7, 0.7, 0.7, 0.95, 0.95, 0.95)
        GameTooltip:AddDoubleLine(isHeal and L.TYPE_HEAL or L.TYPE_HIT,
            (isHeal and "+" or "-") .. FormatAmount(nearest.amount), 0.7, 0.7, 0.7, dc[1], dc[2], dc[3])
        local _, schoolName = SchoolInfo(nearest.school)
        if schoolName ~= "" then
            GameTooltip:AddDoubleLine(L.TIP_SCHOOL, schoolName, 0.7, 0.7, 0.7, 0.95, 0.95, 0.95)
        end
        local b, a = HpStep(m.curve, nearest.t)
        local delta = a - b
        local dcol = (delta < 0) and BDR.UI.DAMAGE or BDR.UI.HEAL
        GameTooltip:AddDoubleLine(L.TIP_HP_CHANGE, string.format("%+.1f%%", delta),
            0.7, 0.7, 0.7, dcol[1], dcol[2], dcol[3])
        if nearest.isKillingBlow or (nearest.overkill and nearest.overkill > 0) then
            GameTooltip:AddLine(L.KILLING_BLOW, BDR.UI.DAMAGE[1], BDR.UI.DAMAGE[2], BDR.UI.DAMAGE[3])
        end
    end
    GameTooltip:Show()
end

local function BuildFrame()
    local f = CreateFrame("Frame", "BetterDeathRecapFrame", UIParent, "BackdropTemplate")
    f:SetSize(WINDOW_W, 480)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:Hide()

    -- Background drawn by the backdrop itself (bgFile), clipped inside the border
    -- insets — a separate full-rect texture used to poke past the rounded corners.
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(unpack(BDR.UI.BG))
    f:SetBackdropBorderColor(unpack(BDR.UI.BORDER_GRAY))

    local p = BDR.DB.point
    f:SetPoint(p[1], UIParent, p[3], p[4], p[5])
    f:SetScale(BDR.DB.scale or 1.0)

    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not BDR.DB.locked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)
    table.insert(UISpecialFrames, "BetterDeathRecapFrame")  -- close on Escape

    -- ── Header ─────────────────────────────────────────────────────────────────
    local headerBg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    headerBg:SetColorTexture(0.08, 0.08, 0.10, 1)
    headerBg:SetPoint("TOPLEFT", 5, -5)
    headerBg:SetPoint("TOPRIGHT", -5, -5)
    headerBg:SetHeight(TITLE_H)
    local headerLine = f:CreateTexture(nil, "ARTWORK")
    headerLine:SetColorTexture(unpack(BDR.UI.BORDER_GRAY))
    headerLine:SetPoint("BOTTOMLEFT", headerBg, "BOTTOMLEFT", 0, 0)
    headerLine:SetPoint("BOTTOMRIGHT", headerBg, "BOTTOMRIGHT", 0, 0)
    headerLine:SetHeight(1)

    -- Centred title: "Better" red, "DeathRecap" primary text.
    local title = MakeFontString(f, "GameFontNormalLarge", "CENTER")
    title:SetPoint("TOPLEFT", headerBg, "TOPLEFT", 0, 0)
    title:SetPoint("BOTTOMRIGHT", headerBg, "BOTTOMRIGHT", 0, 0)
    title:SetJustifyH("CENTER")
    title:SetJustifyV("MIDDLE")
    title:SetText(ColorOf(BDR.UI.DAMAGE) .. "Better|r" .. ColorOf(BDR.UI.TEXT) .. "DeathRecap|r")

    -- Right side: the standard WoW close button, then a scale slider whose thumb
    -- shows the value:  Scale: [    [1.0]    ].  The window only rescales on release.
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetSize(26, 26)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function() f:Hide() end)

    local scaleSlider = CreateFrame("Slider", nil, f)
    scaleSlider:SetSize(108, 14)
    scaleSlider:SetPoint("RIGHT", close, "LEFT", -4, 0)
    scaleSlider:SetOrientation("HORIZONTAL")
    scaleSlider:SetMinMaxValues(BDR.CONFIG.SCALE_MIN, BDR.CONFIG.SCALE_MAX)
    scaleSlider:SetValueStep(0.1)
    scaleSlider:SetObeyStepOnDrag(true)
    scaleSlider:EnableMouse(true)
    local strack = scaleSlider:CreateTexture(nil, "BACKGROUND", nil, -1)  -- gray track border
    strack:SetColorTexture(unpack(BDR.UI.BORDER_GRAY))
    strack:SetPoint("TOPLEFT", -1, 1); strack:SetPoint("BOTTOMRIGHT", 1, -1)
    local sfill = scaleSlider:CreateTexture(nil, "BACKGROUND")
    sfill:SetAllPoints()
    sfill:SetColorTexture(0.10, 0.10, 0.12, 1)
    local sthumb = scaleSlider:CreateTexture(nil, "ARTWORK")
    sthumb:SetSize(40, 14)
    sthumb:SetColorTexture(0.28, 0.28, 0.32, 1)
    scaleSlider:SetThumbTexture(sthumb)
    f.scaleValue = MakeFontString(scaleSlider, "GameFontHighlightSmall", "CENTER")
    f.scaleValue:SetPoint("CENTER", sthumb, "CENTER", 0, 0)
    f.scaleValue:SetTextColor(unpack(BDR.UI.TEXT))
    -- Use `f` (not the upvalue `F`): SetValue below fires OnValueChanged while still
    -- inside BuildFrame, before `F = BuildFrame()` has been assigned.
    scaleSlider:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value * 10 + 0.5) / 10
        f.pendingScale = value
        f.scaleValue:SetText(string.format("%.1f", value))
    end)
    scaleSlider:SetScript("OnMouseUp", function()
        if f.pendingScale then SetWindowScale(f.pendingScale) end
    end)
    scaleSlider:SetValue(BDR.DB.scale or 1.0)  -- fires OnValueChanged → sets the thumb label

    local scaleLabel = MakeFontString(f, "GameFontDisableSmall", "RIGHT")
    scaleLabel:SetPoint("RIGHT", scaleSlider, "LEFT", -6, 0)
    scaleLabel:SetText(L.SCALE_LABEL .. ":")

    -- ── Death summary banner ─────────────────────────────────────────────────────
    local yBanner = -PAD - TITLE_H
    local banner = CreateFrame("Frame", nil, f)
    banner:SetPoint("TOPLEFT", PAD, yBanner)
    banner:SetPoint("TOPRIGHT", -PAD, yBanner)
    banner:SetHeight(BANNER_H)
    local bb = banner:CreateTexture(nil, "BACKGROUND")
    bb:SetAllPoints()
    bb:SetColorTexture(0.16, 0.05, 0.05, 1)
    local bbBorder = banner:CreateTexture(nil, "ARTWORK")
    bbBorder:SetColorTexture(0.45, 0.12, 0.12, 1)
    bbBorder:SetPoint("BOTTOMLEFT"); bbBorder:SetPoint("BOTTOMRIGHT"); bbBorder:SetHeight(1)

    f.bannerIcon = banner:CreateTexture(nil, "ARTWORK")
    f.bannerIcon:SetSize(32, 32)
    f.bannerIcon:SetPoint("LEFT", 12, 0)
    f.bannerIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local ibOuter = banner:CreateTexture(nil, "BACKGROUND")  -- dark outer outline + spacing
    ibOuter:SetColorTexture(0, 0, 0, 0.85)
    ibOuter:SetPoint("TOPLEFT", f.bannerIcon, "TOPLEFT", -3, 3)
    ibOuter:SetPoint("BOTTOMRIGHT", f.bannerIcon, "BOTTOMRIGHT", 3, -3)
    local ib = banner:CreateTexture(nil, "BACKGROUND", nil, 1)  -- red inner border
    ib:SetColorTexture(0.55, 0.16, 0.16, 1)
    ib:SetPoint("TOPLEFT", f.bannerIcon, "TOPLEFT", -2, 2)
    ib:SetPoint("BOTTOMRIGHT", f.bannerIcon, "BOTTOMRIGHT", 2, -2)

    f.bannerKilledBy = MakeFontString(banner, "GameFontDisableSmall", "LEFT")
    f.bannerKilledBy:SetPoint("TOPLEFT", f.bannerIcon, "TOPRIGHT", 12, -4)
    f.bannerKilledBy:SetText(ColorOf(BDR.UI.DAMAGE) .. L.KILLED_BY .. "|r")

    f.bannerSource = MakeFontString(banner, "GameFontNormal", "LEFT")
    f.bannerSource:SetPoint("BOTTOMLEFT", f.bannerIcon, "BOTTOMRIGHT", 12, 4)

    -- Hovering the killing-blow icon/name shows the real spell tooltip.
    f.bannerSpellBtn = CreateFrame("Button", nil, banner)
    f.bannerSpellBtn:SetPoint("TOPLEFT", 4, -2)
    f.bannerSpellBtn:SetPoint("BOTTOMLEFT", 4, 2)
    f.bannerSpellBtn:SetWidth(320)
    f.bannerSpellBtn:SetFrameLevel(banner:GetFrameLevel() + 5)
    f.bannerSpellBtn:SetScript("OnEnter", function(self)
        if self.spellID and GameTooltip.SetSpellByID then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            GameTooltip:SetSpellByID(self.spellID)
            GameTooltip:Show()
        end
    end)
    f.bannerSpellBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.bannerAmount = MakeFontString(banner, "GameFontNormalLarge", "RIGHT")
    f.bannerAmount:SetFont("Fonts\\FRIZQT__.TTF", 21, "")
    f.bannerAmount:SetPoint("TOPRIGHT", banner, "TOPRIGHT", -10, -5)

    f.bannerOver = MakeFontString(banner, "GameFontDisableSmall", "RIGHT")
    f.bannerOver:SetPoint("BOTTOMRIGHT", banner, "BOTTOMRIGHT", -10, 6)

    -- ── Graph header (label + legend) ────────────────────────────────────────────
    local yGraphHdr = yBanner - BANNER_H - HDR_GAP
    f.graphLabel = MakeFontString(f, "GameFontDisableSmall", "LEFT")
    f.graphLabel:SetPoint("TOPLEFT", PAD, yGraphHdr)
    f.graphLabel:SetTextColor(unpack(BDR.UI.TEXT_DIM))

    f.graphLegend = MakeFontString(f, "GameFontDisableSmall", "RIGHT")
    f.graphLegend:SetPoint("TOPRIGHT", -PAD, yGraphHdr)
    f.graphLegend:SetText(table.concat({
        ColorOf(BDR.UI.HEAL) .. "—|r " .. ColorOf(BDR.UI.TEXT_DIM) .. L.LEGEND_HEALTH .. "|r",
        ColorOf(BDR.UI.ABSORB) .. "- -|r " .. ColorOf(BDR.UI.TEXT_DIM) .. L.LEGEND_ABSORB .. "|r",
        ColorOf(BDR.UI.DAMAGE) .. "●|r " .. ColorOf(BDR.UI.TEXT_DIM) .. L.LEGEND_HIT .. "|r",
        ColorOf(BDR.UI.HEAL) .. "▲|r " .. ColorOf(BDR.UI.TEXT_DIM) .. L.LEGEND_HEAL .. "|r",
    }, "   "))

    -- ── Graph canvas ─────────────────────────────────────────────────────────────
    local yCanvas = yGraphHdr - GRAPH_HDR
    local graphW = WINDOW_W - PAD - GUTTER - PAD
    local graph = CreateFrame("Frame", nil, f)
    graph:SetPoint("TOPLEFT", PAD + GUTTER, yCanvas)
    graph:SetSize(graphW, GRAPH_H)
    f.graph = graph

    local canvas = graph:CreateTexture(nil, "BACKGROUND")
    canvas:SetAllPoints()
    canvas:SetColorTexture(unpack(BDR.UI.CANVAS_BG))

    -- Y axis: 0–100% labels + low-opacity gridlines. HP maps into [Y_AXIS_MIN..100],
    -- so 0% sits a touch above the bottom edge (the death line isn't flush).
    local function YPos(pct) return (pct - Y_AXIS_MIN) / (100 - Y_AXIS_MIN) * GRAPH_H end
    for _, pct in ipairs({ 0, 20, 40, 60, 80, 100 }) do
        local yy = YPos(pct)
        local lbl = MakeFontString(graph, "GameFontDisableSmall", "RIGHT")
        lbl:SetPoint("RIGHT", graph, "BOTTOMLEFT", -4, yy)
        lbl:SetText(pct .. "%")
        lbl:SetTextColor(unpack(BDR.UI.TEXT_DIM))
        local g = graph:CreateTexture(nil, "BACKGROUND", nil, 1)
        g:SetColorTexture(1, 1, 1, 0.05)
        g:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", 0, yy)
        g:SetPoint("BOTTOMRIGHT", graph, "BOTTOMLEFT", graphW, yy)
        g:SetHeight(1)
    end

    f.graphFillPool = NewPool(function(parent) return parent:CreateTexture(nil, "ARTWORK", nil, 1) end)
    f.graphLinePool = NewPool(function(parent) return parent:CreateLine(nil, "OVERLAY") end)

    -- Post-death dashed fading tail (so the killing-blow dot isn't flush right).
    f.tailPool = NewPool(function(parent) return parent:CreateTexture(nil, "ARTWORK", nil, 2) end)

    -- Event dots: a school-coloured fill inside a white outline; KB is bigger.
    f.dotPool = NewPool(function(parent)
        local d = CreateFrame("Frame", nil, parent)
        d:SetFrameLevel(parent:GetFrameLevel() + 4)
        d.border = d:CreateTexture(nil, "ARTWORK", nil, 1)
        d.border:SetTexture("Interface\\COMMON\\Indicator-Gray")
        d.border:SetVertexColor(1, 1, 1, 1)
        d.border:SetAllPoints()
        d.fill = d:CreateTexture(nil, "OVERLAY", nil, 1)
        d.fill:SetTexture("Interface\\COMMON\\Indicator-Gray")
        d.fill:SetPoint("TOPLEFT", 2, -2)
        d.fill:SetPoint("BOTTOMRIGHT", -2, 2)
        return d
    end)

    -- Scrubber line + dot glow (cursor tracking + table→graph sync).
    f.graphHL = graph:CreateTexture(nil, "OVERLAY", nil, 3)
    f.graphHL:SetColorTexture(1, 1, 1, 0.28)
    f.graphHL:Hide()
    f.markerGlow = graph:CreateTexture(nil, "OVERLAY", nil, 2)
    f.markerGlow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    f.markerGlow:SetBlendMode("ADD")
    f.markerGlow:SetVertexColor(unpack(BDR.UI.GOLD))
    f.markerGlow:Hide()

    f.graphNote = MakeFontString(graph, "GameFontDisableSmall", "CENTER")
    f.graphNote:SetPoint("CENTER", graph, "CENTER", 0, 0)
    f.graphNote:Hide()
    f.mapT = nil

    -- X axis: whole-second labels (pooled) + 0.5s minor ticks (pooled).
    f.xtickPool  = NewPool(function(parent)
        local fs = MakeFontString(parent, "GameFontDisableSmall", "CENTER")
        fs:SetTextColor(unpack(BDR.UI.TEXT_DIM))
        return fs
    end)
    f.xminorPool = NewPool(function(parent)
        local t = parent:CreateTexture(nil, "ARTWORK", nil, 0)
        t:SetColorTexture(1, 1, 1, 0.08)
        return t
    end)

    -- Transparent overlay drives the continuous cursor-tracking tooltip (GraphTrack).
    f.graphOverlay = CreateFrame("Frame", nil, graph)
    f.graphOverlay:SetAllPoints(graph)
    f.graphOverlay:SetFrameLevel(graph:GetFrameLevel() + 8)
    f.graphOverlay:SetScript("OnUpdate", function(self) GraphTrack(self) end)

    -- ── Combat event table ────────────────────────────────────────────────────────
    f.tableTop = nil  -- set in ResolveLayout()
    local function MakeHdr(justify) local fs = MakeFontString(f, "GameFontDisableSmall", justify)
        fs:SetTextColor(unpack(BDR.UI.TEXT_DIM)); return fs end
    f.hdrTime    = MakeHdr("LEFT")
    f.hdrAbility = MakeHdr("LEFT")
    f.hdrType    = MakeHdr("CENTER")
    f.hdrAmount  = MakeHdr("RIGHT")
    f.hdrPct     = MakeHdr("RIGHT")
    f.hdrTime:SetText(L.TBL_TIME)
    f.hdrAbility:SetText(L.TBL_ABILITY)
    f.hdrType:SetText(L.TBL_TYPE)
    f.hdrAmount:SetText(L.TBL_AMOUNT)
    f.hdrPct:SetText(L.TBL_PCTHP)

    local scroll = CreateFrame("ScrollFrame", "BetterDeathRecapTableScroll", f, "UIPanelScrollFrameTemplate")
    f.tableScroll = scroll
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    f.tableChild = child
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local range = self:GetVerticalScrollRange()
        local cur   = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(range, cur - delta * (ROW_H + ROW_GAP) * 2)))
    end)
    StyleScrollbar("BetterDeathRecapTableScrollScrollBar")

    f.rowPool = NewPool(function(parent)
        local row = CreateFrame("Button", nil, parent)
        row:SetHeight(ROW_H)
        row.bgTex = row:CreateTexture(nil, "BACKGROUND")
        row.bgTex:SetAllPoints()
        row.hl = row:CreateTexture(nil, "BORDER")          -- gold hover/selection wash
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(BDR.UI.GOLD[1], BDR.UI.GOLD[2], BDR.UI.GOLD[3], 0.16)
        row.hl:Hide()
        row.accent = row:CreateTexture(nil, "ARTWORK")     -- left type-accent bar
        row.accent:SetPoint("TOPLEFT"); row.accent:SetPoint("BOTTOMLEFT"); row.accent:SetWidth(2)
        row.time = MakeFontString(row, "GameFontDisableSmall", "LEFT")
        row.time:SetPoint("LEFT", C_TIME_X, 0); row.time:SetWidth(C_TIME_W)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(C_ICON_W, C_ICON_W)
        row.icon:SetPoint("LEFT", row.time, "RIGHT", 2, 0)
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        row.text = MakeFontString(row, "GameFontHighlightSmall", "LEFT")
        row.text:SetPoint("LEFT", row, "LEFT", C_NAME_X, 0)
        -- "% Max HP": a big flat bar at the right edge, the number to its LEFT.
        row.pctBarBg = row:CreateTexture(nil, "ARTWORK", nil, 0)  -- bar track
        row.pctBarBg:SetColorTexture(0.18, 0.10, 0.10, 1)
        row.pctBarBg:SetHeight(10)
        row.pctBarBg:SetPoint("RIGHT", -C_PCT_PAD, 0)
        row.pctBarBg:SetWidth(C_PCT_BAR_W)
        row.pctBar = row:CreateTexture(nil, "ARTWORK", nil, 1)    -- fill, width ∝ share of max HP
        row.pctBar:SetHeight(10)
        row.pctBar:SetPoint("LEFT", row.pctBarBg, "LEFT", 0, 0)
        row.pct = MakeFontString(row, "GameFontDisableSmall", "RIGHT")
        row.pct:SetPoint("RIGHT", row.pctBarBg, "LEFT", -C_PCT_GAP, 0); row.pct:SetWidth(C_PCT_NUM_W)
        row.dmg = MakeFontString(row, "GameFontHighlightSmall", "RIGHT")
        row.dmg:SetPoint("RIGHT", row.pct, "LEFT", -8, 0); row.dmg:SetWidth(C_DMG_W)
        row.typeBg = row:CreateTexture(nil, "ARTWORK")
        row.typeBg:SetPoint("RIGHT", row.dmg, "LEFT", -12, 0)
        row.typeBg:SetSize(C_TYPE_W, 14)
        row.typeTxt = MakeFontString(row, "GameFontDisableSmall", "CENTER")
        row.typeTxt:SetPoint("CENTER", row.typeBg, "CENTER", 0, 0)
        row.text:SetPoint("RIGHT", row.typeBg, "LEFT", -8, 0)
        return row
    end)

    f.scrollHint = MakeFontString(f, "GameFontDisableSmall", "CENTER")
    f.scrollHint:SetTextColor(unpack(BDR.UI.TEXT_DIM))
    f.scrollHint:Hide()

    -- ── Section dividers (positioned in render; thin gray lines) ─────────────────
    local function MakeDivider()
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetColorTexture(unpack(BDR.UI.DIVIDER))
        t:SetHeight(1)
        t:Hide()
        return t
    end
    f.divSources = MakeDivider()
    f.divTotal   = MakeDivider()
    f.divFooter  = MakeDivider()

    -- ── Damage sources ───────────────────────────────────────────────────────────
    f.srcHeader = MakeFontString(f, "GameFontDisableSmall", "LEFT")
    f.srcHeader:SetTextColor(unpack(BDR.UI.TEXT_DIM))
    f.srcHeader:SetText(L.SOURCES_HEADER:upper())

    local srcScroll = CreateFrame("ScrollFrame", "BetterDeathRecapSrcScroll", f, "UIPanelScrollFrameTemplate")
    f.srcScroll = srcScroll
    local srcChild = CreateFrame("Frame", nil, srcScroll)
    srcChild:SetSize(1, 1)
    srcScroll:SetScrollChild(srcChild)
    f.srcChild = srcChild
    srcScroll:EnableMouseWheel(true)
    srcScroll:SetScript("OnMouseWheel", function(self, delta)
        local range = self:GetVerticalScrollRange()
        local cur   = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(range, cur - delta * SRC_ROW_H * 2)))
    end)
    StyleScrollbar("BetterDeathRecapSrcScrollScrollBar")

    f.srcRowPool = NewPool(function(parent)
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(SRC_ROW_H)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(14, 14)
        row.icon:SetPoint("LEFT", 0, 0)
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        row.name = MakeFontString(row, "GameFontHighlightSmall", "LEFT")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0); row.name:SetWidth(120)
        row.amount = MakeFontString(row, "GameFontDisableSmall", "RIGHT")
        row.amount:SetPoint("RIGHT", 0, 0); row.amount:SetWidth(64)
        row.pct = MakeFontString(row, "GameFontHighlightSmall", "RIGHT")
        row.pct:SetPoint("RIGHT", row.amount, "LEFT", -10, 0); row.pct:SetWidth(44)
        row.barBg = row:CreateTexture(nil, "ARTWORK", nil, 0)   -- bigger flat bar
        row.barBg:SetColorTexture(0.18, 0.10, 0.10, 1)
        row.barBg:SetHeight(10)
        row.barBg:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
        row.barBg:SetPoint("RIGHT", row.pct, "LEFT", -10, 0)
        row.barFill = row:CreateTexture(nil, "ARTWORK", nil, 1)
        row.barFill:SetPoint("LEFT", row.barBg, "LEFT", 0, 0)
        row.barFill:SetHeight(10)
        return row
    end)
    f.srcTotalLabel = MakeFontString(f, "GameFontHighlightSmall", "CENTER")
    f.srcTotalAmount = MakeFontString(f, "GameFontHighlightSmall", "RIGHT")
    f.srcTotalPct = MakeFontString(f, "GameFontHighlightSmall", "RIGHT")
    f.srcTotalPct:SetTextColor(unpack(BDR.UI.TEXT_DIM))

    -- ── Footer ─────────────────────────────────────────────────────────────────
    f.footer = MakeFontString(f, "GameFontDisableSmall", "LEFT")
    f.footerHint = MakeFontString(f, "GameFontDisableSmall", "RIGHT")

    f.emptyText = MakeFontString(f, "GameFontHighlight", "CENTER")
    f.emptyText:SetText(L.EMPTY)
    f.emptyText:Hide()

    ApplyLockState(f)
    return f
end

local function EnsureFrame()
    if not F then F = BuildFrame() end
    return F
end

-- ── shared graph mapping + hover sync ────────────────────────────────────────

local function GraphX(t)
    local m = F.mapT
    if not m then return 0 end
    return math.max(0, math.min(m.gw, (t - m.first) / m.xMax * m.gw))
end

-- Highlight an event everywhere: vertical line on the curve, a gold glow on its
-- marker, and a gold wash on its table row (the addon's core sync feature).
local function HoverEvent(ev)
    if not (ev and F.mapT) then return end
    F.graphHL:ClearAllPoints()
    F.graphHL:SetPoint("BOTTOMLEFT", F.graph, "BOTTOMLEFT", GraphX(ev.t) - 0.5, 0)
    F.graphHL:SetSize(1, F.mapT.gh)
    F.graphHL:Show()
    local pos = F.markerPos and F.markerPos[ev]
    if pos then
        F.markerGlow:ClearAllPoints()
        F.markerGlow:SetPoint("CENTER", F.graph, "BOTTOMLEFT", pos.x, pos.y)
        F.markerGlow:SetSize(pos.r + 12, pos.r + 12)
        F.markerGlow:Show()
    else
        F.markerGlow:Hide()
    end
    local row = F.rowOf and F.rowOf[ev]
    if row then row.hl:Show() end
end

local function UnhoverEvent(ev)
    F.graphHL:Hide()
    F.markerGlow:Hide()
    local row = ev and F.rowOf and F.rowOf[ev]
    if row and not row.isKB then row.hl:Hide() end
end

-- ── rendering ────────────────────────────────────────────────────────────────

local function RenderBanner(report)
    local kb = report.killingBlow
    if not kb then
        F.bannerIcon:Hide()
        F.bannerSpellBtn.spellID = nil
        F.bannerKilledBy:SetText(ColorOf(BDR.UI.DAMAGE) .. L.KILLED_BY .. "|r")
        F.bannerSource:SetText("|cff999999" .. L.BANNER_UNKNOWN .. "|r")
        F.bannerAmount:SetText("")
        F.bannerOver:SetText("")
        return
    end
    local icon = SpellIcon(kb.spellID)
    F.bannerIcon:SetTexture(icon or "Interface\\Icons\\Ability_Creature_Cursed_05")
    F.bannerIcon:Show()
    F.bannerSpellBtn.spellID = kb.spellID  -- drives the spell tooltip on hover

    F.bannerKilledBy:SetText(ColorOf(BDR.UI.DAMAGE) .. L.KILLED_BY .. "|r")
    -- Only show the "• <spell>" segment for an actual spell (melee blows have no ID).
    local spellName = kb.spellID and SpellNameAt(kb) or kb.spellName
    local spell = spellName and ("  " .. ColorOf(BDR.UI.TEXT_DIM) .. "•|r  "
        .. ColorOf(BDR.UI.TEXT) .. spellName .. "|r") or ""
    F.bannerSource:SetText(ColorOf(BDR.UI.NAME_YELLOW) .. (kb.sourceName or L.UNKNOWN) .. "|r" .. spell)

    -- Headline number = total damage taken in the window (matches the "Total
    -- Damage" row), attributed to the killing blow named above. Falls back to the
    -- killing-blow amount when no source totals are available.
    local total = 0
    for _, s in ipairs(report.sources or {}) do total = total + (s.total or 0) end
    if total <= 0 then total = kb.amount or 0 end
    F.bannerAmount:SetText(ColorOf(BDR.UI.DAMAGE) .. FormatFull(total) .. "|r")
    F.bannerOver:SetText(kb.overkill
        and ("|cff888888" .. L.OVERKILL:format(FormatAmount(kb.overkill)) .. "|r") or "")
end

local function RenderGraph(report)
    local graph = F.graph
    PoolReset(F.graphLinePool)
    PoolReset(F.graphFillPool)
    PoolReset(F.dotPool)
    PoolReset(F.tailPool)
    PoolReset(F.xtickPool)
    PoolReset(F.xminorPool)
    F.graphHL:Hide(); F.markerGlow:Hide()
    F.markerPos = {}
    F.trackRow = nil
    F.tracking = false

    local gw, gh = graph:GetWidth(), graph:GetHeight()
    local curve = report.healthCurve or {}
    if #curve < 2 then
        F.mapT = nil
        F.graphLabel:SetText(L.HP_HEADER:format(
            (report.context and report.context.windowSeconds) or BDR.CONFIG.WINDOW_SECONDS))
        F.graphNote:SetText(L.HP_UNAVAILABLE)
        F.graphNote:Show()
        return
    end
    F.graphNote:Hide()

    -- Time model: 0s = first event ("into combat"); death sits at X=duration, and
    -- the plot runs to duration + TAIL_SECONDS so the killing blow isn't flush right.
    local first    = curve[1].t            -- oldest (most-negative) time
    local duration = -first
    local xMax     = duration + TAIL_SECONDS
    if xMax <= 0 then xMax = 1 end
    F.graphLabel:SetText(L.HP_HEADER:format(math.max(1, math.floor(duration + 0.5))))

    local function X(t)   return (t - first) / xMax * gw end
    local function Y(pct)
        pct = math.max(Y_AXIS_MIN, math.min(100, pct))
        return (pct - Y_AXIS_MIN) / (100 - Y_AXIS_MIN) * gh
    end

    -- X axis: whole-second labels + 0.5s minor ticks (only over the live duration).
    for s = 0, math.floor(duration) do
        local fs = PoolNext(F.xtickPool, graph)
        fs:ClearAllPoints()
        fs:SetPoint("TOP", graph, "BOTTOMLEFT", s / xMax * gw, -2)
        fs:SetText(s .. "s")
    end
    local minor = 0.5
    while minor <= duration do
        if minor % 1 ~= 0 then
            local tick = PoolNext(F.xminorPool, graph)
            tick:ClearAllPoints()
            tick:SetPoint("BOTTOM", graph, "BOTTOMLEFT", minor / xMax * gw, 0)
            tick:SetSize(1, 4)
        end
        minor = minor + 0.5
    end

    -- Area fill: stepped columns tinted by HP (cosmetic urgency mirror of the line).
    for px = 0, gw, 2 do
        local t = first + (px / gw) * xMax
        if t <= 0 then
            local h = Y(StepPctAt(curve, t))
            if h > 0 then
                local col = PoolNext(F.graphFillPool, graph)
                local c = HpColor(StepPctAt(curve, t))
                col:SetColorTexture(c[1], c[2], c[3], 0.16)
                col:ClearAllPoints()
                col:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", px, 0)
                col:SetSize(2.5, h)
            end
        end
    end

    -- Stepped line, gradient by HP (horizontal hold, then a vertical drop per hit).
    local function Seg(x1, y1, x2, y2, c)
        local line = PoolNext(F.graphLinePool, graph)
        line:SetThickness(2)
        line:SetColorTexture(c[1], c[2], c[3], 1)
        line:SetStartPoint("BOTTOMLEFT", graph, x1, y1)
        line:SetEndPoint("BOTTOMLEFT", graph, x2, y2)
    end
    for i = 2, #curve do
        local a, b = curve[i - 1], curve[i]
        Seg(X(a.t), Y(a.pct), X(b.t), Y(a.pct), HpColor(a.pct))
        Seg(X(b.t), Y(a.pct), X(b.t), Y(b.pct), HpColor(math.min(a.pct, b.pct)))
    end

    -- Post-death dashed fading tail at HP = 0, from the death point to the edge.
    local deathX, zeroY = X(0), Y(0)
    local tx, alpha = deathX + 5, 0.7
    while tx < gw do
        local d = PoolNext(F.tailPool, graph)
        d:SetColorTexture(BDR.UI.HP_LOW[1], BDR.UI.HP_LOW[2], BDR.UI.HP_LOW[3], math.max(0.08, alpha))
        d:ClearAllPoints()
        d:SetPoint("LEFT", graph, "BOTTOMLEFT", tx, zeroY)
        d:SetSize(4, 2)
        tx, alpha = tx + 8, alpha - 0.06
    end

    -- Event dots on the line, coloured by damage school (heals green); KB bigger.
    for _, ev in ipairs(report.hits or report.events or {}) do
        if ev.t >= first and ev.t <= 0 then
            local gx, gy = X(ev.t), Y(StepPctAt(curve, ev.t))
            local color = (ev.kind == "heal") and BDR.UI.HEAL or (SchoolInfo(ev.school))
            local r = ev.isKillingBlow and 8 or 5
            local d = PoolNext(F.dotPool, graph)
            d:SetSize(r * 2, r * 2)
            d:ClearAllPoints()
            d:SetPoint("CENTER", graph, "BOTTOMLEFT", gx, gy)
            d.fill:SetVertexColor(color[1], color[2], color[3], 1)
            F.markerPos[ev] = { x = gx, y = gy, r = r * 2 }
        end
    end

    F.mapT = { first = first, xMax = xMax, gw = gw, gh = gh, curve = curve,
               hits = report.hits or report.events or {} }
end

-- Positions the table column header + the scrollable rows; returns the y below.
local function RenderTable(report)
    PoolReset(F.rowPool)
    F.rowOf = {}
    local hits = report.hits or report.events or {}

    -- Newest first (chronological list is oldest→newest; reverse it).
    local ordered = {}
    for i = #hits, 1, -1 do ordered[#ordered + 1] = hits[i] end
    local total = #ordered

    -- Column header (aligned to the row columns).
    local hy = F.tableTop
    F.hdrTime:ClearAllPoints();    F.hdrTime:SetPoint("TOPLEFT", PAD + C_TIME_X, hy)
    F.hdrAbility:ClearAllPoints(); F.hdrAbility:SetPoint("TOPLEFT", PAD + C_NAME_X, hy)
    local OFF       = PAD + SCROLLBAR_W
    local barRight  = OFF + C_PCT_PAD                            -- right edge of the bar
    local numRight  = barRight + C_PCT_BAR_W + C_PCT_GAP         -- right edge of the % number
    local dmgRight  = numRight + C_PCT_NUM_W + 8
    local typeRight = dmgRight + C_DMG_W + 12
    F.hdrPct:ClearAllPoints()
    F.hdrPct:SetPoint("TOPRIGHT", -barRight, hy)                 -- label spans the whole column
    F.hdrPct:SetWidth(C_PCT_BAR_W + C_PCT_GAP + C_PCT_NUM_W)
    F.hdrAmount:ClearAllPoints(); F.hdrAmount:SetPoint("TOPRIGHT", -dmgRight, hy); F.hdrAmount:SetWidth(C_DMG_W)
    F.hdrType:ClearAllPoints();   F.hdrType:SetPoint("TOPRIGHT", -typeRight, hy);  F.hdrType:SetWidth(C_TYPE_W)

    local stride    = ROW_H + ROW_GAP
    local shown     = math.min(TL_VISIBLE_ROWS, math.max(total, 1))
    local rowW      = WINDOW_W - 2 * PAD - SCROLLBAR_W
    local scrollTop = F.tableTop - TBL_HDR
    local viewportH = shown * stride

    F.tableScroll:ClearAllPoints()
    F.tableScroll:SetPoint("TOPLEFT", PAD, scrollTop)
    F.tableScroll:SetSize(rowW, viewportH)
    F.tableChild:SetSize(rowW, math.max(viewportH, total * stride))
    F.tableScroll:SetVerticalScroll(0)
    F.tableScroll:Show()
    local bar = _G["BetterDeathRecapTableScrollScrollBar"]
    if bar then if total > shown then bar:Show() else bar:Hide() end end

    local curve = report.healthCurve or {}
    local y = 0
    for idx, ev in ipairs(ordered) do
        local row = PoolNext(F.rowPool, F.tableChild)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", F.tableChild, "TOPLEFT", 0, y)
        row:SetWidth(rowW)
        F.rowOf[ev] = row

        local isHeal = ev.kind == "heal"
        local hpLevel = PctAtT(curve, ev.t)             -- HP% at the moment of this event
        local dmgC = isHeal and BDR.UI.HEAL or BDR.UI.DAMAGE

        row.time:SetText(ev.t == 0 and "0.0s" or string.format("%.1fs", ev.t))
        -- Ability icon, always shown: spell icon by ID (melee carries spell 88163).
        row.icon:SetTexture(SpellIcon(ev.spellID) or SpellIcon(88163) or "Interface\\ICONS\\INV_Sword_04")
        row.icon:Show()
        row.text:SetText(SpellNameAt(ev))

        -- Amount: signed (− damage / + heal), coloured red / green.
        row.dmg:SetText((isHeal and "+" or "-") .. FormatFull(ev.amount))

        -- "% Max HP" = the HP level at that moment + a bar of the same length
        -- (green for heals, red for damage); matches the graph curve at that time.
        row.pct:SetText(string.format("%d%%", math.floor(hpLevel + 0.5)))
        row.pct:SetTextColor(unpack(BDR.UI.TEXT_DIM))
        row.pctBar:SetColorTexture(dmgC[1], dmgC[2], dmgC[3], 0.9)
        row.pctBar:SetWidth(math.max(1, C_PCT_BAR_W * math.min(100, hpLevel) / 100))
        row.pctBarBg:Show(); row.pctBar:Show()

        -- Type pill: Hit/DoT in red, Heal/HoT in green.
        local typeLabel
        if isHeal then typeLabel = ev.periodic and L.TYPE_HOT or L.TYPE_HEAL
        else           typeLabel = ev.periodic and L.TYPE_DOT or L.TYPE_HIT end
        row.typeBg:SetColorTexture(dmgC[1], dmgC[2], dmgC[3], 0.16)
        row.typeTxt:SetText(typeLabel)
        row.typeTxt:SetTextColor(dmgC[1], dmgC[2], dmgC[3])

        -- Row background: alternating shade, KB strong red, type accent bar.
        row.isKB = ev.isKillingBlow
        if ev.isKillingBlow then
            row.bgTex:SetColorTexture(unpack(BDR.UI.ROW_KB_BG))
            row.hl:Show()
            row.accent:SetColorTexture(unpack(BDR.UI.DAMAGE)); row.accent:Show()
            row.dmg:SetTextColor(1, 0.4, 0.4)
        else
            local alt = (idx % 2 == 0)
            row.bgTex:SetColorTexture(unpack(alt and BDR.UI.ROW_ALT or { 0.05, 0.05, 0.065, 1 }))
            row.hl:Hide()
            row.accent:SetColorTexture(dmgC[1], dmgC[2], dmgC[3]); row.accent:Show()
            row.dmg:SetTextColor(unpack(dmgC))
        end

        row.ev = ev
        row:SetScript("OnEnter", function(self)
            HoverEvent(self.ev)
            if self.ev.spellID and GameTooltip.SetSpellByID then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")  -- top-center of the row
                GameTooltip:SetSpellByID(self.ev.spellID)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function(self) UnhoverEvent(self.ev); GameTooltip:Hide() end)
        y = y - stride
    end

    -- "Scroll for more" hint when the list overflows the viewport.
    local yBottom = scrollTop - viewportH
    if total > shown then
        F.scrollHint:ClearAllPoints()
        F.scrollHint:SetPoint("TOP", F.tableScroll, "BOTTOM", 0, -2)
        F.scrollHint:SetText("▼ " .. L.SCROLL_MORE)
        F.scrollHint:Show()
        yBottom = yBottom - 12
    else
        F.scrollHint:Hide()
    end
    return yBottom
end

local function RenderSources(report, yTop)
    PoolReset(F.srcRowPool)
    local sources = report.sources or {}

    -- Divider, then the gray section header.
    F.divSources:ClearAllPoints()
    F.divSources:SetPoint("TOPLEFT", PAD, yTop)
    F.divSources:SetPoint("TOPRIGHT", -PAD, yTop)
    F.divSources:Show()

    local y = yTop - 8
    F.srcHeader:ClearAllPoints()
    F.srcHeader:SetPoint("TOPLEFT", PAD, y)
    y = y - SRC_HDR

    local grand = 0
    for _, s in ipairs(sources) do grand = grand + (s.total or 0) end

    -- Scrollable list (scrollbar only appears when it overflows the viewport).
    local count      = #sources
    local shown      = math.min(SRC_VISIBLE_ROWS, math.max(count, 1))
    local needScroll = count > shown
    local rowW       = WINDOW_W - 2 * PAD - (needScroll and SCROLLBAR_W or 0)
    local viewportH  = shown * SRC_ROW_H

    F.srcScroll:ClearAllPoints()
    F.srcScroll:SetPoint("TOPLEFT", PAD, y)
    F.srcScroll:SetSize(rowW, viewportH)
    F.srcChild:SetSize(rowW, math.max(viewportH, count * SRC_ROW_H))
    F.srcScroll:SetVerticalScroll(0)
    F.srcScroll:Show()
    local bar = _G["BetterDeathRecapSrcScrollScrollBar"]
    if bar then if needScroll then bar:Show() else bar:Hide() end end

    local ry = 0
    for i, s in ipairs(sources) do
        local row = PoolNext(F.srcRowPool, F.srcChild)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", F.srcChild, "TOPLEFT", 0, ry)
        row:SetWidth(rowW)

        local icon = SpellIcon(s.spellID)
        if icon then row.icon:SetTexture(icon); row.icon:Show() else row.icon:Hide() end
        row.name:SetText(s.name or L.UNKNOWN)
        row.name:SetTextColor(unpack(BDR.UI.TEXT))
        row.pct:SetText(string.format("%.1f%%", s.pct or 0))
        row.pct:SetTextColor(unpack(BDR.UI.TEXT))
        row.amount:SetText(FormatFull(s.total))
        row.amount:SetTextColor(unpack(BDR.UI.TEXT_DIM))

        local c = (i == 1) and BDR.UI.SOURCE_PRIMARY or BDR.UI.SOURCE_OTHER
        row.barFill:SetColorTexture(c[1], c[2], c[3], 1)
        -- Bar spans from after the name (x≈147) to before the pct column; the
        -- name/pct/amount column widths are fixed, so compute it directly rather
        -- than reading barBg:GetWidth() (anchors aren't resolved until next draw).
        local bw = math.max(1, (rowW - 275))
        row.barFill:SetWidth(math.max(1, bw * (s.pct or 0) / 100))
        ry = ry - SRC_ROW_H
    end
    y = y - viewportH

    -- Divider, then the centered Total Damage row.
    y = y - 4
    F.divTotal:ClearAllPoints()
    F.divTotal:SetPoint("TOPLEFT", PAD, y)
    F.divTotal:SetPoint("TOPRIGHT", -PAD, y)
    F.divTotal:Show()
    y = y - 6

    F.srcTotalLabel:ClearAllPoints()
    F.srcTotalLabel:SetPoint("TOP", F, "TOP", 0, y)
    F.srcTotalLabel:SetText(ColorOf(BDR.UI.TEXT) .. L.TOTAL_DAMAGE .. "|r")
    F.srcTotalPct:ClearAllPoints()
    F.srcTotalPct:SetPoint("TOPRIGHT", -PAD, y); F.srcTotalPct:SetWidth(44)
    F.srcTotalPct:SetText("100%")
    F.srcTotalAmount:ClearAllPoints()
    F.srcTotalAmount:SetPoint("TOPRIGHT", F.srcTotalPct, "LEFT", -10, 0); F.srcTotalAmount:SetWidth(80)
    F.srcTotalAmount:SetText(ColorOf(BDR.UI.TEXT) .. FormatFull(grand) .. "|r")

    return y - SRC_TOTAL_H
end

local function RenderFooter(report, yTop)
    local ctx = report.context or {}
    local parts = {}
    if ctx.difficulty then parts[#parts + 1] = ctx.difficulty end
    if ctx.zone then parts[#parts + 1] = ctx.zone end
    parts[#parts + 1] = L.FOOTER_WINDOW:format(ctx.windowSeconds or BDR.CONFIG.WINDOW_SECONDS)

    -- Divider above the footer.
    F.divFooter:ClearAllPoints()
    F.divFooter:SetPoint("TOPLEFT", PAD, yTop)
    F.divFooter:SetPoint("TOPRIGHT", -PAD, yTop)
    F.divFooter:Show()
    local y = yTop - 7

    F.footer:ClearAllPoints()
    F.footer:SetPoint("TOPLEFT", PAD, y)
    F.footer:SetText(ColorOf(BDR.UI.TEXT_DIM) .. table.concat(parts, "  •  "):upper() .. "|r")

    F.footerHint:ClearAllPoints()
    F.footerHint:SetPoint("TOPRIGHT", -PAD, y)
    F.footerHint:SetText(ColorOf(BDR.UI.TEXT_DIM)
        .. (report.isSample and L.FOOTER_SAMPLE or L.FOOTER_HINT):upper() .. "|r")

    return y - FOOTER_H
end

-- ── public API ───────────────────────────────────────────────────────────────

local function ResolveLayout()
    local yBanner   = -PAD - TITLE_H
    local yGraphHdr = yBanner - BANNER_H - HDR_GAP
    local yCanvas   = yGraphHdr - GRAPH_HDR
    F.tableTop = yCanvas - GRAPH_H - XAXIS_H - 12
end

function Display:Show(report)
    if not report then return end
    EnsureFrame()
    F.report = report
    ResolveLayout()

    RenderBanner(report)
    RenderGraph(report)

    local yBottom
    if report.empty then
        F.emptyText:ClearAllPoints()
        F.emptyText:SetPoint("TOP", F.graph, "BOTTOM", 0, -40)
        F.emptyText:Show()
        PoolReset(F.rowPool); PoolReset(F.srcRowPool)
        F.tableScroll:Hide(); F.scrollHint:Hide(); F.srcScroll:Hide()
        F.divSources:Hide(); F.divTotal:Hide()
        F.hdrTime:Hide(); F.hdrAbility:Hide(); F.hdrType:Hide(); F.hdrAmount:Hide(); F.hdrPct:Hide()
        F.srcHeader:Hide(); F.srcTotalLabel:Hide(); F.srcTotalAmount:Hide(); F.srcTotalPct:Hide()
        yBottom = RenderFooter(report, F.tableTop)
    else
        F.emptyText:Hide()
        F.hdrTime:Show(); F.hdrAbility:Show(); F.hdrType:Show(); F.hdrAmount:Show(); F.hdrPct:Show()
        F.srcHeader:Show(); F.srcTotalLabel:Show(); F.srcTotalAmount:Show(); F.srcTotalPct:Show()
        local yAfterTbl = RenderTable(report)
        local yAfterSrc = RenderSources(report, yAfterTbl - 10)
        yBottom = RenderFooter(report, yAfterSrc - 6)
    end

    F:SetHeight(-yBottom + PAD)
    F:Show()
end

function Display:Toggle()
    EnsureFrame()
    if F:IsShown() then F:Hide(); return end
    local report = BDR.Analyzer:Build()
    if not (report and not report.empty) then report = BDR.DB.lastReport end
    if report then
        self:Show(report)
    else
        BDR.Print(BDR.COLOR.WARN .. L.NO_DEATH .. BDR.COLOR.RESET)
    end
end

function Display:RefreshIfShown(report)
    if F and F:IsShown() and report then self:Show(report) end
end

function Display:ShowLast()
    local report = BDR.DB.lastReport
    if not report then
        BDR.Print(BDR.COLOR.WARN .. L.NO_HISTORY .. BDR.COLOR.RESET)
        return
    end
    self:Show(report)
end

function Display:Hide()
    if F then F:Hide() end
end

function Display:SetLocked(locked)
    EnsureFrame()
    BDR.DB.locked = locked
    ApplyLockState()
end
