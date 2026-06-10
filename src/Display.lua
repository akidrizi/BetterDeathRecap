local _, BDR = ...

-- Display — the window. Builds one reusable frame lazily, then re-populates it
-- from a DeathReport on every Show(). All variable-count visuals (curve lines,
-- fill columns, timeline rows, source bars) come from small object pools so we
-- never leak frames across deaths.

local Display = {}
BDR.Display = Display

local WINDOW_W, WINDOW_H = 540, 430
local PAD = 14

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

-- Short, readable damage numbers: 482000 -> "482k", 1_250_000 -> "1.3m".
local function FormatAmount(n)
    n = n or 0
    if n >= 1e6 then return string.format("%.1fm", n / 1e6) end
    if n >= 1e3 then return string.format("%.0fk", n / 1e3) end
    return tostring(math.floor(n + 0.5))
end

local function HpColor(pct)
    local c = BDR.UI
    if pct >= 50 then return c.HP_GOOD end
    if pct >= 25 then return c.HP_MID end
    return c.HP_LOW
end

-- Interpolate the health % at relative time `t` from a sorted curve.
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

local function ApplyLockState()
    local locked = BDR.DB.locked
    F.lockBtn:SetText(locked and "Unlock" or "Lock")
    F:EnableMouse(true)
end

local function MakeFontString(parent, template, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    if justify then fs:SetJustifyH(justify) end
    return fs
end

local function BuildFrame()
    local f = CreateFrame("Frame", "BetterDeathRecapFrame", UIParent, "BackdropTemplate")
    f:SetSize(WINDOW_W, WINDOW_H)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:Hide()

    -- Background + gold border.
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(BDR.UI.BG))
    f:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropBorderColor(unpack(BDR.UI.BORDER_GOLD))

    -- Restore saved position (default: centred, slightly high).
    local p = BDR.DB.point
    f:SetPoint(p[1], UIParent, p[3], p[4], p[5])

    -- Drag to move (respects lock state).
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if not BDR.DB.locked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    -- Close on Escape.
    table.insert(UISpecialFrames, "BetterDeathRecapFrame")

    -- ── Title bar ────────────────────────────────────────────────────────────
    local title = MakeFontString(f, "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", PAD, -PAD)
    title:SetText("|cffff5555Better|rDeathRecap")
    f.title = title

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    local lockBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    lockBtn:SetSize(64, 20)
    lockBtn:SetPoint("RIGHT", close, "LEFT", -2, 0)
    lockBtn:SetScript("OnClick", function()
        BDR.DB.locked = not BDR.DB.locked
        ApplyLockState()
    end)
    f.lockBtn = lockBtn

    local histBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    histBtn:SetSize(64, 20)
    histBtn:SetPoint("RIGHT", lockBtn, "LEFT", -4, 0)
    histBtn:SetText("History")
    histBtn:SetScript("OnClick", function() Display:ShowLast() end)

    -- ── Killing-blow banner ────────────────────────────────────────────────────
    local banner = CreateFrame("Frame", nil, f)
    banner:SetPoint("TOPLEFT", PAD, -PAD - 28)
    banner:SetPoint("TOPRIGHT", -PAD, -PAD - 28)
    banner:SetHeight(30)
    local bb = banner:CreateTexture(nil, "ARTWORK")
    bb:SetAllPoints()
    bb:SetColorTexture(BDR.UI.KILL_RED[1], BDR.UI.KILL_RED[2], BDR.UI.KILL_RED[3], 0.18)
    local bannerText = MakeFontString(banner, "GameFontNormalLarge", "LEFT")
    bannerText:SetPoint("LEFT", 8, 0)
    bannerText:SetPoint("RIGHT", -8, 0)
    f.bannerText = bannerText

    -- ── Body: left graph + right timeline ──────────────────────────────────────
    local bodyTop = -PAD - 28 - 38
    local graphW = 230

    local graphLabel = MakeFontString(f, "GameFontHighlightSmall", "LEFT")
    graphLabel:SetPoint("TOPLEFT", PAD, bodyTop)
    f.graphLabel = graphLabel

    local graph = CreateFrame("Frame", nil, f)
    graph:SetPoint("TOPLEFT", PAD, bodyTop - 16)
    graph:SetSize(graphW, 150)
    f.graph = graph
    f.graphLinePool = NewPool(function(parent)
        return parent:CreateLine(nil, "OVERLAY")
    end)
    f.graphFillPool = NewPool(function(parent)
        local t = parent:CreateTexture(nil, "ARTWORK")
        t:SetColorTexture(unpack(BDR.UI.FILL))
        return t
    end)
    f.graphGridPool = NewPool(function(parent)
        local t = parent:CreateTexture(nil, "BACKGROUND")
        t:SetColorTexture(unpack(BDR.UI.GRID))
        return t
    end)
    f.graphDot = graph:CreateTexture(nil, "OVERLAY")
    f.graphDot:SetColorTexture(unpack(BDR.UI.HP_LOW))
    f.graphDot:SetSize(6, 6)
    f.graphDot:Hide()
    f.graphAxis = MakeFontString(graph, "GameFontDisableSmall", "LEFT")
    f.graphAxis:SetPoint("TOPLEFT", graph, "BOTTOMLEFT", 0, -2)
    f.graphAxisR = MakeFontString(graph, "GameFontDisableSmall", "RIGHT")
    f.graphAxisR:SetPoint("TOPRIGHT", graph, "BOTTOMRIGHT", 0, -2)

    -- Right column: timeline header + rows.
    local tlLeft = PAD + graphW + 16
    local tlHeader = MakeFontString(f, "GameFontHighlightSmall", "LEFT")
    tlHeader:SetPoint("TOPLEFT", tlLeft, bodyTop)
    tlHeader:SetText("Hit timeline")
    f.timelineLeft = tlLeft
    f.timelineTop  = bodyTop - 18
    f.rowPool = NewPool(function(parent)
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(18)
        row.bgTex = row:CreateTexture(nil, "BACKGROUND")
        row.bgTex:SetAllPoints()
        row.time = MakeFontString(row, "GameFontHighlightSmall", "LEFT")
        row.time:SetPoint("LEFT", 0, 0)
        row.time:SetWidth(34)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(14, 14)
        row.icon:SetPoint("LEFT", row.time, "RIGHT", 2, 0)
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        row.text = MakeFontString(row, "GameFontHighlightSmall", "LEFT")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.dmg = MakeFontString(row, "GameFontHighlightSmall", "RIGHT")
        row.dmg:SetPoint("RIGHT", 0, 0)
        row.text:SetPoint("RIGHT", row.dmg, "LEFT", -4, 0)
        return row
    end)

    -- ── Damage sources ─────────────────────────────────────────────────────────
    local srcHeader = MakeFontString(f, "GameFontHighlightSmall", "LEFT")
    srcHeader:SetPoint("TOPLEFT", PAD, bodyTop - 150 - 26)
    srcHeader:SetText("Damage sources")
    f.srcTop = bodyTop - 150 - 44
    f.barPool = NewPool(function(parent)
        local bar = CreateFrame("Frame", nil, parent)
        bar:SetHeight(16)
        bar.track = bar:CreateTexture(nil, "BACKGROUND")
        bar.track:SetAllPoints()
        bar.track:SetColorTexture(1, 1, 1, 0.05)
        bar.fill = bar:CreateTexture(nil, "ARTWORK")
        bar.fill:SetPoint("TOPLEFT")
        bar.fill:SetPoint("BOTTOMLEFT")
        bar.name = MakeFontString(bar, "GameFontHighlightSmall", "LEFT")
        bar.name:SetPoint("LEFT", 4, 0)
        bar.val = MakeFontString(bar, "GameFontHighlightSmall", "RIGHT")
        bar.val:SetPoint("RIGHT", -4, 0)
        return bar
    end)

    -- ── Footer ───────────────────────────────────────────────────────────────
    local footer = MakeFontString(f, "GameFontDisableSmall", "LEFT")
    footer:SetPoint("BOTTOMLEFT", PAD, PAD)
    footer:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    f.footer = footer

    local emptyText = MakeFontString(f, "GameFontHighlight", "CENTER")
    emptyText:SetPoint("CENTER", 0, 0)
    emptyText:SetText("No recap data for this death.")
    emptyText:Hide()
    f.emptyText = emptyText

    ApplyLockState()
    return f
end

local function EnsureFrame()
    if not F then F = BuildFrame() end
    return F
end

-- ── rendering ────────────────────────────────────────────────────────────────

local function RenderBanner(report)
    local kb = report.killingBlow
    if not kb then
        F.bannerText:SetText("|cffff5555Killed.|r  Source unknown.")
        return
    end
    local source = kb.sourceName or "Unknown"
    local spell  = kb.spellName and (" · " .. kb.spellName) or ""
    local over   = kb.overkill and (" |cffff8888(" .. FormatAmount(kb.overkill) .. " overkill)|r") or ""
    F.bannerText:SetText(string.format("|cffff5555%s|r%s · |cffffffff%s|r%s",
        source, spell, FormatAmount(kb.amount), over))
end

local function RenderGraph(report)
    local graph = F.graph
    PoolReset(F.graphLinePool)
    PoolReset(F.graphFillPool)
    PoolReset(F.graphGridPool)
    F.graphDot:Hide()

    local gw, gh = graph:GetWidth(), graph:GetHeight()
    local window = (report.context and report.context.windowSeconds) or BDR.CONFIG.WINDOW_SECONDS
    F.graphLabel:SetText(string.format("HP · last %ds", window))
    F.graphAxis:SetText("-" .. window .. "s")
    F.graphAxisR:SetText("death")

    -- Gridlines at 25/50/75%.
    for _, pct in ipairs({ 25, 50, 75 }) do
        local g = PoolNext(F.graphGridPool, graph)
        g:ClearAllPoints()
        g:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", 0, gh * pct / 100)
        g:SetSize(gw, 1)
    end

    local curve = report.healthCurve or {}
    if #curve < 2 then return end

    -- Map relative time [-window, 0] -> x [0, gw]; pct [0, 100] -> y [0, gh].
    local function X(t) return (t + window) / window * gw end
    local function Y(pct) return math.max(0, math.min(100, pct)) / 100 * gh end

    -- Filled area: interpolated vertical columns under the curve.
    local step = 3
    for px = 0, gw, step do
        local t = (px / gw) * window - window
        local pct = PctAtT(curve, t)
        local h = Y(pct)
        if h > 0 then
            local col = PoolNext(F.graphFillPool, graph)
            col:ClearAllPoints()
            col:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", px, 0)
            col:SetSize(step, h)
        end
    end

    -- The curve itself: one coloured line per segment.
    for i = 2, #curve do
        local a, b = curve[i - 1], curve[i]
        local line = PoolNext(F.graphLinePool, graph)
        line:SetThickness(2)
        local c = HpColor(math.min(a.pct, b.pct))
        line:SetColorTexture(c[1], c[2], c[3], 1)
        line:SetStartPoint("BOTTOMLEFT", graph, X(a.t), Y(a.pct))
        line:SetEndPoint("BOTTOMLEFT", graph, X(b.t), Y(b.pct))
    end

    -- Death dot at the final point.
    local last = curve[#curve]
    F.graphDot:ClearAllPoints()
    F.graphDot:SetPoint("CENTER", graph, "BOTTOMLEFT", X(last.t), Y(last.pct))
    F.graphDot:Show()
end

local function RenderTimeline(report)
    PoolReset(F.rowPool)
    local y = F.timelineTop
    local rowW = WINDOW_W - F.timelineLeft - PAD
    for _, ev in ipairs(report.events or {}) do
        local row = PoolNext(F.rowPool, F)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", F.timelineLeft, y)
        row:SetWidth(rowW)

        row.time:SetText(ev.t == 0 and "0s" or string.format("%.1fs", ev.t))

        local icon = SpellIcon(ev.spellID)
        if icon then row.icon:SetTexture(icon); row.icon:Show() else row.icon:Hide() end

        local label = ev.spellName or "Melee"
        if ev.sourceName then label = ev.sourceName .. " · " .. label end
        row.text:SetText(label)
        row.dmg:SetText(FormatAmount(ev.amount))

        if ev.isKillingBlow then
            row.bgTex:SetColorTexture(BDR.UI.KILL_RED[1], BDR.UI.KILL_RED[2], BDR.UI.KILL_RED[3], 0.30)
            row.text:SetText("|cffff5555KILLING BLOW|r · " .. label)
            row.dmg:SetTextColor(1, 0.4, 0.4)
        else
            row.bgTex:SetColorTexture(0, 0, 0, 0)
            row.dmg:SetTextColor(0.85, 0.85, 0.85)
        end
        y = y - 18

        -- Absorb annotation as a small secondary line.
        if ev.absorbed then
            local sub = PoolNext(F.rowPool, F)
            sub:ClearAllPoints()
            sub:SetPoint("TOPLEFT", F.timelineLeft, y)
            sub:SetWidth(rowW)
            sub.bgTex:SetColorTexture(0, 0, 0, 0)
            sub.time:SetText("")
            sub.icon:Hide()
            sub.text:SetText("|cff88ccff   absorbed " .. FormatAmount(ev.absorbed) .. "|r")
            sub.dmg:SetText("")
            y = y - 14
        end
    end
end

local function RenderSources(report)
    PoolReset(F.barPool)
    local y = F.srcTop
    local barW = WINDOW_W - 2 * PAD
    for i, s in ipairs(report.sources or {}) do
        local bar = PoolNext(F.barPool, F)
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", PAD, y)
        bar:SetWidth(barW)

        local c = (i == 1) and BDR.UI.SOURCE_PRIMARY or BDR.UI.SOURCE_OTHER
        bar.fill:SetColorTexture(c[1], c[2], c[3], 0.85)
        bar.fill:SetWidth(math.max(1, barW * (s.pct or 0) / 100))
        bar.name:SetText(s.name or "Unknown")
        bar.val:SetText(string.format("%.0f%% · %s", s.pct or 0, FormatAmount(s.total)))
        y = y - 19
    end
end

local function RenderFooter(report)
    local ctx = report.context or {}
    local parts = {}
    if ctx.difficulty then parts[#parts + 1] = ctx.difficulty end
    if ctx.zone then parts[#parts + 1] = ctx.zone end
    parts[#parts + 1] = (ctx.windowSeconds or BDR.CONFIG.WINDOW_SECONDS) .. "s window"
    local tag = report.isSample and "  |cff888888(sample — /bdr)|r" or "  |cff888888(/bdr to toggle)|r"
    F.footer:SetText("|cff999999" .. table.concat(parts, "  ·  ") .. "|r" .. tag)
end

-- ── public API ───────────────────────────────────────────────────────────────

function Display:Show(report)
    if not report then return end
    EnsureFrame()

    if report.empty then
        -- Minimal state: hide the detailed sections, show the curve + a notice.
        F.emptyText:Show()
        RenderBanner(report)
        RenderGraph(report)
        PoolReset(F.rowPool); PoolReset(F.barPool)
        RenderFooter(report)
    else
        F.emptyText:Hide()
        RenderBanner(report)
        RenderGraph(report)
        RenderTimeline(report)
        RenderSources(report)
        RenderFooter(report)
    end

    F:Show()
end

function Display:Toggle()
    EnsureFrame()
    if F:IsShown() then
        F:Hide()
    else
        local report = BDR.DB.lastReport or BDR.Analyzer:SampleReport()
        self:Show(report)
    end
end

function Display:ShowLast()
    local report = BDR.DB.lastReport
    if not report then
        BDR.Print(BDR.COLOR.WARN .. "No saved death yet. Try /bdr test for a demo." .. BDR.COLOR.RESET)
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
