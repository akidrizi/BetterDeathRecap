local _, BDR = ...

-- HealthTracker — a rolling buffer of the player's health, sampled on the
-- event-driven UNIT_HEALTH event (never polled). C_DeathRecap gives us the hits
-- but not a health-over-time curve, so we reconstruct one from these samples.
--
-- Buffer entries: { t = GetTime(), hp = <current>, hpMax = <max> }
-- Oldest-first. Pruned to CONFIG.WINDOW_SECONDS on every sample, and hard-capped
-- at CONFIG.MAX_SAMPLES so a pathological event storm can't grow it unbounded.

local HealthTracker = {}
BDR.HealthTracker = HealthTracker

local samples = {}

function HealthTracker:Clear()
    wipe(samples)
end

-- Record one sample of the player's current/max health. Cheap: two API reads,
-- one table insert, and a prune of entries older than the window.
function HealthTracker:Sample()
    local hpMax = UnitHealthMax("player")
    if not hpMax or hpMax <= 0 then return end  -- loading screen / no valid unit yet

    local now = GetTime()
    samples[#samples + 1] = { t = now, hp = UnitHealth("player"), hpMax = hpMax }

    -- Drop anything older than the window (from the front).
    local cutoff = now - BDR.CONFIG.WINDOW_SECONDS
    local firstKept = 1
    while samples[firstKept] and samples[firstKept].t < cutoff do
        firstKept = firstKept + 1
    end
    if firstKept > 1 then
        local n = 0
        for i = firstKept, #samples do
            n = n + 1
            samples[n] = samples[i]
        end
        for i = n + 1, #samples do
            samples[i] = nil
        end
    end

    -- Hard cap (defensive): keep only the most recent MAX_SAMPLES.
    local overflow = #samples - BDR.CONFIG.MAX_SAMPLES
    if overflow > 0 then
        local n = 0
        for i = overflow + 1, #samples do
            n = n + 1
            samples[n] = samples[i]
        end
        for i = n + 1, #samples do
            samples[i] = nil
        end
    end
end

-- Return a frozen copy of the buffer for the Analyzer: a plain array of
-- { t, hp, hpMax }, oldest-first, plus the reference end time (now). The copy
-- means later sampling can't mutate a report already built.
function HealthTracker:Snapshot()
    local out = {}
    for i = 1, #samples do
        local s = samples[i]
        out[i] = { t = s.t, hp = s.hp, hpMax = s.hpMax }
    end
    return { samples = out, now = GetTime() }
end
