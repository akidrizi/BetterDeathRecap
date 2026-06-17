local _, BDR = ...

-- Analyzer — turn Blizzard's C_DeathRecap data (+ our health snapshot) into a
-- structured DeathReport that Display can render without touching the raw API.
-- Everything here is defensive: every C_DeathRecap field is treated as possibly
-- nil/absent (availability varies by patch — see docs/API-NOTES.md), and a
-- missing source becomes an environmental / "Unknown" label rather than an error.

local Analyzer = {}
BDR.Analyzer = Analyzer

-- ── Helpers ─────────────────────────────────────────────────────────────────

-- Resolve an ENVIRONMENTAL_DAMAGE event to (localized label, icon). The kind comes
-- either as a CLEU string token (e.g. "Falling") or via a sentinel spellID mapped
-- in BDR.ENVIRONMENT. Blizzard has no spell for these, so we supply a stock icon
-- (BDR.ENV_ICONS) per type — UNKNOWN is the catch-all.
local function ResolveEnvironment(ev)
    local token = ev.environmentalType or ev.environmentType
    local key   -- normalized UPPER token, e.g. "FALLING"
    if type(token) == "string" and token ~= "" then
        key = token:upper()
    else
        local sentinel = ev.spellId or ev.spellID
        local locKey = sentinel and BDR.ENVIRONMENT[sentinel]   -- "ENV_FALLING"
        if locKey then key = locKey:gsub("^ENV_", "") end
    end
    local label = (key and BDR.L["ENV_" .. key]) or BDR.L.ENV_UNKNOWN
    local icon  = (key and BDR.ENV_ICONS[key]) or BDR.ENV_ICONS.UNKNOWN
    return label, icon
end

-- Resolve a spell's display name from its ID (recap events carry only the ID).
local function SpellName(spellID)
    if not spellID then return nil end
    if C_Spell and C_Spell.GetSpellName then
        return C_Spell.GetSpellName(spellID)
    end
    if GetSpellInfo then
        return (GetSpellInfo(spellID))
    end
    return nil
end

-- Call a possibly-missing API safely: returns the result, or nil on error/absence.
local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, r1, r2, r3 = pcall(fn, ...)
    if ok then return r1, r2, r3 end
    return nil
end

-- Is there a recap at this id? Prefer HasRecapEvents; else infer from GetRecapEvents.
local function HasRecap(id)
    if C_DeathRecap.HasRecapEvents then
        return SafeCall(C_DeathRecap.HasRecapEvents, id) and true or false
    end
    local e = SafeCall(C_DeathRecap.GetRecapEvents, id)
    return type(e) == "table" and #e > 0
end

-- Pick the recap for the MOST RECENT death. Recap ids INCREMENT per death and
-- the kept set slides upward, so the newest death is the HIGHEST valid id. (A
-- previous version capped the scan at 10 and went permanently stale once the
-- death count passed 10 — the classic "same recap forever" bug.) We scan upward,
-- tracking the highest valid id, and stop a few ids after the valid block ends.
local function MostRecentRecapID()
    if not (C_DeathRecap and C_DeathRecap.GetRecapEvents) then return 1 end
    local best, lastValid, misses = nil, nil, 0
    for id = 1, 500 do
        if HasRecap(id) then
            best, lastValid, misses = id, id, 0
        elseif lastValid then
            misses = misses + 1
            if misses >= 8 then break end  -- walked past the end of the valid block
        end
    end
    return best or 1
end

-- Normalise one raw recap event into our internal shape, or nil to skip it.
-- The recap interleaves DAMAGE and HEAL events (the `event`/CLEU subevent tells
-- which). We keep BOTH — heals are needed to plot the health curve correctly
-- (health rising) — and tag each with `kind` so Build can use only damage events
-- for the timeline / sources / killing blow. `currentHP` is the player's health
-- at that event; `amount` is the magnitude (damage or heal size).
local function NormalizeEvent(ev)
    if type(ev) ~= "table" then return nil end

    local subEvent = type(ev.event) == "string" and ev.event or ""
    local isHeal     = subEvent:find("HEAL") ~= nil
    local isMelee    = subEvent:find("^SWING") ~= nil
    local isEnv      = subEvent:find("^ENVIRONMENTAL") ~= nil
    local isPeriodic = subEvent:find("PERIODIC") ~= nil   -- a DoT / HoT tick
    -- Instant-death effects (e.g. SPELL_INSTAKILL — Atomize and similar one-shots)
    -- carry NO amount, but they ARE the killing blow. Treat them as damage so the
    -- addon recognises the death instead of dropping the event.
    local isInstaKill = subEvent:find("INSTAKILL") ~= nil
    local isDamage = (not isHeal) and (isMelee or isInstaKill or subEvent:find("DAMAGE") ~= nil)

    local raw = ev.amount
    local amt = (type(raw) == "number") and (raw < 0 and -raw or raw) or 0
    local currentHP = ev.currentHP or ev.currentHealth
    -- An insta-kill removed all your HP; use the HP it took (currentHP) as the
    -- "damage", or a placeholder (refined to max HP in Build) when not given.
    if isInstaKill and amt <= 0 then
        amt = (type(currentHP) == "number" and currentHP > 0) and currentHP or 1
    end
    -- Need either a usable amount or a health reading (skips MISSED/etc.).
    if amt <= 0 and type(currentHP) ~= "number" then return nil end

    local spellID  = ev.spellId or ev.spellID
    local spellName, iconOverride
    local source
    if isMelee then
        spellID   = 88163             -- the "Melee" auto-attack spell (proper icon + tooltip)
        spellName = BDR.L.MELEE
        source    = ev.sourceName
        if not source or source == "" or ev.hideCaster then source = BDR.L.ENV_UNKNOWN end
    elseif isEnv then
        -- No real spell — the environmental TYPE is the event, with a stock icon.
        spellName, iconOverride = ResolveEnvironment(ev)
        spellID = nil
        source  = spellName           -- the env label doubles as the "source"
    else
        spellName = ev.spellName or SpellName(spellID)
        source    = ev.sourceName
        if not source or source == "" or ev.hideCaster then source = BDR.L.ENV_UNKNOWN end
    end

    -- The recap uses -1 as a "none" sentinel for overkill/absorbed.
    local overkill = (type(ev.overkill) == "number" and ev.overkill > 0) and ev.overkill or nil
    local absorbed = (type(ev.absorbed) == "number" and ev.absorbed > 0) and ev.absorbed or nil

    return {
        kind       = isHeal and "heal" or (isDamage and "damage" or "other"),
        periodic   = isPeriodic,
        timestamp  = ev.timestamp or 0,
        spellID    = spellID,
        spellName  = spellName,
        amount     = amt,
        absorbed   = absorbed,
        overkill   = overkill,
        school     = ev.school or ev.schoolMask or ev.damageSchool,  -- SCHOOL_MASK_* (dot colour)
        currentHP  = (type(currentHP) == "number") and currentHP or nil,
        isMelee    = isMelee,
        isEnv      = isEnv,
        isInstaKill = isInstaKill,
        iconOverride = iconOverride,  -- environmental stock icon (no spell icon exists)
        sourceName = source,
        sourceGUID = ev.sourceGUID,   -- best-effort killer portrait (Display extracts the creatureID)
    }
end

-- Pull the most recent death recap: a normalised event list + the recap's max
-- health (used to scale the reconstructed HP curve). Returns events, maxHP, id.
local function GatherRecap()
    local out = {}
    if not C_DeathRecap then return out, nil, nil end

    local id = MostRecentRecapID()
    -- GetRecapEvents may take the id (or be arg-less on some builds) — try both.
    local events = SafeCall(C_DeathRecap.GetRecapEvents, id)
    if type(events) ~= "table" then events = SafeCall(C_DeathRecap.GetRecapEvents) end
    local maxHP = SafeCall(C_DeathRecap.GetRecapMaxHealth, id)

    if type(events) == "table" then
        -- The recap array is newest-first; remember each event's position so we can
        -- keep Blizzard's exact order when timestamps tie (same-tick melee + spell).
        for i, ev in ipairs(events) do
            local norm = NormalizeEvent(ev)
            if norm then norm.recapIndex = i; out[#out + 1] = norm end
        end
    end
    return out, maxHP, id
end

-- ── Diagnostics: dump EVERY raw event of the chosen recap (for /bdr dump) ─────
-- One line per event with the fields that matter, and the time relative to death
-- (so we can sanity-check the timeline against the combat log). Returns strings.
function Analyzer:DumpEvents()
    local lines = {}
    if not (C_DeathRecap and C_DeathRecap.GetRecapEvents) then
        lines[1] = "GetRecapEvents not available."
        return lines
    end
    local id = MostRecentRecapID()

    -- Show which recap ids exist + which we picked (confirms we track new deaths).
    local valid = {}
    for i = 1, 60 do
        if HasRecap(i) then valid[#valid + 1] = i end
    end
    lines[#lines + 1] = "valid recap ids: " ..
        (next(valid) and table.concat(valid, ",") or "none") .. "  → using id=" .. tostring(id)

    local raw = SafeCall(C_DeathRecap.GetRecapEvents, id)
    if type(raw) ~= "table" then raw = SafeCall(C_DeathRecap.GetRecapEvents) end
    if type(raw) ~= "table" then
        lines[#lines + 1] = "GetRecapEvents returned no table."
        return lines
    end

    local deathT = 0
    for _, ev in ipairs(raw) do
        if type(ev.timestamp) == "number" and ev.timestamp > deathT then deathT = ev.timestamp end
    end

    lines[#lines + 1] = ("recap id=%s  maxHP=%s  events=%d  (ALL shown — full recap, like Blizzard)"):format(
        tostring(id), tostring(SafeCall(C_DeathRecap.GetRecapMaxHealth, id)), #raw)
    for i, ev in ipairs(raw) do
        local ok, line = pcall(function()
            local rel = (type(ev.timestamp) == "number" and deathT > 0) and (ev.timestamp - deathT) or 0
            return string.format("#%d t=%.1fs amt=%s ok=%s hp=%s | %s | %s",
                i, rel, tostring(ev.amount), tostring(ev.overkill), tostring(ev.currentHP),
                tostring(ev.event), tostring(ev.sourceName))
        end)
        lines[#lines + 1] = ok and line or ("#" .. i .. " <event unreadable>")
    end
    return lines
end

-- ── Diagnostics: report what the live recap API exposes (for /bdr debug) ──────
-- Enumerates the actual members of C_DeathRecap (function names vary by patch and
-- the originally-assumed ones were wrong), plus a few related globals, so we can
-- discover the real API names from in-game output.
function Analyzer:Probe()
    local events, maxHP, id = GatherRecap()
    local info = {
        hasNamespace = C_DeathRecap ~= nil,
        hasGet       = C_DeathRecap and C_DeathRecap.GetRecapEvents ~= nil,
        hasHas       = C_DeathRecap and C_DeathRecap.HasRecapEvents ~= nil,
        hasMaxHP     = C_DeathRecap and C_DeathRecap.GetRecapMaxHealth ~= nil,
        recapID      = id,
        maxHP        = maxHP,
        eventCount   = #events,
        members      = {},
        globals      = {},
        firstEvent   = {},
    }

    -- List C_DeathRecap's real members (guarded — some C_ namespaces resist pairs).
    if C_DeathRecap then
        pcall(function()
            for k in pairs(C_DeathRecap) do
                if type(k) == "string" then info.members[#info.members + 1] = k end
            end
        end)
        table.sort(info.members)
    end

    -- Dump the first RAW event's fields, so we can confirm the exact field names.
    pcall(function()
        local raw = SafeCall(C_DeathRecap.GetRecapEvents, id)
        if type(raw) ~= "table" then raw = SafeCall(C_DeathRecap.GetRecapEvents) end
        if type(raw) == "table" and type(raw[1]) == "table" then
            for k, v in pairs(raw[1]) do
                info.firstEvent[#info.firstEvent + 1] = tostring(k) .. "=" .. tostring(v)
            end
            table.sort(info.firstEvent)
        end
    end)

    -- Related globals worth knowing about.
    for _, name in ipairs({ "OpenDeathRecapUI", "DeathRecapFrame", "C_PlayerInfo" }) do
        if _G[name] ~= nil then info.globals[#info.globals + 1] = name end
    end
    return info
end

-- Aggregate per-source damage totals into sorted bars (desc), with percentages.
-- Also records the spellID of each source's single biggest hit, so the sources
-- panel can show a representative icon next to the attacker.
local function BuildSources(events)
    local totals, order = {}, {}
    local topHit, topSpell, topIcon, guid = {}, {}, {}, {}  -- per-source biggest hit + icon + a GUID
    local grand = 0
    for _, ev in ipairs(events) do
        local amt = ev.amount or 0
        if amt > 0 then
            local name = ev.sourceName
            if not totals[name] then
                totals[name] = 0
                order[#order + 1] = name
                topHit[name] = 0
            end
            totals[name] = totals[name] + amt
            grand = grand + amt
            if ev.sourceGUID then guid[name] = ev.sourceGUID end  -- for the source portrait
            if amt > topHit[name] then
                topHit[name]   = amt
                topSpell[name] = ev.spellID
                topIcon[name]  = ev.iconOverride   -- environmental stock icon, if any
            end
        end
    end

    local sources = {}
    for _, name in ipairs(order) do
        sources[#sources + 1] = {
            name    = name,
            total   = totals[name],
            pct     = grand > 0 and (totals[name] / grand * 100) or 0,
            spellID = topSpell[name],
            iconOverride = topIcon[name],
            sourceGUID = guid[name],
        }
    end
    table.sort(sources, function(a, b) return a.total > b.total end)
    return sources
end

-- Build an HP-over-time curve from the recap (never UnitHealth, which is secret
-- on Midnight). Preferred path: `curveEvents` carry per-event `currentHP` (the
-- player's actual health when each hit landed), plotted directly. Both paths
-- normalise to `realMax` — the player's REAL max health (GetRecapMaxHealth on the
-- newest recap id, or UnitHealthMax) — so a fight that OPENED below full health
-- reads e.g. 60% at the start instead of a false 100%. Only when no real max is
-- known do we fall back to the peak observed health (the OLD behaviour, which
-- forced the first point to 100% — the bug this replaces). Fallback when no
-- currentHP exists: reconstruct backward from death over the damage events
-- (health-before = health-after + that hit's effective damage; the killing blow
-- removes only `amount − overkill`). Both append the death point (t=0, 0%).
local function BuildRecapCurve(curveEvents, dmgEvents, realMax, kb)
    local curve = {}

    -- Denominator: the real max health when known, else the peak observed health.
    local function denomFor(peak)
        if realMax and realMax > 0 then return realMax end
        if peak > 0 then return peak end
        return 1
    end

    if #curveEvents > 0 then
        local peak = 0
        for _, ev in ipairs(curveEvents) do
            if ev.currentHP > peak then peak = ev.currentHP end
        end
        local denom = denomFor(peak)
        for _, ev in ipairs(curveEvents) do
            local pct = ev.currentHP / denom * 100
            curve[#curve + 1] = { t = ev.t, pct = math.max(0, math.min(100, pct)) }
        end
        curve[#curve + 1] = { t = 0, pct = 0 }
        return curve
    end

    if #dmgEvents == 0 then return curve end
    local health, afterHP = {}, 0
    for i = #dmgEvents, 1, -1 do
        local ev = dmgEvents[i]
        local eff = ev.amount or 0
        if ev == kb and ev.overkill and ev.overkill > 0 then eff = eff - ev.overkill end
        if eff < 0 then eff = 0 end
        health[i] = afterHP + eff
        afterHP = health[i]
    end
    local peak = 0
    for i = 1, #dmgEvents do if health[i] > peak then peak = health[i] end end
    local denom = denomFor(peak)
    for i = 1, #dmgEvents do
        curve[#curve + 1] = { t = dmgEvents[i].t, pct = math.max(0, math.min(100, health[i] / denom * 100)) }
    end
    curve[#curve + 1] = { t = 0, pct = 0 }
    return curve
end

-- Best-effort context line: difficulty, zone, window length.
local function BuildContext(windowSeconds)
    local zone = (GetRealZoneText and GetRealZoneText()) or BDR.L.UNKNOWN
    local difficulty
    if GetInstanceInfo then
        local _, _, _, diffName = GetInstanceInfo()
        if diffName and diffName ~= "" then difficulty = diffName end
    end
    return {
        difficulty    = difficulty,
        zone          = zone,
        windowSeconds = windowSeconds or BDR.CONFIG.WINDOW_SECONDS,
    }
end

-- ── Public: build a report from live data ───────────────────────────────────
-- Returns a DeathReport (see CLAUDE.md). The HP curve is reconstructed from the
-- recap (BuildRecapCurve), not from UnitHealth samples (which are "secret" on
-- Midnight), so callers no longer need to pass a health snapshot.
function Analyzer:Build()
    local allEvents, maxHP = GatherRecap()

    -- Split the recap: DAMAGE events drive the timeline / sources / killing blow;
    -- ALL events with a health reading (incl. heals) drive the HP curve.
    local dmg = {}
    for _, ev in ipairs(allEvents) do
        if ev.kind == "damage" and ev.amount > 0 then dmg[#dmg + 1] = ev end
    end

    if #dmg == 0 then
        return {
            killedAt    = GetTime(),
            killingBlow = nil,
            events      = {},
            sources     = {},
            healthCurve = {},
            context     = BuildContext(),
            empty       = true,
        }
    end

    -- Chronological by real timestamp (epoch seconds). STABLE on ties: same-tick
    -- events keep the recap's order (higher recapIndex = older), so when reversed
    -- for the newest-first table they read exactly like Blizzard's recap.
    local function byTime(a, b)
        local ta, tb = a.timestamp or 0, b.timestamp or 0
        if ta ~= tb then return ta < tb end
        return (a.recapIndex or 0) > (b.recapIndex or 0)
    end
    table.sort(allEvents, byTime)
    table.sort(dmg, byTime)

    local kb = dmg[#dmg]  -- latest damage event = killing blow
    local deathTime = (kb.timestamp and kb.timestamp ~= 0) and kb.timestamp or GetTime()

    -- Relative-to-death times (<= 0) on the shared event tables. If the recap
    -- gives no usable timestamps, space the damage hits evenly instead.
    local span = (allEvents[#allEvents].timestamp or 0) - (allEvents[1].timestamp or 0)
    if span > 0.05 then
        for _, ev in ipairs(allEvents) do ev.t = ev.timestamp - deathTime end
    else
        local n = #dmg
        local step = BDR.CONFIG.WINDOW_SECONDS / math.max(1, n - 1)
        for i, ev in ipairs(dmg) do ev.t = -((n - i) * step) end
        for _, ev in ipairs(allEvents) do ev.t = ev.t or 0 end
    end

    -- NO fight-gap trimming. C_DeathRecap.GetRecapEvents already returns exactly the
    -- events Blizzard's own death recap shows for THIS death, so we render ALL of them
    -- to match it. (An earlier gap-based trim dropped the oldest hits and shrank the
    -- window — e.g. showed 9s when Blizzard showed 17s. That was data loss.) `dmg` is
    -- already the complete, time-sorted damage subset built above.

    -- Curve events: those carrying a health reading, in time order.
    local curveEvents = {}
    for _, ev in ipairs(allEvents) do
        if type(ev.currentHP) == "number" then curveEvents[#curveEvents + 1] = ev end
    end

    -- Window fits the actual fight (small floor so a 1–2 hit death isn't a
    -- zero-width graph). No artificial minimum — a 4s fight shows a ~4s axis.
    local oldestT = dmg[1].t or 0
    if #curveEvents > 0 and (curveEvents[1].t or 0) < oldestT then oldestT = curveEvents[1].t end
    local window = math.max(3, math.ceil(-oldestT))

    -- Full event list (every damage AND heal in the fight, chronological) — the
    -- table lists the damage ones and the graph marks them all. `kind` drives the
    -- graph dot colour (damage = school colour, heal = green).
    local hits = {}
    for _, ev in ipairs(allEvents) do
        if (ev.kind == "damage" or ev.kind == "heal") and (ev.amount or 0) > 0 then
            hits[#hits + 1] = {
                t            = ev.t,
                kind         = ev.kind,
                periodic     = ev.periodic,    -- DoT / HoT tick
                sourceName   = ev.sourceName,
                spellName    = ev.spellName,
                spellID      = ev.spellID,
                school       = ev.school,       -- SCHOOL_MASK_* (graph dot colour)
                amount       = ev.amount,
                absorbed     = (ev.absorbed and ev.absorbed > 0) and ev.absorbed or nil,
                overkill     = (ev.overkill and ev.overkill > 0) and ev.overkill or nil,
                currentHP    = ev.currentHP,   -- health when this event landed (for the graph)
                isEnv        = ev.isEnv,
                isInstaKill  = ev.isInstaKill, -- instant-death effect (no real amount)
                iconOverride = ev.iconOverride, -- environmental stock icon
                isKillingBlow = ev == kb,
            }
        end
    end

    -- Every hit is rendered (the table scrolls) — no row cap, so we list the same
    -- events as Blizzard's recap rather than dropping the oldest.
    local timeline = hits

    -- Real max health for the curve denominator (fixes the "always starts at 100%"
    -- bug when the fight opened below full HP). GetRecapMaxHealth is reliable on the
    -- newest recap id; UnitHealthMax (non-secret on Midnight) is the cross-check /
    -- backup. We never let the denominator fall below the peak observed HP.
    local recapMax = (type(maxHP) == "number" and maxHP > 0) and maxHP or 0
    local unitMax = 0
    do
        local okm, um = pcall(function() return UnitHealthMax and UnitHealthMax("player") end)
        if okm and type(um) == "number" and um > 0 then unitMax = um end
    end
    local peakHP = 0
    for _, ev in ipairs(allEvents) do
        if type(ev.currentHP) == "number" and ev.currentHP > peakHP then peakHP = ev.currentHP end
    end
    local realMax
    if recapMax > 0 and (unitMax == 0 or recapMax <= unitMax * 1.5) then
        realMax = recapMax            -- trust the recap's own max
    elseif unitMax > 0 then
        realMax = unitMax             -- recap max looked implausible → use the unit's
    else
        realMax = recapMax
    end
    if realMax < peakHP then realMax = peakHP end

    -- Per-hit remaining HP% = the player's health WHEN each hit landed (its own
    -- currentHP / realMax). The table + graph dot read this so the KILLING BLOW
    -- shows the HP you had when it hit (e.g. 2%), NOT 0 — the curve appends a death
    -- point at t=0, so reading the curve at the KB's time would always give 0.
    if realMax > 0 then
        for _, h in ipairs(hits) do
            if type(h.currentHP) == "number" then
                h.hpPct = math.max(0, math.min(100, h.currentHP / realMax * 100))
            end
            -- Insta-kill with only a placeholder amount: the HP it removed is realMax.
            if h.isInstaKill and (h.amount or 0) <= 1 then h.amount = realMax end
        end
        if kb.isInstaKill and (kb.amount or 0) <= 1 then kb.amount = realMax end
    end

    -- HP curve, isolated so any hiccup can only blank the graph, never the report.
    local ok, curve = pcall(BuildRecapCurve, curveEvents, dmg, realMax, kb)
    if not (ok and type(curve) == "table") then curve = {} end

    return {
        killedAt    = deathTime,
        killingBlow = {
            sourceName = kb.sourceName,
            sourceGUID = kb.sourceGUID,   -- best-effort killer portrait
            spellName  = kb.spellName,
            spellID    = kb.spellID,
            amount     = kb.amount,
            overkill   = (kb.overkill and kb.overkill > 0) and kb.overkill or nil,
            isEnv      = kb.isEnv,
            isInstaKill = kb.isInstaKill,
            iconOverride = kb.iconOverride,  -- environmental stock icon (no spell icon)
        },
        events      = timeline,
        hits        = hits,               -- full hit list for graph markers
        sources     = BuildSources(dmg),  -- damage-only (heals excluded)
        healthCurve = curve,
        context     = BuildContext(window),
    }
end

-- ── Public: built-in sample report (for /bdr test) ──────────────────────────
-- Lets the UI be iterated on without dying in-game. Shapes match Build() output.
function Analyzer:SampleReport()
    -- Mirrors the DESIGN.png mock-up: a high plateau that plunges in the last few
    -- seconds. Curve points sit at the hit times so the table's "% Max HP" column
    -- reads each hit's share (before% − after%) straight off the curve.
    local curve = {
        { t = -16.0, pct = 100 },
        { t = -13.0, pct = 96  },
        { t = -10.0, pct = 92  },
        { t = -7.5,  pct = 82  },
        { t = -5.5,  pct = 70  },
        { t = -4.5,  pct = 84  },  -- a heal lands here: HP bumps back up
        { t = -3.5,  pct = 55  },
        { t = -1.5,  pct = 37  },
        { t = 0,     pct = 6   },  -- HP when the killing blow landed (matches its hpPct)
        { t = 0,     pct = 0   },  -- death
    }

    -- Chronological (oldest → newest); the killing blow is last, at t = 0. More than
    -- the 5-row viewport so the table scrolls (exercises the scrollbar in /bdr test).
    local function H(t, source, spell, id, amount, school, extra)
        local h = { t = t, kind = "damage", sourceName = source, spellName = spell,
                    spellID = id, amount = amount, school = school }
        if extra then for k, v in pairs(extra) do h[k] = v end end
        return h
    end
    -- school masks: 1 Physical · 4 Fire · 16 Frost · 32 Shadow
    local hits = {
        H(-16.0, "Decaying Horror", "Bone Nova",  49158, 6400,  16),
        { t = -13.0, kind = "damage", periodic = true, sourceName = "Mephisto",
          spellName = "Corruption", spellID = 172, amount = 8100, school = 32 },   -- DoT (Shadow)
        { t = -11.0, kind = "damage", sourceName = "Mephisto",
          spellName = "Melee", spellID = 88163, amount = 15000, school = 1 },      -- melee (Physical)
        H(-10.0, "Decaying Horror", "Bone Nova",  49158, 9800,  16),
        H(-7.5,  "Mephisto",        "Desolation", 47897, 12165, 32),
        { t = -6.5, kind = "heal", periodic = true, sourceName = "Field Medic",
          spellName = "Renew", spellID = 139, amount = 6000 },                     -- HoT tick
        H(-5.5,  "Decaying Horror", "Bone Nova",  49158, 18972, 16),
        { t = -4.5, kind = "heal", sourceName = "Field Medic",
          spellName = "Flash Heal", spellID = 2061, amount = 32000 },              -- direct heal
        H(-3.5,  "Mephisto",        "Desolation", 47897, 21515, 32),
        H(-1.5,  "Mephisto",        "Desolation", 47897, 28441, 32),
        H(0,     "Mephisto",        "Soulfire",   6353,  78023, 4,
          { overkill = 12000, isKillingBlow = true, hpPct = 6 }),  -- hit you at 6% HP (not 0)
    }
    return {
        killedAt    = GetTime(),
        killingBlow = { sourceName = "Mephisto", spellName = "Soulfire",
                        spellID = 6353, amount = 78023, overkill = 12000 },
        events = hits,
        hits   = hits,
        sources = {
            { name = "Mephisto",        total = 143753, pct = 78.1, spellID = 6353  },
            { name = "Decaying Horror", total = 26481,  pct = 14.3, spellID = 49158 },
            { name = "Doom Bolt",       total = 10547,  pct = 5.7,  spellID = 603   },
            { name = "Shade of Doom",   total = 3512,   pct = 1.7,  spellID = 17877 },
        },
        healthCurve = curve,
        context = { difficulty = "Heroic", zone = "The Burning Throne", windowSeconds = 10 },
        isSample = true,
    }
end
