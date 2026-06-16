local _, BDR = ...

-- /bdr slash commands. The bare command toggles the window; subcommands drive
-- the demo, history, and lock state.
local function Dispatch(msg)
    local L = BDR.L
    local cmd = (msg or ""):match("^%s*(%S*)"):lower()

    if cmd == "" or cmd == "toggle" then
        BDR.Display:Toggle()

    elseif cmd == "test" or cmd == "demo" then
        BDR.Display:Show(BDR.Analyzer:SampleReport())

    elseif cmd == "history" or cmd == "last" then
        BDR.Display:ShowLast()

    elseif cmd == "options" or cmd == "config" then
        if BDR.Options then BDR.Options:Open() end

    elseif cmd == "lock" then
        BDR.Display:SetLocked(true)
        BDR.Print(BDR.COLOR.OK .. L.LOCKED .. BDR.COLOR.RESET)

    elseif cmd == "unlock" then
        BDR.Display:SetLocked(false)
        BDR.Print(BDR.COLOR.OK .. L.UNLOCKED .. BDR.COLOR.RESET)

    elseif cmd == "dump" then
        for _, line in ipairs(BDR.Analyzer:DumpEvents()) do
            BDR.Print(line)
        end

    elseif cmd == "btn" then
        for _, line in ipairs(BDR.RecapButton:Diagnose()) do
            BDR.Print(line)
        end

    elseif cmd == "debug" then
        local p = BDR.Analyzer:Probe()
        if not p.hasNamespace then
            BDR.Print(BDR.COLOR.WARN .. L.DEBUG_NO_API .. BDR.COLOR.RESET)
        else
            local yn = function(v) return v and "yes" or "no" end
            BDR.Print(L.DEBUG_API:format(yn(p.hasGet), yn(p.hasHas), yn(p.hasMaxHP)))
            BDR.Print(("recap id: %s · maxHP: %s · damage events read: %d"):format(
                tostring(p.recapID or "?"), tostring(p.maxHP or "?"), p.eventCount))
            local members = (#p.members > 0) and table.concat(p.members, ", ") or "(none — pairs() blocked)"
            BDR.Print(BDR.COLOR.OK .. "C_DeathRecap members: " .. BDR.COLOR.RESET .. members)
            if #p.firstEvent > 0 then
                BDR.Print(BDR.COLOR.OK .. "First event fields: " .. BDR.COLOR.RESET
                    .. table.concat(p.firstEvent, ", "))
            end
            if #p.globals > 0 then
                BDR.Print(BDR.COLOR.OK .. "Globals present: " .. BDR.COLOR.RESET .. table.concat(p.globals, ", "))
            end
            BDR.Print(BDR.COLOR.GRAY .. L.DEBUG_HINT .. BDR.COLOR.RESET)
        end

    else
        BDR.Print(BDR.COLOR.GRAY .. L.CMD_HELP .. BDR.COLOR.RESET)
    end
end

SLASH_BETTERDEATHRECAP1 = "/bdr"
SLASH_BETTERDEATHRECAP2 = "/betterdeathrecap"
SlashCmdList["BETTERDEATHRECAP"] = Dispatch
