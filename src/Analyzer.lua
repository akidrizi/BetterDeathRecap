local _, BDR = ...

-- Analyzer — turn Blizzard's C_DeathRecap data (+ our health snapshot) into a
-- structured DeathReport that Display can render without touching the raw API.
-- Everything here is defensive: every C_DeathRecap field is treated as possibly
-- nil/absent (availability varies by patch — see docs/API-NOTES.md), and a
-- missing source becomes an environmental / "Unknown" label rather than an error.

local Analyzer = {}
BDR.Analyzer = Analyzer

-- ── Helpers ─────────────────────────────────────────────────────────────────

-- Resolve a human label for an event's source. Real attackers carry a name;
-- environmental deaths have a nil source and a sentinel (negative) spellID.
local function ResolveSource(combatantName, spellID)
    if combatantName and combatantName ~= "" then
        return combatantName
    end
    if spellID and BDR.ENVIRONMENT[spellID] then
        return BDR.ENVIRONMENT[spellID]
    end
    return BDR.ENVIRONMENT_FALLBACK
end

-- Pull every event out of every combatant into one flat, source-tagged list.
-- Returns the list (unsorted) or an empty table if the API exposes nothing.
local function GatherEvents()
    local out = {}
    if not (C_DeathRecap and C_DeathRecap.GetCombatants and C_DeathRecap.GetEvents) then
        return out
    end

    local combatants = C_DeathRecap.GetCombatants()
    if type(combatants) ~= "table" then return out end

    for index, combatant in ipairs(combatants) do
        local name = type(combatant) == "table" and combatant.name or nil
        local events = C_DeathRecap.GetEvents(index)
        if type(events) == "table" then
            for _, ev in ipairs(events) do
                if type(ev) == "table" and ev.amount then
                    out[#out + 1] = {
                        timestamp  = ev.timestamp or 0,
                        spellID    = ev.spellID,
                        spellName  = ev.spellName,
                        amount     = ev.amount or 0,
                        absorbed   = ev.absorbed,
                        overkill   = ev.overkill,
                        sourceName = ResolveSource(name, ev.spellID),
                    }
                end
            end
        end
    end
    return out
end

-- Aggregate per-source damage totals into sorted bars (desc), with percentages.
local function BuildSources(events)
    local totals, order = {}, {}
    local grand = 0
    for _, ev in ipairs(events) do
        local amt = ev.amount or 0
        if amt > 0 then
            if not totals[ev.sourceName] then
                totals[ev.sourceName] = 0
                order[#order + 1] = ev.sourceName
            end
            totals[ev.sourceName] = totals[ev.sourceName] + amt
            grand = grand + amt
        end
    end

    local sources = {}
    for _, name in ipairs(order) do
        sources[#sources + 1] = {
            name  = name,
            total = totals[name],
            pct   = grand > 0 and (totals[name] / grand * 100) or 0,
        }
    end
    table.sort(sources, function(a, b) return a.total > b.total end)
    return sources
end

-- Normalise the health snapshot into a curve of { t = <relative secs>, pct }.
-- `deathTime` is the reference (t = 0 at death; samples are negative seconds).
local function BuildHealthCurve(snapshot, deathTime)
    local curve = {}
    if type(snapshot) ~= "table" or type(snapshot.samples) ~= "table" then
        return curve
    end
    local window = BDR.CONFIG.WINDOW_SECONDS
    for _, s in ipairs(snapshot.samples) do
        local rel = s.t - deathTime
        if rel >= -window and rel <= 0 and s.hpMax and s.hpMax > 0 then
            curve[#curve + 1] = { t = rel, pct = (s.hp / s.hpMax) * 100 }
        end
    end
    -- Ensure the curve ends at death (0%, t = 0) so the line lands on the dot.
    if #curve > 0 and curve[#curve].t < 0 then
        curve[#curve + 1] = { t = 0, pct = 0 }
    end
    return curve
end

-- Best-effort context line: difficulty, zone, window length.
local function BuildContext()
    local zone = (GetRealZoneText and GetRealZoneText()) or "Unknown"
    local difficulty
    if GetInstanceInfo then
        local _, _, _, diffName = GetInstanceInfo()
        if diffName and diffName ~= "" then difficulty = diffName end
    end
    return {
        difficulty    = difficulty,
        zone          = zone,
        windowSeconds = BDR.CONFIG.WINDOW_SECONDS,
    }
end

-- ── Public: build a report from live data ───────────────────────────────────
-- Returns a DeathReport (see CLAUDE.md) or nil if there is nothing to show.
function Analyzer:Build(snapshot)
    local events = GatherEvents()
    if #events == 0 then
        -- No usable recap events. Still return a minimal report so Display can
        -- show a "No recap data" state rather than nothing at all.
        return {
            killedAt    = GetTime(),
            killingBlow = nil,
            events      = {},
            sources     = {},
            healthCurve = BuildHealthCurve(snapshot, (snapshot and snapshot.now) or GetTime()),
            context     = BuildContext(),
            empty       = true,
        }
    end

    -- Chronological order (oldest first). The killing blow is the latest hit.
    table.sort(events, function(a, b) return a.timestamp < b.timestamp end)
    local kb = events[#events]
    local deathTime = kb.timestamp ~= 0 and kb.timestamp or ((snapshot and snapshot.now) or GetTime())

    -- Re-express timestamps as seconds relative to death (<= 0).
    local timeline = {}
    for _, ev in ipairs(events) do
        timeline[#timeline + 1] = {
            t            = ev.timestamp ~= 0 and (ev.timestamp - deathTime) or 0,
            sourceName   = ev.sourceName,
            spellName    = ev.spellName,
            spellID      = ev.spellID,
            amount       = ev.amount,
            absorbed     = (ev.absorbed and ev.absorbed > 0) and ev.absorbed or nil,
            isKillingBlow = ev == kb,
        }
    end

    -- Cap the rendered timeline to the most recent N hits (oldest dropped) but
    -- always keep the killing blow (it's last, so it survives the tail cut).
    local maxRows = BDR.CONFIG.MAX_TIMELINE
    if #timeline > maxRows then
        local trimmed = {}
        for i = #timeline - maxRows + 1, #timeline do
            trimmed[#trimmed + 1] = timeline[i]
        end
        timeline = trimmed
    end

    return {
        killedAt    = deathTime,
        killingBlow = {
            sourceName = kb.sourceName,
            spellName  = kb.spellName,
            spellID    = kb.spellID,
            amount     = kb.amount,
            overkill   = (kb.overkill and kb.overkill > 0) and kb.overkill or nil,
        },
        events      = timeline,
        sources     = BuildSources(events),
        healthCurve = BuildHealthCurve(snapshot, deathTime),
        context     = BuildContext(),
    }
end

-- ── Public: built-in sample report (for /bdr test) ──────────────────────────
-- Lets the UI be iterated on without dying in-game. Shapes match Build() output.
function Analyzer:SampleReport()
    local curve = {}
    -- A plausible decline: chip damage, a big setup hit, then the killing blow.
    local pcts = { 100, 98, 95, 88, 86, 60, 58, 55, 30, 28, 12, 0 }
    for i, pct in ipairs(pcts) do
        curve[i] = { t = -8 + (i - 1) * (8 / (#pcts - 1)), pct = pct }
    end

    return {
        killedAt    = GetTime(),
        killingBlow = { sourceName = "Voidflame Tyrant", spellName = "Cataclysm",
                        spellID = 1604, amount = 482000, overkill = 71000 },
        events = {
            { t = -7.4, sourceName = "Voidflame Tyrant", spellName = "Shadow Bolt",
              spellID = 686, amount = 42000 },
            { t = -6.1, sourceName = "Searing Imp", spellName = "Fireball",
              spellID = 133, amount = 38000 },
            { t = -4.8, sourceName = "Voidflame Tyrant", spellName = "Dark Nova",
              spellID = 1949, amount = 96000, absorbed = 21000 },
            { t = -3.0, sourceName = "Searing Imp", spellName = "Fireball",
              spellID = 133, amount = 41000 },
            { t = -1.2, sourceName = "Voidflame Tyrant", spellName = "Shadow Bolt",
              spellID = 686, amount = 58000 },
            { t = 0,    sourceName = "Voidflame Tyrant", spellName = "Cataclysm",
              spellID = 1604, amount = 482000, isKillingBlow = true },
        },
        sources = {
            { name = "Voidflame Tyrant", total = 678000, pct = 89.6 },
            { name = "Searing Imp",      total = 79000,  pct = 10.4 },
        },
        healthCurve = curve,
        context = { difficulty = "Mythic", zone = "The Ember Court", windowSeconds = 8 },
        isSample = true,
    }
end
