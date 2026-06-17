local _, BDR = ...

-- Display — the recap window. Built once, lazily, then re-populated from a
-- DeathReport on every Show(). Layout follows PLAN.md / BetterDeathRecap_UI_v2:
--   Header (title + scale control + close)
--   Death summary banner (who/what killed you + amount + overkill)
--   Health-timeline graph (the hero; curve + event markers + hover sync)
--   Combat event table (scrollable; Time/Event/Source/Damage/Remaining Health, newest top)
--   Damage sources (per-attacker bars + total)
--   Encounter footer (difficulty · zone · window)
-- Variable-count visuals come from small object pools so we never leak frames.

local Display = {}
BDR.Display = Display

local L = BDR.L  -- Locale.lua loads before Display.lua, so BDR.L is ready here.

-- ── layout constants (vertical stack, top → bottom) ──────────────────────────
local WINDOW_W   = 560
local PAD        = 12
local GUTTER     = 0           -- (was the health-% axis-label margin; labels removed → reclaimed)
local TITLE_H    = 26
local BANNER_H   = 46
local HDR_GAP    = 12
local GRAPH_HDR  = 28          -- header+legend row height; clears the canvas top below it
local GRAPH_H    = 152         -- HP-graph canvas height (the hero)
local XAXIS_H    = 14
local OVERVIEW_H = 34          -- overview/brush strip below the graph (zoom scrollbar)
local Y_AXIS_MIN   = -5        -- y-axis floor (%) so the death line isn't flush at the bottom
local Y_AXIS_MAX   = 105       -- y-axis ceiling (%) so the 100% line has headroom (not flush at top)
local GRAPH_PAD    = 0.2       -- seconds of breathing room added BEFORE the first hit AND after death
local MIN_ZOOM_SPAN = 0.5      -- tightest zoom-in: the visible window can't go below this (seconds)
local DOT_TEX = "Interface\\COMMON\\Indicator-Gray"  -- a REAL filled circle (tintable) for graph dots
local TBL_HDR    = 16          -- table column-header row
local ROW_H      = 18
local ROW_GAP    = 1
local SRC_HDR    = 16
local SRC_ROW_H  = 18
local SRC_TOTAL_H = 20
local FOOTER_H   = 10          -- half-height footer; text vertically centred in the band

local TL_VISIBLE_ROWS  = 5     -- combat-table viewport height (rows); the rest scrolls
local SRC_VISIBLE_ROWS = 5     -- damage-sources viewport height (rows); the rest scrolls
local SCROLLBAR_W      = 22

-- Table column geometry. A borderless grid: every column LEFT-aligned at its own x.
-- Columns: Time · [tombstone on the KB] · Event(icon+name) · Source · Damage ·
-- Remaining Health (`NN%` right-aligned tight to a flat bar). Source is wide; the HP
-- number sits close to its bar. The rightmost edge (HP bar end ≈509) clears the
-- reserved scrollbar so nothing hides under it when the list overflows 5 rows.
local C_TIME_X    = 6
local C_TIME_W    = 46          -- "−16.000s" (3-decimal / millisecond precision)
local C_DEATH_W   = 13          -- tombstone slot right of the time (KB row only)
local C_ICON_W    = 16
local C_ICON_X    = C_TIME_X + C_TIME_W + C_DEATH_W + 2      -- event spell icon
local C_EVENT_X   = C_ICON_X + C_ICON_W + 4                  -- spell name, right of the icon
local C_EVENT_W   = 100
local C_SOURCE_X  = C_EVENT_X + C_EVENT_W + 6               -- attacker name (wide)
local C_SOURCE_W  = 122
local C_DMG_X     = C_SOURCE_X + C_SOURCE_W + 6            -- damage number (left-aligned)
local C_DMG_W     = 58
local C_HP_NUM_W  = 34          -- "100%", right-aligned tight to the bar
local C_HP_BAR_X  = C_DMG_X + C_DMG_W + 12 + C_HP_NUM_W + 4  -- flat bar left edge
local C_HP_BAR_W  = 80

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

-- Does this atlas exist on the live client? (Used to pick the death marker's icon.)
local function AtlasExists(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

-- Apply the death/grave marker to a texture: prefer the graveyard atlas (a
-- tombstone, reliably present), else the BDR.DEATH_ICON texture path.
local function ApplyDeathIcon(tex)
    if tex.SetAtlas and AtlasExists("poi-graveyard-neutral") then
        tex:SetAtlas("poi-graveyard-neutral")
    else
        tex:SetTexture(BDR.DEATH_ICON)
    end
end

-- Restyle a UIPanelScrollFrameTemplate scrollbar to the MODERN retail look: a thin
-- track, a chunky gray thumb, and small chevron up/down arrows (the minimal atlas
-- when the client has it). Everything is guarded so a missing piece degrades
-- gracefully. (ElvUI, if loaded, reskins on top of this.)
local function StyleScrollbar(barName)
    local bar = _G[barName]
    if not bar then return end
    bar:SetWidth(8)

    local thumb = (bar.GetThumbTexture and bar:GetThumbTexture()) or _G[barName .. "ThumbTexture"]
    if thumb then
        thumb:SetColorTexture(0.45, 0.45, 0.48, 0.9)
        thumb:SetSize(5, 48)
    end
    for _, suffix in ipairs({ "Track", "Background", "Top", "Bottom", "Middle" }) do
        local t = _G[barName .. suffix]
        if t and t.SetAlpha then t:SetAlpha(0) end
    end

    local function styleArrow(btn, atlas)
        if not btn then return end
        btn:SetSize(12, 12)
        if btn.SetNormalAtlas and AtlasExists(atlas) then
            btn:SetNormalAtlas(atlas); btn:SetPushedAtlas(atlas); btn:SetDisabledAtlas(atlas)
        end
        local function fit(tex) if tex then tex:ClearAllPoints(); tex:SetAllPoints(btn) end end
        local n = btn.GetNormalTexture and btn:GetNormalTexture()
        local p = btn.GetPushedTexture and btn:GetPushedTexture()
        local d = btn.GetDisabledTexture and btn:GetDisabledTexture()
        local h = btn.GetHighlightTexture and btn:GetHighlightTexture()
        fit(n); fit(p); fit(d); fit(h)
        if n then n:SetVertexColor(0.6, 0.6, 0.64) end
        if p then p:SetVertexColor(0.85, 0.85, 0.9) end
        if d then d:SetVertexColor(0.3, 0.3, 0.32) end
        if h then h:SetAlpha(0) end
    end
    styleArrow(_G[barName .. "ScrollUpButton"],   "minimal-scrollbar-arrow-top")
    styleArrow(_G[barName .. "ScrollDownButton"], "minimal-scrollbar-arrow-bottom")
end

-- Apply a new window scale (buttons commit immediately), persist + refresh label.
local function SetWindowScale(v)
    v = math.max(BDR.CONFIG.SCALE_MIN, math.min(BDR.CONFIG.SCALE_MAX, math.floor(v * 10 + 0.5) / 10))
    BDR.DB.scale = v                       -- the displayed slider value (1.0 = baseline)
    F:SetScale(v * BDR.CONFIG.SCALE_BASE)   -- actual frame scale (baseline is 1.3×)
end

-- ── Continuous cursor-tracking tooltip (the graph's "foolproof" hover) ───────
-- A transparent overlay over the graph; its OnUpdate maps the cursor X to a time,
-- finds the nearest hit, and shows a tooltip that follows the cursor with no dead
-- zones. F.mapT (set by RenderGraph) holds the time/HP mapping + the hit list.

local RenderGraph   -- forward declaration (GraphTrack re-renders the graph while panning)

-- Dotted vertical cursor crosshair: a column of short dashes at graph-x `gx` (pooled,
-- redrawn each hover frame — a solid texture can't be dashed, same trick as tailPool).
local function ShowCrosshair(gx)
    if not (F and F.crosshairPool and F.graph) then return end
    PoolReset(F.crosshairPool)
    local h = (F.mapT and F.mapT.gh) or F.graph:GetHeight()
    local y = 1
    while y < h do
        local d = PoolNext(F.crosshairPool, F.graph)
        d:SetColorTexture(0.92, 0.92, 0.96, 0.55)
        d:ClearAllPoints()
        d:SetPoint("BOTTOMLEFT", F.graph, "BOTTOMLEFT", gx - 0.5, y)
        d:SetSize(1, 3)          -- 3px dash …
        y = y + 6                -- … + 3px gap
    end
end

local function HideCrosshair()
    if F and F.crosshairPool then PoolReset(F.crosshairPool) end
end

local function GraphTrackStop()
    if not (F and F.tracking) then return end
    F.tracking = false
    HideCrosshair(); F.markerGlow:Hide()
    if F.hoverDot then F.hoverDot:Hide() end
    if F.trackRow then F.trackRow.hl:Hide(); F.trackRow = nil end
    if GameTooltip:GetOwner() == F.graphOverlay then GameTooltip:Hide() end
end

local function GraphTrack(overlay)
    local m = F and F.mapT
    if not m then return end

    if overlay.movingWindow then return end   -- dragging the whole window: no tooltip/scrub

    -- Drag-to-pan the zoomed window (continues even if the cursor leaves the graph).
    if overlay.panning then
        local cur  = GetCursorPosition() / overlay:GetEffectiveScale()
        local span = overlay.panSpan
        local dt   = -(cur - overlay.panStartX) / m.gw * span   -- drag right → earlier times
        local newMin = overlay.panStartMin + dt
        if newMin < m.fullMin then newMin = m.fullMin end
        if newMin + span > m.fullMax then newMin = m.fullMax - span end
        if newMin < m.fullMin then newMin = m.fullMin end
        F.zoomMin, F.zoomMax = newMin, newMin + span
        if RenderGraph then RenderGraph(F.report) end
        return
    end

    if not overlay:IsMouseOver() then GraphTrackStop(); return end
    F.tracking = true

    local scale = overlay:GetEffectiveScale()
    local gx = (GetCursorPosition() / scale) - F.graph:GetLeft()
    if gx < 0 then gx = 0 elseif gx > m.gw then gx = m.gw end

    local relT = gx / m.gw * m.span + m.xMinT   -- cursor X → relative-to-death seconds
    if relT > 0 then relT = 0 end

    -- Nearest hit by X-axis proximity.
    local nearest, nd
    for _, ev in ipairs(m.hits) do
        local ex = (ev.t - m.xMinT) / m.span * m.gw
        local d = math.abs(ex - gx)
        if not nd or d < nd then nd, nearest = d, ev end
    end

    -- Dotted crosshair at the cursor.
    ShowCrosshair(gx)

    local hp = StepPctAt(m.curve, relT)   -- stepped, to match the stepped line

    -- Small dot where the crosshair meets the HP line (the value point under the cursor).
    local hpY = (math.max(Y_AXIS_MIN, math.min(Y_AXIS_MAX, hp)) - Y_AXIS_MIN)
                / (Y_AXIS_MAX - Y_AXIS_MIN) * m.gh
    F.hoverDot:ClearAllPoints()
    F.hoverDot:SetPoint("CENTER", F.graph, "BOTTOMLEFT", gx, hpY)
    F.hoverDot:Show()

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

    -- On a dot, report the hit's OWN time/HP (its pre-hit currentHP — e.g. the KB's
    -- real ~2%, not the 0% at death); off a dot, report the cursor's stepped HP.
    local hpR = math.floor(((onHit and (nearest.hpPct or StepPctAt(m.curve, nearest.t))) or hp) + 0.5)
    -- Pin the tooltip to the graph's TOP edge at the cursor's X — it follows the line
    -- horizontally instead of floating with the cursor (like the table's row tooltip).
    GameTooltip:SetOwner(overlay, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    if gx < m.gw * 0.5 then
        GameTooltip:SetPoint("BOTTOMLEFT", F.graph, "TOPLEFT", gx, 6)
    else
        GameTooltip:SetPoint("BOTTOMRIGHT", F.graph, "TOPLEFT", gx, 6)
    end
    -- Minimal line (default yellow): the killing blow gets its own callout, every
    -- other point shows seconds-before-death + HP. (NOT "seconds into combat".)
    if onHit and nearest.isKillingBlow then
        GameTooltip:AddLine(L.TIP_KB_AT:format(hpR), 1, 0.82, 0)
    elseif onHit then
        GameTooltip:AddLine(L.TIP_BEFORE_DEATH:format(-nearest.t, hpR), 1, 0.82, 0)
    else
        GameTooltip:AddLine(L.TIP_BEFORE_DEATH:format(-relT, hpR), 1, 0.82, 0)
    end
    -- Hovering a dot expands to the hit detail: icon+spell, then Source/School/Hit/Hit%.
    if onHit then
        local isHeal = nearest.kind == "heal"
        local dc = isHeal and BDR.UI.HEAL or BDR.UI.DAMAGE
        GameTooltip:AddLine(" ")
        local icon = SpellIcon(nearest.spellID) or nearest.iconOverride
        local nameLine = SpellNameAt(nearest)
        if icon then nameLine = string.format("|T%s:16:16|t %s", icon, nameLine) end
        GameTooltip:AddLine(nameLine, BDR.UI.TEXT[1], BDR.UI.TEXT[2], BDR.UI.TEXT[3])
        GameTooltip:AddDoubleLine(L.TIP_SOURCE .. ":", nearest.sourceName or L.UNKNOWN,
            0.7, 0.7, 0.7, 0.95, 0.95, 0.95)
        local _, schoolName = SchoolInfo(nearest.school)
        GameTooltip:AddDoubleLine(L.TIP_SCHOOL .. ":", (schoolName ~= "" and schoolName) or "—",
            0.7, 0.7, 0.7, 0.95, 0.95, 0.95)
        GameTooltip:AddDoubleLine(L.TYPE_HIT .. ":", (isHeal and "+" or "-") .. FormatFull(nearest.amount),
            0.7, 0.7, 0.7, dc[1], dc[2], dc[3])
        local b, a = HpStep(m.curve, nearest.t)
        GameTooltip:AddDoubleLine(L.TIP_HIT_PCT .. ":", string.format("%+.1f%%", a - b),
            0.7, 0.7, 0.7, dc[1], dc[2], dc[3])
    end
    GameTooltip:Show()
end

-- ── Overview / brush (the horizontal zoom-scroll strip below the graph) ──────
-- The brush mirrors the visible [zoomMin..zoomMax] window over the FULL timeline.
-- Dragging its body SCROLLS (pans) the zoom; dragging an edge grip RESIZES (zooms).
-- All three modes share `OverviewDrag`, run from an OnUpdate installed only while a
-- drag is live. Re-renders the graph each frame so the brush tracks the cursor.
local function OverviewDrag()
    if not (F and F.ovDragMode and F.mapT) then return end
    local m, ov = F.mapT, F.overview
    local ovW, full = ov:GetWidth(), (m.fullMax - m.fullMin)
    if ovW <= 0 or full <= 0 then return end
    local cur = GetCursorPosition() / ov:GetEffectiveScale()
    local dt  = (cur - F.ovDragStartX) / ovW * full     -- cursor delta → time delta
    local vMin, vMax = F.ovStartMin, F.ovStartMax
    if F.ovDragMode == "pan" then
        local span = vMax - vMin
        vMin = vMin + dt
        if vMin < m.fullMin then vMin = m.fullMin end
        if vMin + span > m.fullMax then vMin = m.fullMax - span end
        vMax = vMin + span
    elseif F.ovDragMode == "left" then
        vMin = math.min(math.max(m.fullMin, vMin + dt), vMax - MIN_ZOOM_SPAN)
    elseif F.ovDragMode == "right" then
        vMax = math.max(math.min(m.fullMax, vMax + dt), vMin + MIN_ZOOM_SPAN)
    end
    if vMin <= m.fullMin + 1e-3 and vMax >= m.fullMax - 1e-3 then
        F.zoomMin, F.zoomMax = nil, nil          -- brush spans everything → full view
    else
        F.zoomMin, F.zoomMax = vMin, vMax
    end
    if RenderGraph then RenderGraph(F.report) end
end

local function OverviewDragStart(mode)
    local m = F and F.mapT
    if not m then return end
    F.ovDragMode   = mode
    F.ovDragStartX = GetCursorPosition() / F.overview:GetEffectiveScale()
    F.ovStartMin   = F.zoomMin or m.fullMin
    F.ovStartMax   = F.zoomMax or m.fullMax
    GraphTrackStop()
    F.overview:SetScript("OnUpdate", function() OverviewDrag() end)
end

local function OverviewDragStop()
    if not F then return end
    F.ovDragMode = nil
    F.overview:SetScript("OnUpdate", nil)
end

local function BuildFrame()
    local f = CreateFrame("Frame", "BetterDeathRecapFrame", UIParent, "BackdropTemplate")
    f:SetSize(WINDOW_W, 480)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:Hide()

    -- Background drawn by the backdrop itself (bgFile), clipped inside the border
    -- insets — a separate full-rect texture used to poke past the rounded corners.
    -- Square frame: a 1px straight border (no rounded tooltip edge — sharp corners).
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropColor(unpack(BDR.UI.BG))
    f:SetBackdropBorderColor(unpack(BDR.UI.BORDER_GRAY))

    local p = BDR.DB.point
    f:SetPoint(p[1], UIParent, p[3], p[4], p[5])
    f:SetScale((BDR.DB.scale or 1.0) * BDR.CONFIG.SCALE_BASE)

    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not BDR.DB.locked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)
    table.insert(UISpecialFrames, "BetterDeathRecapFrame")  -- close on Escape

    -- ── Header ─────────────────────────────────────────────────────────────────
    -- Anchored FLUSH to the 1px border (offset 1, not 5) so the opaque header strip
    -- touches the frame edge. Otherwise the translucent (alpha 0.7) background shows
    -- through the gap and the header reads as "floating".
    local headerBg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    headerBg:SetColorTexture(0.08, 0.08, 0.10, 1)
    headerBg:SetPoint("TOPLEFT", 1, -1)
    headerBg:SetPoint("TOPRIGHT", -1, -1)
    headerBg:SetHeight(TITLE_H)
    local headerLine = f:CreateTexture(nil, "ARTWORK")
    headerLine:SetColorTexture(unpack(BDR.UI.BORDER_GRAY))
    headerLine:SetPoint("BOTTOMLEFT", headerBg, "BOTTOMLEFT", 0, 0)
    headerLine:SetPoint("BOTTOMRIGHT", headerBg, "BOTTOMRIGHT", 0, 0)
    headerLine:SetHeight(1)

    -- Left-aligned title (per DESIGN.png): "Better" red, "DeathRecap" primary text.
    local title = MakeFontString(f, "GameFontNormalLarge", "LEFT")
    title:SetPoint("LEFT", headerBg, "LEFT", 10, 0)
    title:SetJustifyH("LEFT")
    title:SetJustifyV("MIDDLE")
    title:SetText(ColorOf(BDR.UI.DAMAGE) .. "Better|r" .. ColorOf(BDR.UI.TEXT) .. "DeathRecap|r")

    -- Right side: the STANDARD WoW close button (`UIPanelCloseButton`) so ElvUI (and
    -- other skins) restyle it like Blizzard's own — a plain white "×" that picks up
    -- the skin's hover colour. Vertically centred in the header like the title.
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("RIGHT", headerBg, "RIGHT", -2, 0)
    close:SetScript("OnClick", function() f:Hide() end)
    -- The "×" is the legacy UIPanelCloseButton, which ElvUI does NOT auto-skin on a
    -- custom frame — so re-skin it ourselves via ElvUI's own Skins module if present
    -- (soft, dependency-free, pcall-guarded). No-op when ElvUI isn't loaded.
    if _G.ElvUI then
        pcall(function()
            local E = unpack(_G.ElvUI)
            local S = E and E.GetModule and E:GetModule("Skins")
            if S and S.HandleCloseButton then S:HandleCloseButton(close) end
        end)
    end
    -- ElvUI's skin can re-anchor the button to the frame corner; pin it back to the
    -- header's vertical centre so every header item shares one midline.
    close:ClearAllPoints()
    close:SetPoint("RIGHT", headerBg, "RIGHT", -2, 0)

    -- Slider is anchored to the header (NOT chained off the close button) so it stays
    -- vertically centred even if a skin moves the close button. -36 clears the ~32px
    -- close button to its right.
    local scaleSlider = CreateFrame("Slider", nil, f)
    scaleSlider:SetSize(108, 14)
    scaleSlider:SetPoint("RIGHT", headerBg, "RIGHT", -36, 0)
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
    -- Flush to the header bottom (no gap) and to the left/right borders (offset 1, like
    -- the header), so it spans edge-to-edge directly under the title bar.
    local yBanner = -1 - TITLE_H
    local banner = CreateFrame("Frame", nil, f)
    banner:SetPoint("TOPLEFT", 1, yBanner)
    banner:SetPoint("TOPRIGHT", -1, yBanner)
    banner:SetHeight(BANNER_H)
    local bb = banner:CreateTexture(nil, "BACKGROUND")
    bb:SetAllPoints()
    bb:SetColorTexture(0.16, 0.05, 0.05, 1)
    local bbBorder = banner:CreateTexture(nil, "ARTWORK")
    bbBorder:SetColorTexture(0.45, 0.12, 0.12, 1)
    bbBorder:SetPoint("BOTTOMLEFT"); bbBorder:SetPoint("BOTTOMRIGHT"); bbBorder:SetHeight(1)

    -- (No big right-side portrait model: a 3D model can render OVER the 2D
    -- amount/overkill text. The SOURCE portrait is the small one over the icon below.)
    f.bannerIcon = banner:CreateTexture(nil, "ARTWORK")
    f.bannerIcon:SetSize(40, 40)   -- larger: fills more of the banner; still square
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

    -- The SOURCE portrait = the STOCK 2D unit-frame face, drawn on top of the spell/env
    -- icon (which shows through as the fallback). The PlayerModel below is now just an
    -- invisible (alpha-0) resolver for the creature's displayID — see SetCreaturePortrait.
    f.bannerPortrait = banner:CreateTexture(nil, "ARTWORK", nil, 2)
    f.bannerPortrait:SetPoint("TOPLEFT", f.bannerIcon, "TOPLEFT", 0, 0)
    f.bannerPortrait:SetPoint("BOTTOMRIGHT", f.bannerIcon, "BOTTOMRIGHT", 0, 0)
    f.bannerPortrait:Hide()
    f.bannerSourceModel = CreateFrame("PlayerModel", nil, banner)
    f.bannerSourceModel:SetAllPoints(f.bannerIcon)
    f.bannerSourceModel:SetFrameLevel(banner:GetFrameLevel() + 3)
    f.bannerSourceModel:SetAlpha(0)
    f.bannerSourceModel:Hide()

    -- Left block: KILLED BY (top) + killer • spell (below). Its TOP is aligned with
    -- the Damage number's top on the right (both at banner top -6); each carries a
    -- second line stacked below.
    -- Anchored to the banner top (not the icon) so its top edge matches the Damage
    -- number's top on the right; x sits just past the 40px icon (12 + 40 + outline + gap).
    f.bannerKilledBy = MakeFontString(banner, "GameFontDisableSmall", "LEFT")
    f.bannerKilledBy:SetPoint("TOPLEFT", banner, "TOPLEFT", 62, -6)
    f.bannerKilledBy:SetText(ColorOf(BDR.UI.DAMAGE) .. L.KILLED_BY .. "|r")

    -- The killer • spell (left) and the overkill line (right) are BOTH bottom-anchored
    -- to the banner so they share one baseline (Source/Spell aligned with overkill).
    f.bannerSource = MakeFontString(banner, "GameFontNormal", "LEFT")
    f.bannerSource:SetPoint("BOTTOMLEFT", banner, "BOTTOMLEFT", 62, 7)

    -- Right block: Damage (top) + overkill (bottom-aligned with killer • spell).
    f.bannerAmount = MakeFontString(banner, "GameFontNormalLarge", "RIGHT")
    f.bannerAmount:SetFont("Fonts\\FRIZQT__.TTF", 21, "")
    f.bannerAmount:SetPoint("TOPRIGHT", banner, "TOPRIGHT", -10, -6)

    f.bannerOver = MakeFontString(banner, "GameFontDisableSmall", "RIGHT")
    f.bannerOver:SetPoint("BOTTOMRIGHT", banner, "BOTTOMRIGHT", -10, 7)

    -- Hovering the killer • spell text shows the real spell tooltip, anchored above
    -- the centre of that text (and only over it — like the table rows).
    f.bannerSpellBtn = CreateFrame("Button", nil, banner)
    f.bannerSpellBtn:SetPoint("TOPLEFT", f.bannerSource, "TOPLEFT", -2, 2)
    f.bannerSpellBtn:SetPoint("BOTTOMRIGHT", f.bannerSource, "BOTTOMRIGHT", 2, -2)
    f.bannerSpellBtn:SetFrameLevel(banner:GetFrameLevel() + 5)
    f.bannerSpellBtn:SetScript("OnEnter", function(self)
        if self.spellID and GameTooltip.SetSpellByID then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetSpellByID(self.spellID)
            GameTooltip:Show()
        end
    end)
    f.bannerSpellBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- ── Graph header (label only — the legend was redundant, removed) ────────────
    local yGraphHdr = yBanner - BANNER_H - HDR_GAP
    f.graphLabel = MakeFontString(f, "GameFontDisableSmall", "LEFT")
    f.graphLabel:SetPoint("TOPLEFT", PAD, yGraphHdr)
    f.graphLabel:SetTextColor(unpack(BDR.UI.TEXT_DIM))

    -- Interaction hint at the graph's top-right: scroll = zoom, drag = pan.
    f.graphHint = MakeFontString(f, "GameFontDisableSmall", "RIGHT")
    f.graphHint:SetPoint("TOPRIGHT", -PAD, yGraphHdr)
    f.graphHint:SetTextColor(unpack(BDR.UI.TEXT_DIM))
    f.graphHint:SetText(L.GRAPH_HINT:upper())

    -- ── Graph canvas ─────────────────────────────────────────────────────────────
    local yCanvas = yGraphHdr - GRAPH_HDR
    local graphW = WINDOW_W - PAD - GUTTER - PAD
    local graph = CreateFrame("Frame", nil, f)
    graph:SetPoint("TOPLEFT", PAD + GUTTER, yCanvas)
    graph:SetSize(graphW, GRAPH_H)
    graph:SetClipsChildren(true)   -- so zoomed-out-of-range line/dots can't spill the canvas
    f.graph = graph

    local canvas = graph:CreateTexture(nil, "BACKGROUND")
    canvas:SetAllPoints()
    canvas:SetColorTexture(unpack(BDR.UI.PANEL_BG))

    -- No Y-axis labels (removed) — HP maps into [Y_AXIS_MIN..Y_AXIS_MAX], so 0% sits a
    -- touch above the bottom and 100% a touch below the top. The width those labels
    -- used to reserve (GUTTER) is reclaimed by the graph + overview strip.

    f.graphLinePool = NewPool(function(parent) return parent:CreateLine(nil, "OVERLAY") end)

    -- Post-death dashed fading tail (so the killing-blow dot isn't flush right).
    f.tailPool = NewPool(function(parent) return parent:CreateTexture(nil, "ARTWORK", nil, 2) end)

    -- Event markers: a small school-coloured ROUND dot on the line (heals green) with a
    -- thin dark ring; the KB dot is a bit bigger. Uses a REAL circular texture (DOT_TEX)
    -- — NOT SetMask (masking didn't render on the live client and left the "yellow
    -- squares"). `fill` is tinted to the school colour via SetVertexColor in RenderGraph;
    -- the dark `border` is 1px larger and sits behind, giving a thin ring.
    f.dotPool = NewPool(function(parent)
        local d = CreateFrame("Frame", nil, parent)
        d:SetFrameLevel(parent:GetFrameLevel() + 4)
        d.border = d:CreateTexture(nil, "ARTWORK", nil, 0)
        d.border:SetTexture(DOT_TEX)
        d.border:SetVertexColor(0, 0, 0, 0.9)
        d.border:SetPoint("TOPLEFT", -1, 1)
        d.border:SetPoint("BOTTOMRIGHT", 1, -1)
        d.fill = d:CreateTexture(nil, "ARTWORK", nil, 1)
        d.fill:SetTexture(DOT_TEX)
        d.fill:SetAllPoints()
        return d
    end)

    -- Dotted vertical cursor crosshair (the common "hover line" pattern) + dot glow.
    -- Pooled dashes (ShowCrosshair); follows the cursor and the table→graph hover sync.
    f.crosshairPool = NewPool(function(parent) return parent:CreateTexture(nil, "OVERLAY", nil, 3) end)
    f.markerGlow = graph:CreateTexture(nil, "OVERLAY", nil, 2)
    f.markerGlow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    f.markerGlow:SetBlendMode("ADD")
    f.markerGlow:SetVertexColor(unpack(BDR.UI.GOLD))
    f.markerGlow:Hide()

    -- A tiny dot that rides the HP line where the crosshair (dotted cursor line) meets
    -- it, marking the exact point under the cursor. (Round, real texture — same DOT_TEX.)
    f.hoverDot = CreateFrame("Frame", nil, graph)
    f.hoverDot:SetFrameLevel(graph:GetFrameLevel() + 6)
    f.hoverDot:SetSize(7, 7)
    local hdBorder = f.hoverDot:CreateTexture(nil, "OVERLAY", nil, 4)
    hdBorder:SetTexture(DOT_TEX); hdBorder:SetVertexColor(0, 0, 0, 0.9)
    hdBorder:SetPoint("TOPLEFT", -1, 1); hdBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    f.hoverDot.fill = f.hoverDot:CreateTexture(nil, "OVERLAY", nil, 5)
    f.hoverDot.fill:SetTexture(DOT_TEX); f.hoverDot.fill:SetAllPoints()
    f.hoverDot.fill:SetVertexColor(1, 1, 1, 1)
    f.hoverDot:Hide()

    f.graphNote = MakeFontString(graph, "GameFontDisableSmall", "CENTER")
    f.graphNote:SetPoint("CENTER", graph, "CENTER", 0, 0)
    f.graphNote:Hide()
    f.mapT = nil

    -- X axis: seconds-before-death labels (pooled); no minor ticks (grid removed).
    f.xtickPool  = NewPool(function(parent)
        local fs = MakeFontString(parent, "GameFontDisableSmall", "CENTER")
        fs:SetTextColor(unpack(BDR.UI.TEXT_DIM))
        return fs
    end)

    -- Death marker at the death point on the x-axis (in place of a "DEATH" label).
    -- Prefer Blizzard's graveyard/tombstone atlas (a grave marker, reliably present);
    -- fall back to the `BDR.DEATH_ICON` texture if the atlas is missing. Hover names
    -- the moment of death.
    f.deathMarker = CreateFrame("Frame", nil, f)   -- on `f` (not graph) so the clip won't hide it
    f.deathMarker:SetSize(BDR.DEATH_ICON_SIZE, BDR.DEATH_ICON_SIZE)
    f.deathMarker:EnableMouse(true)
    f.deathMarker.tex = f.deathMarker:CreateTexture(nil, "OVERLAY")
    f.deathMarker.tex:SetAllPoints()
    ApplyDeathIcon(f.deathMarker.tex)
    f.deathMarker:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(L.AXIS_DEATH:upper(), BDR.UI.DAMAGE[1], BDR.UI.DAMAGE[2], BDR.UI.DAMAGE[3])
        GameTooltip:Show()
    end)
    f.deathMarker:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.deathMarker:Hide()

    -- Transparent overlay drives the continuous cursor-tracking tooltip (GraphTrack).
    f.graphOverlay = CreateFrame("Frame", nil, graph)
    f.graphOverlay:SetAllPoints(graph)
    f.graphOverlay:SetFrameLevel(graph:GetFrameLevel() + 8)
    f.graphOverlay:SetScript("OnUpdate", function(self) GraphTrack(self) end)

    -- ── Graph overview / zoom-scroll strip ───────────────────────────────────────
    -- A compressed view of the WHOLE timeline with a draggable "brush" window that
    -- mirrors the zoomed range. Drag the brush body to SCROLL, drag an edge grip to
    -- ZOOM. (Mouse-wheel on the main graph still zooms; this is the horizontal scroll.)
    local yOverview = yCanvas - GRAPH_H - XAXIS_H - 8
    local ov = CreateFrame("Frame", nil, f, "BackdropTemplate")
    ov:SetPoint("TOPLEFT", PAD + GUTTER, yOverview)
    ov:SetSize(graphW, OVERVIEW_H)
    ov:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    ov:SetBackdropColor(unpack(BDR.UI.PANEL_BG))
    ov:SetBackdropBorderColor(BDR.UI.BORDER_GRAY[1], BDR.UI.BORDER_GRAY[2], BDR.UI.BORDER_GRAY[3], 0.6)
    ov:SetClipsChildren(true)
    f.overview = ov
    f.ovLinePool = NewPool(function(parent) return parent:CreateLine(nil, "ARTWORK") end)

    -- Dim the OUT-of-view ranges (left + right of the brush) so the window pops.
    f.ovDimL = ov:CreateTexture(nil, "OVERLAY", nil, 1); f.ovDimL:SetColorTexture(0, 0, 0, 0.5)
    f.ovDimR = ov:CreateTexture(nil, "OVERLAY", nil, 1); f.ovDimR:SetColorTexture(0, 0, 0, 0.5)

    -- The brush (visible-range window): body drag = pan ONLY. Zoom is the scroll-wheel
    -- (graph or this strip) — NO edge-resize grips, because players kept accidentally
    -- resizing when they meant to scroll.
    local brush = CreateFrame("Frame", nil, ov)
    brush:SetFrameLevel(ov:GetFrameLevel() + 4)
    brush:EnableMouse(true); brush:RegisterForDrag("LeftButton")
    f.ovBrush = brush
    local bfill = brush:CreateTexture(nil, "BACKGROUND")
    bfill:SetAllPoints(); bfill:SetColorTexture(BDR.UI.GOLD[1], BDR.UI.GOLD[2], BDR.UI.GOLD[3], 0.12)
    for _, side in ipairs({ "LEFT", "RIGHT" }) do
        local edge = brush:CreateTexture(nil, "ARTWORK")
        edge:SetColorTexture(unpack(BDR.UI.GOLD))
        edge:SetPoint("TOP" .. side); edge:SetPoint("BOTTOM" .. side); edge:SetWidth(2)
    end
    brush:SetScript("OnDragStart", function() OverviewDragStart("pan") end)
    brush:SetScript("OnDragStop", OverviewDragStop)

    -- ◄ ► move-handles in the brush centre, so it's obvious it can be dragged sideways.
    local function MakeArrow(dir)
        local a = brush:CreateTexture(nil, "OVERLAY")
        a:SetSize(9, 9)
        a:SetVertexColor(unpack(BDR.UI.GOLD))
        a:SetPoint("CENTER", brush, "CENTER", dir == "left" and -5 or 5, 0)
        local atlas = (dir == "left") and "common-icon-backarrow" or "common-icon-forwardarrow"
        if a.SetAtlas and AtlasExists(atlas) then
            a:SetAtlas(atlas, false)
        else                                   -- fallback: rotate the classic up-arrow
            a:SetTexture("Interface\\Buttons\\Arrow-Up-Up")
            a:SetRotation((dir == "left") and (math.pi / 2) or (-math.pi / 2))
        end
        return a
    end
    f.ovArrowL = MakeArrow("left")
    f.ovArrowR = MakeArrow("right")

    -- Scroll-wheel over the overview ZOOMS too (centred on the cursor's spot in the
    -- strip), mirroring the main graph's wheel-zoom so the brush stays in sync.
    ov:EnableMouseWheel(true)
    ov:SetScript("OnMouseWheel", function(self, delta)
        local m = F.mapT
        if not (m and F.report) then return end
        local ovW = self:GetWidth()
        local ox  = (GetCursorPosition() / self:GetEffectiveScale()) - self:GetLeft()
        ox = math.max(0, math.min(ovW, ox))
        local full    = m.fullMax - m.fullMin
        local cursorT = m.fullMin + (ovW > 0 and ox / ovW or 0.5) * full
        local curMin  = F.zoomMin or m.fullMin
        local curMax  = F.zoomMax or m.fullMax
        local newSpan = math.max(MIN_ZOOM_SPAN, math.min((curMax - curMin) * (delta > 0 and 0.8 or 1.25), full))
        local newMin  = cursorT - newSpan / 2
        local newMax  = newMin + newSpan
        if newMin < m.fullMin then newMin, newMax = m.fullMin, m.fullMin + newSpan end
        if newMax > m.fullMax then newMax, newMin = m.fullMax, m.fullMax - newSpan end
        if newMin < m.fullMin then newMin = m.fullMin end
        if newSpan >= full - 1e-3 then F.zoomMin, F.zoomMax = nil, nil
        else F.zoomMin, F.zoomMax = newMin, newMax end
        if RenderGraph then RenderGraph(F.report) end
    end)

    -- ── Combat event table ────────────────────────────────────────────────────────
    f.tableTop = nil  -- set in ResolveLayout()
    local function MakeHdr(justify) local fs = MakeFontString(f, "GameFontDisableSmall", justify)
        fs:SetTextColor(unpack(BDR.UI.TEXT_DIM)); return fs end
    f.hdrTime   = MakeHdr("LEFT")
    f.hdrEvent  = MakeHdr("LEFT")
    f.hdrSource = MakeHdr("LEFT")
    f.hdrDamage = MakeHdr("LEFT")
    f.hdrPct    = MakeHdr("LEFT")
    f.hdrTime:SetText(L.TBL_TIME)
    f.hdrEvent:SetText(L.TBL_EVENT)
    f.hdrSource:SetText(L.TBL_SOURCE)
    f.hdrDamage:SetText(L.TBL_DAMAGE)
    f.hdrPct:SetText(L.TBL_REMAINING)

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
        -- Every column is LEFT-aligned at its own x; all text truncates in-row
        -- (SetWordWrap false) rather than wrapping to a second line.
        row.time = MakeFontString(row, "GameFontDisableSmall", "LEFT")
        row.time:SetPoint("LEFT", C_TIME_X, 0); row.time:SetWidth(C_TIME_W); row.time:SetWordWrap(false)
        -- Tombstone marker right of the time (snug after "0.0s", not crowding the Event
        -- column), shown ONLY on the killing-blow row.
        row.deathIcon = row:CreateTexture(nil, "ARTWORK")
        row.deathIcon:SetSize(C_DEATH_W, C_DEATH_W)
        row.deathIcon:SetPoint("LEFT", row, "LEFT", C_TIME_X + C_TIME_W - 6, 0)
        ApplyDeathIcon(row.deathIcon)
        row.deathIcon:Hide()
        -- Event: spell icon + name.
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(C_ICON_W, C_ICON_W)
        row.icon:SetPoint("LEFT", row, "LEFT", C_ICON_X, 0)
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        row.text = MakeFontString(row, "GameFontHighlightSmall", "LEFT")
        row.text:SetPoint("LEFT", row, "LEFT", C_EVENT_X, 0); row.text:SetWidth(C_EVENT_W)
        row.text:SetWordWrap(false)
        -- Source: the attacker name.
        row.source = MakeFontString(row, "GameFontHighlightSmall", "LEFT")
        row.source:SetPoint("LEFT", row, "LEFT", C_SOURCE_X, 0); row.source:SetWidth(C_SOURCE_W)
        row.source:SetWordWrap(false)
        -- Damage: the number, left-aligned.
        row.dmg = MakeFontString(row, "GameFontHighlightSmall", "LEFT")
        row.dmg:SetPoint("LEFT", row, "LEFT", C_DMG_X, 0); row.dmg:SetWidth(C_DMG_W); row.dmg:SetWordWrap(false)
        -- Remaining HP: a flat bar with the % number right-aligned tight to its left.
        row.pctBarBg = row:CreateTexture(nil, "ARTWORK", nil, 0)  -- fat bar track (covers the row)
        row.pctBarBg:SetColorTexture(0.18, 0.10, 0.10, 1)
        row.pctBarBg:SetHeight(ROW_H - 4)
        row.pctBarBg:SetPoint("LEFT", row, "LEFT", C_HP_BAR_X, 0)
        row.pctBarBg:SetWidth(C_HP_BAR_W)
        row.pctBar = row:CreateTexture(nil, "ARTWORK", nil, 1)    -- fill, width ∝ HP%
        row.pctBar:SetHeight(ROW_H - 4)
        row.pctBar:SetPoint("LEFT", row.pctBarBg, "LEFT", 0, 0)
        row.pct = MakeFontString(row, "GameFontHighlightSmall", "RIGHT")
        row.pct:SetPoint("RIGHT", row.pctBarBg, "LEFT", -4, 0); row.pct:SetWidth(C_HP_NUM_W)
        row.pct:SetWordWrap(false)
        -- Event hover zone (icon + spell name): shows the SPELL tooltip; the rest of
        -- the row shows the Time/Damage/HP tooltip (see RenderTable).
        row.eventBtn = CreateFrame("Button", nil, row)
        row.eventBtn:SetPoint("TOPLEFT", row, "TOPLEFT", C_ICON_X, 0)
        row.eventBtn:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", C_ICON_X, 0)
        row.eventBtn:SetWidth(C_SOURCE_X - C_ICON_X)
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

    -- Meter-style row: a FAT bar covers the whole row; the source icon, name, and
    -- raw total sit ON TOP of it (Details/Recount look).
    f.srcRowPool = NewPool(function(parent)
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(SRC_ROW_H)
        row.barBg = row:CreateTexture(nil, "BACKGROUND")              -- full-row track
        row.barBg:SetColorTexture(0.16, 0.09, 0.09, 1)
        row.barBg:SetPoint("TOPLEFT", 0, -1)
        row.barBg:SetPoint("BOTTOMRIGHT", 0, 1)
        row.barFill = row:CreateTexture(nil, "BACKGROUND", nil, 1)    -- fill, width ∝ share
        row.barFill:SetPoint("TOPLEFT", row.barBg, "TOPLEFT", 0, 0)
        row.barFill:SetPoint("BOTTOMLEFT", row.barBg, "BOTTOMLEFT", 0, 0)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(SRC_ROW_H - 4, SRC_ROW_H - 4)
        row.icon:SetPoint("LEFT", 2, 0)
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        -- Source PORTRAIT = the STOCK 2D unit-frame face over the icon (spell/env icon
        -- shows underneath as a fallback). `row.portrait` is now just the invisible
        -- displayID resolver; `row.portrait2D` is the painted 2D portrait.
        row.portrait2D = row:CreateTexture(nil, "ARTWORK", nil, 2)
        row.portrait2D:SetPoint("TOPLEFT", row.icon, "TOPLEFT", 0, 0)
        row.portrait2D:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 0, 0)
        row.portrait2D:Hide()
        row.portrait = CreateFrame("PlayerModel", nil, row)
        row.portrait:SetAllPoints(row.icon)
        row.portrait:SetFrameLevel(row:GetFrameLevel() + 2)
        row.portrait:SetAlpha(0)
        row.portrait:Hide()
        row.amount = MakeFontString(row, "GameFontHighlightSmall", "RIGHT")
        row.amount:SetPoint("RIGHT", -6, 0); row.amount:SetWidth(82)
        row.name = MakeFontString(row, "GameFontHighlightSmall", "LEFT")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
        row.name:SetPoint("RIGHT", row.amount, "LEFT", -8, 0)
        row.name:SetJustifyH("LEFT"); row.name:SetWordWrap(false)
        return row
    end)
    -- Total Damage line doubles as the collapse/expand toggle for the sources list
    -- (no ▶/▼ icon — a hover tooltip explains the click instead).
    f.srcTotalBtn = CreateFrame("Button", nil, f)
    f.srcTotalBtn:SetHeight(SRC_TOTAL_H)
    f.srcTotalLabel = MakeFontString(f.srcTotalBtn, "GameFontHighlightSmall", "CENTER")
    f.srcTotalLabel:SetPoint("CENTER", f.srcTotalBtn, "CENTER", 0, 0)
    f.srcTotalBtn:SetScript("OnClick", function()
        BDR.DB.sourcesCollapsed = not BDR.DB.sourcesCollapsed
        if F.report then Display:Show(F.report) end
    end)
    f.srcTotalBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(BDR.DB.sourcesCollapsed and L.SRC_EXPAND or L.SRC_COLLAPSE, 1, 0.82, 0)
        GameTooltip:Show()
    end)
    f.srcTotalBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
    return math.max(0, math.min(m.gw, (t - m.xMinT) / m.span * m.gw))
end

-- Highlight an event everywhere: vertical line on the curve, a gold glow on its
-- marker, and a gold wash on its table row (the addon's core sync feature).
local function HoverEvent(ev)
    if not (ev and F.mapT) then return end
    ShowCrosshair(GraphX(ev.t))
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
    HideCrosshair()
    F.markerGlow:Hide()
    local row = ev and F.rowOf and F.rowOf[ev]
    if row and not row.isKB then row.hl:Hide() end
end

-- ── rendering ────────────────────────────────────────────────────────────────

-- Render the SOURCE's STOCK 2D portrait — the flat unit-frame face WoW uses — onto
-- `tex2D`, resolved from the recap event's sourceGUID (`Creature-0-…-ID-spawn`). There
-- is no GUID→2D-portrait call, so we use a hidden `model` purely to resolve the
-- creature's displayID (`SetCreature` → `GetDisplayInfo` once it loads), then
-- `SetPortraitTextureFromCreatureDisplayID`. On no creatureID / failure, `tex2D` hides
-- and the spell/env icon underneath shows (which is what Blizzard's own recap shows).
-- Everything is pcall-guarded so a model/API quirk can never error the report.
local function SetCreaturePortrait(tex2D, model, guid)
    if not (tex2D and model) then return end
    local npcID
    if type(guid) == "string" then
        local unitType, _, _, _, _, id = strsplit("-", guid)
        if (unitType == "Creature" or unitType == "Vehicle") and id then npcID = tonumber(id) end
    end
    tex2D:Hide()
    if not npcID then model:SetScript("OnModelLoaded", nil); model:Hide(); return end

    local function apply()
        local okd, displayID = pcall(function() return model:GetDisplayInfo() end)
        if okd and type(displayID) == "number" and displayID > 0
           and SetPortraitTextureFromCreatureDisplayID then
            if pcall(SetPortraitTextureFromCreatureDisplayID, tex2D, displayID) then
                tex2D:SetTexCoord(0, 1, 0, 1)
                tex2D:Show()
            end
        end
    end

    model:SetScript("OnModelLoaded", apply)
    model:SetAlpha(0); model:Show()                       -- invisible resolver; shown so it loads
    pcall(function() model:ClearModel(); model:SetCreature(npcID) end)
    apply()                                               -- in case the display is already cached
    if C_Timer and C_Timer.After then C_Timer.After(0.15, apply) end
end

local function RenderBanner(report)
    local kb = report.killingBlow
    if not kb then
        F.bannerIcon:Hide()
        SetCreaturePortrait(F.bannerPortrait, F.bannerSourceModel, nil)
        F.bannerSpellBtn.spellID = nil
        F.bannerKilledBy:SetText(ColorOf(BDR.UI.DAMAGE) .. L.KILLED_BY .. "|r")
        F.bannerSource:SetText(ColorOf(BDR.UI.TEXT) .. L.BANNER_UNKNOWN .. "|r")
        F.bannerAmount:SetText("")
        F.bannerOver:SetText("")
        return
    end
    -- The "KILLED BY" icon shows the SOURCE: environmental → its stock icon; a creature
    -- → its STOCK 2D portrait (over the icon); the spell icon shows underneath as a
    -- fallback when no creature portrait can be resolved.
    if kb.isEnv then
        F.bannerIcon:SetTexture(kb.iconOverride or "Interface\\Icons\\Ability_Creature_Cursed_05")
        SetCreaturePortrait(F.bannerPortrait, F.bannerSourceModel, nil)
    else
        F.bannerIcon:SetTexture(SpellIcon(kb.spellID) or "Interface\\Icons\\Ability_Creature_Cursed_05")
        SetCreaturePortrait(F.bannerPortrait, F.bannerSourceModel, kb.sourceGUID)
    end
    F.bannerIcon:Show()
    F.bannerSpellBtn.spellID = kb.spellID              -- drives the spell tooltip on hover

    F.bannerKilledBy:SetText(ColorOf(BDR.UI.DAMAGE) .. L.KILLED_BY .. "|r")
    if kb.isEnv then
        -- Environmental death: no attacker — show just the type label, once.
        F.bannerSource:SetText(ColorOf(BDR.UI.NAME_YELLOW) .. (kb.spellName or L.UNKNOWN) .. "|r")
    else
        -- Only show the "• <spell>" segment for an actual spell (melee blows have no ID).
        local spellName = kb.spellID and SpellNameAt(kb) or kb.spellName
        local spell = spellName and ("  " .. ColorOf(BDR.UI.TEXT_DIM) .. "•|r  "
            .. ColorOf(BDR.UI.TEXT) .. spellName .. "|r") or ""
        F.bannerSource:SetText(ColorOf(BDR.UI.NAME_YELLOW) .. (kb.sourceName or L.UNKNOWN) .. "|r" .. spell)
    end

    -- Headline number = the KILLING BLOW's own damage (the last spell), with its
    -- overkill beneath — not the whole-window total. Signed (minus) like the table.
    F.bannerAmount:SetText(ColorOf(BDR.UI.DAMAGE) .. "-" .. FormatFull(kb.amount or 0) .. "|r")
    if kb.isInstaKill then
        F.bannerOver:SetText(ColorOf(BDR.UI.TEXT) .. L.INSTANT_KILL .. "|r")
    elseif kb.overkill then
        F.bannerOver:SetText(ColorOf(BDR.UI.TEXT) .. L.OVERKILL:format(FormatAmount(kb.overkill)) .. "|r")
    else
        F.bannerOver:SetText("")
    end
end

-- Draw the overview strip: a compressed stepped HP curve across the FULL extent,
-- plus the brush rectangle over the currently-visible [visMin..visMax] window and the
-- dimming on either side. Called from RenderGraph (so it tracks every zoom/pan).
local function RenderOverview(curve, fullMin, fullMax, visMin, visMax)
    local ov = F.overview
    if not ov then return end
    ov:Show()
    PoolReset(F.ovLinePool)
    local ovW, ovH = ov:GetWidth(), ov:GetHeight()
    local fullSpan = fullMax - fullMin
    if fullSpan <= 0 or ovW <= 0 then return end
    local pad = 3
    local function OX(t) return (t - fullMin) / fullSpan * ovW end
    local function OY(pct) return pad + math.max(0, math.min(100, pct)) / 100 * (ovH - 2 * pad) end

    -- Mini stepped HP curve (red), ignoring zoom — this is the "you are here" map.
    local c = BDR.UI.DAMAGE
    for i = 2, #curve do
        local a, b = curve[i - 1], curve[i]
        local segs = { { OX(a.t), OY(a.pct), OX(b.t), OY(a.pct) },    -- flat hold
                       { OX(b.t), OY(a.pct), OX(b.t), OY(b.pct) } }   -- vertical drop
        for _, s in ipairs(segs) do
            local line = PoolNext(F.ovLinePool, ov)
            line:SetThickness(1.5)
            line:SetColorTexture(c[1], c[2], c[3], 0.85)
            line:SetStartPoint("BOTTOMLEFT", ov, s[1], s[2])
            line:SetEndPoint("BOTTOMLEFT", ov, s[3], s[4])
        end
    end

    -- Brush over the visible window.
    local bL = math.max(0, math.min(ovW, OX(visMin)))
    local bR = math.max(0, math.min(ovW, OX(visMax)))
    if bR - bL < 6 then bR = math.min(ovW, bL + 6) end
    F.ovBrush:ClearAllPoints()
    F.ovBrush:SetPoint("TOPLEFT", ov, "TOPLEFT", bL, 0)
    F.ovBrush:SetPoint("BOTTOMLEFT", ov, "BOTTOMLEFT", bL, 0)
    F.ovBrush:SetWidth(bR - bL)
    -- The ◄ ► move-handles only fit when the brush is wide enough.
    local showArrows = (bR - bL) >= 22
    F.ovArrowL:SetShown(showArrows); F.ovArrowR:SetShown(showArrows)

    if bL > 0.5 then
        F.ovDimL:ClearAllPoints()
        F.ovDimL:SetPoint("TOPLEFT", ov, "TOPLEFT", 0, 0)
        F.ovDimL:SetPoint("BOTTOMLEFT", ov, "BOTTOMLEFT", 0, 0)
        F.ovDimL:SetWidth(bL); F.ovDimL:Show()
    else F.ovDimL:Hide() end
    if bR < ovW - 0.5 then
        F.ovDimR:ClearAllPoints()
        F.ovDimR:SetPoint("TOPRIGHT", ov, "TOPRIGHT", 0, 0)
        F.ovDimR:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT", 0, 0)
        F.ovDimR:SetWidth(ovW - bR); F.ovDimR:Show()
    else F.ovDimR:Hide() end
end

function RenderGraph(report)   -- assigns the forward-declared upvalue (see GraphTrack)
    local graph = F.graph
    PoolReset(F.graphLinePool)
    PoolReset(F.dotPool)
    PoolReset(F.tailPool)
    PoolReset(F.xtickPool)
    HideCrosshair(); F.markerGlow:Hide(); F.deathMarker:Hide()
    if F.hoverDot then F.hoverDot:Hide() end
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
        if F.overview then F.overview:Hide() end   -- no curve → no overview strip
        return
    end
    F.graphNote:Hide()

    -- Time model: the curve's `t` is seconds-relative-to-death (<= 0). The X axis
    -- is labelled in seconds-BEFORE-death (death = 0 at X(0)); GRAPH_PAD seconds of
    -- breathing room are added BEFORE the first hit and AFTER death so neither end
    -- is flush to an edge.
    local first    = curve[1].t            -- oldest (most-negative) time
    local duration = -first
    -- Full extent (with the GRAPH_PAD margins) vs the currently-VISIBLE window — a
    -- zoomed sub-range (mouse-wheel over the graph), or the full extent when unzoomed.
    local fullMin  = first - GRAPH_PAD
    local fullMax  = GRAPH_PAD
    local visMin   = F.zoomMin or fullMin
    local visMax   = F.zoomMax or fullMax
    if visMin < fullMin then visMin = fullMin end
    if visMax > fullMax then visMax = fullMax end
    if visMax - visMin < MIN_ZOOM_SPAN then visMax = visMin + MIN_ZOOM_SPAN end   -- tightest zoom
    local xMinT    = visMin
    local span     = visMax - visMin
    if span <= 0 then span = 1 end
    F.graphLabel:SetText(L.HP_HEADER:format(math.max(1, math.floor(duration + 0.5))))

    local function X(t)   return (t - xMinT) / span * gw end
    local function Y(pct)
        pct = math.max(Y_AXIS_MIN, math.min(Y_AXIS_MAX, pct))
        return (pct - Y_AXIS_MIN) / (Y_AXIS_MAX - Y_AXIS_MIN) * gh
    end

    -- X axis: seconds-BEFORE-death labels within the VISIBLE range (finer ticks when
    -- zoomed in); 0 is skipped (the tombstone marks death). Labels are on `f` so the
    -- graph's clip can't hide them.
    local vis = visMax - visMin
    local lstep = (vis > 16) and 4 or (vis > 8) and 2 or (vis > 3) and 1 or (vis > 1.2) and 0.5 or 0.25
    local tk = math.ceil(visMin / lstep - 1e-6) * lstep
    while tk <= visMax + 1e-6 do
        if tk <= -1e-6 then                  -- only before death; 0 belongs to the tombstone
            local fs = PoolNext(F.xtickPool, F)
            fs:ClearAllPoints()
            fs:SetPoint("TOP", graph, "BOTTOMLEFT", X(tk), -2)
            fs:SetText((lstep < 1) and string.format("%.1fs", tk) or string.format("%ds", tk))
            fs:SetTextColor(unpack(BDR.UI.TEXT_DIM))
        end
        tk = tk + lstep
    end

    -- Tombstone marker at the death point — only when death is in view.
    if visMin <= 0 and visMax >= 0 then
        F.deathMarker:ClearAllPoints()
        F.deathMarker:SetPoint("TOP", graph, "BOTTOMLEFT", X(0), -1)
        F.deathMarker:Show()
    else
        F.deathMarker:Hide()
    end

    -- Stepped line, gradient by HP (horizontal hold, then a vertical drop per hit):
    -- HP holds flat between hits and drops straight down on a hit — the true shape
    -- (a diagonal would imply HP bleeding down gradually, which misreads the drop).
    local function Seg(x1, y1, x2, y2, c)
        local line = PoolNext(F.graphLinePool, graph)
        line:SetThickness(2)
        line:SetColorTexture(c[1], c[2], c[3], 1)
        line:SetStartPoint("BOTTOMLEFT", graph, x1, y1)
        line:SetEndPoint("BOTTOMLEFT", graph, x2, y2)
    end
    for i = 2, #curve do
        local a, b = curve[i - 1], curve[i]
        if not ((a.t < visMin and b.t < visMin) or (a.t > visMax and b.t > visMax)) then
            Seg(X(a.t), Y(a.pct), X(b.t), Y(a.pct), HpColor(a.pct))
            Seg(X(b.t), Y(a.pct), X(b.t), Y(b.pct), HpColor(math.min(a.pct, b.pct)))
        end
    end

    -- Post-death dashed fading tail at HP = 0, from the death point to the edge.
    local deathX, zeroY = X(0), Y(0)
    local tx, alpha = deathX + 3, 0.7
    while tx < gw do
        local d = PoolNext(F.tailPool, graph)
        d:SetColorTexture(BDR.UI.HP_LOW[1], BDR.UI.HP_LOW[2], BDR.UI.HP_LOW[3], math.max(0.08, alpha))
        d:ClearAllPoints()
        d:SetPoint("LEFT", graph, "BOTTOMLEFT", tx, zeroY)
        d:SetSize(4, 2)
        tx, alpha = tx + 6, alpha - 0.06
    end

    -- Pre-combat dashed margin before the first hit, at the first sample's HP level
    -- (mirrors the post-death tail, fading out toward the left edge).
    local firstX, firstY = X(first), Y(curve[1].pct)
    local fc = HpColor(curve[1].pct)
    local lx, lalpha = firstX - 3, 0.7
    while lx > 0 do
        local d = PoolNext(F.tailPool, graph)
        d:SetColorTexture(fc[1], fc[2], fc[3], math.max(0.08, lalpha))
        d:ClearAllPoints()
        d:SetPoint("RIGHT", graph, "BOTTOMLEFT", lx, firstY)
        d:SetSize(4, 2)
        lx, lalpha = lx - 6, lalpha - 0.06
    end

    -- Event markers on the line: a school-coloured DOT per hit (heals green), KB bigger.
    for _, ev in ipairs(report.hits or report.events or {}) do
        if ev.t >= visMin - 0.001 and ev.t <= visMax + 0.001 then
            local gx, gy = X(ev.t), Y(ev.hpPct or StepPctAt(curve, ev.t))   -- HP when it landed
            local color = (ev.kind == "heal") and BDR.UI.HEAL or (SchoolInfo(ev.school))
            local r = ev.isKillingBlow and 5 or 4   -- small dot radius (KB emphasised)
            local d = PoolNext(F.dotPool, graph)
            d:SetSize(r * 2, r * 2)
            d:ClearAllPoints()
            d:SetPoint("CENTER", graph, "BOTTOMLEFT", gx, gy)
            d.fill:SetVertexColor(color[1], color[2], color[3], 1)   -- masked texture → tint, not SetColorTexture
            F.markerPos[ev] = { x = gx, y = gy, r = r * 2 }
        end
    end

    F.mapT = { first = first, xMinT = xMinT, span = span, gw = gw, gh = gh, curve = curve,
               fullMin = fullMin, fullMax = fullMax,
               hits = report.hits or report.events or {} }

    -- Overview strip + brush, mirroring this zoom window over the full extent.
    RenderOverview(curve, fullMin, fullMax, visMin, visMax)

    -- Mouse-wheel over the graph zooms the time window in/out, centred on the cursor;
    -- wheeling all the way out restores the full view. (Hooked once.)
    if not F.zoomHooked then
        F.zoomHooked = true
        F.graphOverlay:EnableMouseWheel(true)
        F.graphOverlay:SetScript("OnMouseWheel", function(self, delta)
            local m = F.mapT
            if not (m and F.report) then return end
            local s  = self:GetEffectiveScale()
            local gx = (GetCursorPosition() / s) - F.graph:GetLeft()
            gx = math.max(0, math.min(m.gw, gx))
            local cursorT  = gx / m.gw * m.span + m.xMinT
            local fullSpan = m.fullMax - m.fullMin
            local newSpan  = math.max(MIN_ZOOM_SPAN, math.min(m.span * (delta > 0 and 0.8 or 1.25), fullSpan))
            local frac     = (m.span > 0) and (cursorT - m.xMinT) / m.span or 0.5
            local newMin   = cursorT - frac * newSpan
            local newMax   = newMin + newSpan
            if newMin < m.fullMin then newMin, newMax = m.fullMin, m.fullMin + newSpan end
            if newMax > m.fullMax then newMax, newMin = m.fullMax, m.fullMax - newSpan end
            if newMin < m.fullMin then newMin = m.fullMin end
            if newSpan >= fullSpan - 1e-3 then
                F.zoomMin, F.zoomMax = nil, nil          -- fully out → full view
            else
                F.zoomMin, F.zoomMax = newMin, newMax
            end
            RenderGraph(F.report)
        end)

        -- Click-drag the graph: pan the visible window when zoomed in, or (fully
        -- zoomed out) move the whole window like the title bar.
        F.graphOverlay:EnableMouse(true)
        F.graphOverlay:RegisterForDrag("LeftButton")
        F.graphOverlay:SetScript("OnDragStart", function(self)
            local m = F.mapT
            if m and (F.zoomMin or F.zoomMax) then
                self.panning     = true
                self.panStartX   = GetCursorPosition() / self:GetEffectiveScale()
                self.panSpan     = (F.zoomMax or m.fullMax) - (F.zoomMin or m.fullMin)
                self.panStartMin = F.zoomMin or m.fullMin
                GraphTrackStop()
            elseif not BDR.DB.locked then
                self.movingWindow = true
                F:StartMoving()
                GraphTrackStop()
            end
        end)
        F.graphOverlay:SetScript("OnDragStop", function(self)
            if self.panning then
                self.panning = false
            elseif self.movingWindow then
                self.movingWindow = false
                F:StopMovingOrSizing()
                SavePosition()
            end
        end)
    end
end

-- Blizzard-style hover tooltip for a row's NON-event area: headline damage (with
-- school + overkill), spell by source, remaining HP, and time before death — the
-- "Time / Damage / HP" tooltip Blizzard's own death recap shows on mouseover.
local function ShowRowTip(owner, ev)
    local curve = (F.report and F.report.healthCurve) or {}
    local hp = math.floor((ev.hpPct or PctAtT(curve, ev.t)) + 0.5)
    local isHeal = ev.kind == "heal"
    local dc = isHeal and BDR.UI.HEAL or BDR.UI.DAMAGE

    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local headline = FormatFull(ev.amount)
    local _, schoolName = SchoolInfo(ev.school)
    if schoolName ~= "" then headline = headline .. " " .. schoolName end
    if ev.overkill and ev.overkill > 0 then
        headline = headline .. " " .. L.TIP_OVERKILL:format(FormatFull(ev.overkill))
    end
    GameTooltip:AddLine(headline, dc[1], dc[2], dc[3])
    -- Environmental deaths have no attacker — show just the type, not "X by X".
    if ev.isEnv then
        GameTooltip:AddLine(SpellNameAt(ev), 0.95, 0.95, 0.95)
    else
        GameTooltip:AddLine(L.TIP_BY:format(SpellNameAt(ev), ev.sourceName or L.UNKNOWN), 0.95, 0.95, 0.95)
    end
    local hc = HpColor(hp)
    GameTooltip:AddLine((ev.isKillingBlow and L.TIP_HP_KB or L.TIP_HP_REMAINING):format(hp),
        hc[1], hc[2], hc[3])
    GameTooltip:AddLine(L.TIP_TIME_BEFORE:format(-ev.t), 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

-- Positions the table column header + the scrollable rows; returns the y below.
local function RenderTable(report)
    PoolReset(F.rowPool)
    F.rowOf = {}
    local allHits = report.hits or report.events or {}

    -- Damage-only (heals stay on the graph, not in the table), newest first.
    local ordered = {}
    for i = #allHits, 1, -1 do
        if allHits[i].kind ~= "heal" then ordered[#ordered + 1] = allHits[i] end
    end
    local total = #ordered

    -- Column header — every title LEFT-aligned at its column's left edge (borderless
    -- grid; titles all the way to the left of their cell).
    local hy = F.tableTop
    F.hdrTime:ClearAllPoints();   F.hdrTime:SetPoint("TOPLEFT", PAD + C_TIME_X, hy)
    F.hdrEvent:ClearAllPoints();  F.hdrEvent:SetPoint("TOPLEFT", PAD + C_EVENT_X, hy)
    F.hdrSource:ClearAllPoints(); F.hdrSource:SetPoint("TOPLEFT", PAD + C_SOURCE_X, hy)
    F.hdrDamage:ClearAllPoints(); F.hdrDamage:SetPoint("TOPLEFT", PAD + C_DMG_X, hy)
    F.hdrPct:ClearAllPoints();    F.hdrPct:SetPoint("TOPLEFT", PAD + C_HP_BAR_X - C_HP_NUM_W - 4, hy)

    local stride     = ROW_H + ROW_GAP
    local shown      = math.min(TL_VISIBLE_ROWS, math.max(total, 1))
    -- Reserve room for the scrollbar when the list overflows (same as the Damage
    -- Sources table) so the right-hand columns never hide under it; full width when
    -- everything fits in the 5-row viewport.
    local needScroll = total > shown
    local rowW       = WINDOW_W - 2 * PAD - (needScroll and SCROLLBAR_W or 0)
    local scrollTop  = F.tableTop - TBL_HDR
    local viewportH  = shown * stride

    F.tableScroll:ClearAllPoints()
    F.tableScroll:SetPoint("TOPLEFT", PAD, scrollTop)
    F.tableScroll:SetSize(rowW, viewportH)
    F.tableChild:SetSize(rowW, math.max(viewportH, total * stride))
    F.tableScroll:SetVerticalScroll(0)
    F.tableScroll:Show()
    local bar = _G["BetterDeathRecapTableScrollScrollBar"]
    if bar then if needScroll then bar:Show() else bar:Hide() end end

    local curve = report.healthCurve or {}
    local y = 0
    for _, ev in ipairs(ordered) do
        local row = PoolNext(F.rowPool, F.tableChild)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", F.tableChild, "TOPLEFT", 0, y)
        row:SetWidth(rowW)
        F.rowOf[ev] = row

        -- HP when this hit landed (its own currentHP); KB shows its real pre-hit HP
        -- (e.g. 2%), not 0. Falls back to the curve for the sample (no hpPct).
        local hpLevel = ev.hpPct or PctAtT(curve, ev.t)

        row.time:SetText(ev.t == 0 and "0.000s" or string.format("%.3fs", ev.t))
        -- Event icon: environmental stock icon, else the spell icon (melee = 88163).
        row.icon:SetTexture(ev.iconOverride or SpellIcon(ev.spellID) or SpellIcon(88163)
            or "Interface\\ICONS\\INV_Sword_04")
        row.icon:Show()
        if ev.isKillingBlow then row.deathIcon:Show() else row.deathIcon:Hide() end
        row.text:SetText(SpellNameAt(ev))
        row.text:SetTextColor(unpack(BDR.UI.TEXT))
        -- Source: the attacker name.
        row.source:SetText(ev.sourceName or L.UNKNOWN)
        row.source:SetTextColor(unpack(BDR.UI.TEXT_DIM))

        -- Damage: the raw number, signed (minus) — the table is damage-only.
        row.dmg:SetText("-" .. FormatFull(ev.amount))

        -- Remaining HP: "NN%" + a flat bar of that length, coloured by HP level.
        local hc = HpColor(hpLevel)
        row.pct:SetText(string.format("%d%%", math.floor(hpLevel + 0.5)))
        row.pct:SetTextColor(hc[1], hc[2], hc[3])
        row.pctBar:SetColorTexture(hc[1], hc[2], hc[3], 0.9)
        row.pctBar:SetWidth(math.max(1, C_HP_BAR_W * math.min(100, math.max(0, hpLevel)) / 100))
        row.pctBarBg:Show(); row.pctBar:Show()

        -- Row background: one unified panel colour (same as the graph canvas); the
        -- killing blow gets the strong red wash.
        row.isKB = ev.isKillingBlow
        if ev.isKillingBlow then
            row.bgTex:SetColorTexture(unpack(BDR.UI.ROW_KB_BG))
            row.hl:Show()
            row.dmg:SetTextColor(1, 0.45, 0.45)
        else
            row.bgTex:SetColorTexture(unpack(BDR.UI.PANEL_BG))
            row.hl:Hide()
            row.dmg:SetTextColor(unpack(BDR.UI.DAMAGE))
        end

        -- Hover split: the Event cell (icon+name) → spell tooltip; the rest of the
        -- row → the Time/Damage/HP tooltip (Blizzard-style), via the eventBtn overlay.
        row.ev = ev
        row:SetScript("OnEnter", function(self) HoverEvent(self.ev); ShowRowTip(self, self.ev) end)
        row:SetScript("OnLeave", function(self) UnhoverEvent(self.ev); GameTooltip:Hide() end)
        row.eventBtn.ev = ev
        row.eventBtn:SetScript("OnEnter", function(self)
            HoverEvent(self.ev)
            if self.ev.spellID and GameTooltip.SetSpellByID then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")  -- top-center of the row
                GameTooltip:SetSpellByID(self.ev.spellID)
                GameTooltip:Show()
            else
                ShowRowTip(self, self.ev)
            end
        end)
        row.eventBtn:SetScript("OnLeave", function(self) UnhoverEvent(self.ev); GameTooltip:Hide() end)
        y = y - stride
    end

    -- (No "scroll for more" hint — the scrollbar itself signals overflow.)
    F.scrollHint:Hide()
    local yBottom = scrollTop - viewportH
    return yBottom
end

-- The Damage Sources section is COLLAPSIBLE. Collapsed (default): just the
-- clickable "▶ Total Damage <grand>" line on top. Expanded: the sources meter list,
-- then "▼ Total Damage <grand>" below it (clicking either toggles).
local function RenderSources(report, yTop)
    PoolReset(F.srcRowPool)
    local sources = report.sources or {}
    local grand = 0
    for _, s in ipairs(sources) do grand = grand + (s.total or 0) end

    -- Divider above the section.
    F.divSources:ClearAllPoints()
    F.divSources:SetPoint("TOPLEFT", PAD, yTop)
    F.divSources:SetPoint("TOPRIGHT", -PAD, yTop)
    F.divSources:Show()

    local collapsed = BDR.DB.sourcesCollapsed
    -- No ▶/▼ icon; the grand total is RED (same as the overkill damage).
    local totalText = ColorOf(BDR.UI.TEXT_DIM) .. L.TOTAL_DAMAGE .. "   |r"
        .. ColorOf(BDR.UI.DAMAGE) .. FormatFull(grand) .. "|r"
    F.srcTotalLabel:SetText(totalText)

    local function placeTotal(y)
        F.srcTotalBtn:ClearAllPoints()
        F.srcTotalBtn:SetPoint("TOPLEFT", PAD, y)
        F.srcTotalBtn:SetPoint("TOPRIGHT", -PAD, y)
        F.srcTotalBtn:Show()
        return y - SRC_TOTAL_H
    end

    if collapsed then
        F.srcHeader:Hide(); F.srcScroll:Hide(); F.divTotal:Hide()
        local cbar = _G["BetterDeathRecapSrcScrollScrollBar"]; if cbar then cbar:Hide() end
        return placeTotal(yTop - 6)
    end

    -- Expanded: header + the scrollable meter list.
    F.srcHeader:Show()
    local y = yTop - 8
    F.srcHeader:ClearAllPoints()
    F.srcHeader:SetPoint("TOPLEFT", PAD, y)
    y = y - SRC_HDR

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

        local icon = s.iconOverride or SpellIcon(s.spellID)
        if icon then row.icon:SetTexture(icon); row.icon:Show() else row.icon:Hide() end
        -- Stock 2D portrait over the icon (env sources keep their stock icon, no portrait).
        SetCreaturePortrait(row.portrait2D, row.portrait, (not s.iconOverride) and s.sourceGUID or nil)
        row.name:SetText(s.name or L.UNKNOWN)
        row.name:SetTextColor(unpack(BDR.UI.TEXT))
        row.amount:SetText(FormatFull(s.total))     -- raw damage total (no percentage)
        row.amount:SetTextColor(unpack(BDR.UI.TEXT))

        -- Fat fill across the whole row, width ∝ this source's share of the total.
        local c = (i == 1) and BDR.UI.SOURCE_PRIMARY or BDR.UI.SOURCE_OTHER
        row.barFill:SetColorTexture(c[1], c[2], c[3], 0.9)
        row.barFill:SetWidth(math.max(2, rowW * (s.pct or 0) / 100))
        ry = ry - SRC_ROW_H
    end
    y = y - viewportH

    -- Divider, then the Total Damage toggle below the list.
    y = y - 4
    F.divTotal:ClearAllPoints()
    F.divTotal:SetPoint("TOPLEFT", PAD, y)
    F.divTotal:SetPoint("TOPRIGHT", -PAD, y)
    F.divTotal:Show()
    return placeTotal(y - 6)
end

local function RenderFooter(report, yTop)
    local ctx = report.context or {}
    local parts = {}
    if ctx.difficulty then parts[#parts + 1] = ctx.difficulty end
    if ctx.zone then parts[#parts + 1] = ctx.zone end
    parts[#parts + 1] = L.FOOTER_WINDOW:format(ctx.windowSeconds or BDR.CONFIG.WINDOW_SECONDS)

    -- Divider above the footer; the text is vertically centred in the visible band
    -- below it — between the divider and the window's bottom edge (FOOTER_H + PAD).
    F.divFooter:ClearAllPoints()
    F.divFooter:SetPoint("TOPLEFT", PAD, yTop)
    F.divFooter:SetPoint("TOPRIGHT", -PAD, yTop)
    F.divFooter:Show()
    local midY = yTop - (FOOTER_H + PAD) / 2

    F.footer:ClearAllPoints()
    F.footer:SetPoint("LEFT", F, "TOPLEFT", PAD, midY)
    F.footer:SetText(ColorOf(BDR.UI.TEXT_DIM) .. table.concat(parts, "  •  "):upper() .. "|r")

    F.footerHint:ClearAllPoints()
    F.footerHint:SetPoint("RIGHT", F, "TOPRIGHT", -PAD, midY)
    F.footerHint:SetText(ColorOf(BDR.UI.TEXT_DIM)
        .. (report.isSample and L.FOOTER_SAMPLE or L.FOOTER_HINT):upper() .. "|r")

    return yTop - FOOTER_H
end

-- ── public API ───────────────────────────────────────────────────────────────

local function ResolveLayout()
    local yBanner   = -1 - TITLE_H   -- flush under the header (matches BuildFrame)
    local yGraphHdr = yBanner - BANNER_H - HDR_GAP
    local yCanvas   = yGraphHdr - GRAPH_HDR
    -- graph (GRAPH_H) → x-axis (XAXIS_H) → 8px gap → overview strip (OVERVIEW_H) → 12px
    F.tableTop = yCanvas - GRAPH_H - XAXIS_H - 8 - OVERVIEW_H - 12
end

function Display:Show(report)
    if not report then return end
    EnsureFrame()
    F.report = report
    F.zoomMin, F.zoomMax = nil, nil   -- a (re)shown report starts at the full graph view
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
        F.hdrTime:Hide(); F.hdrEvent:Hide(); F.hdrSource:Hide(); F.hdrDamage:Hide(); F.hdrPct:Hide()
        F.srcHeader:Hide(); F.srcTotalBtn:Hide()
        yBottom = RenderFooter(report, F.tableTop)
    else
        F.emptyText:Hide()
        F.hdrTime:Show(); F.hdrEvent:Show(); F.hdrSource:Show(); F.hdrDamage:Show(); F.hdrPct:Show()
        -- (srcHeader / srcTotalBtn shown by RenderSources per the collapse state)
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
    if not (report and not report.empty) then report = BDR.GetLastReport() end
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
    local report = BDR.GetLastReport()
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
