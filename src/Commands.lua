local _, BDR = ...

-- /bdr slash commands. The bare command toggles the window; subcommands drive
-- the demo, history, and lock state.
local function Dispatch(msg)
    local cmd = (msg or ""):match("^%s*(%S*)"):lower()

    if cmd == "" or cmd == "toggle" then
        BDR.Display:Toggle()

    elseif cmd == "test" or cmd == "demo" then
        BDR.Display:Show(BDR.Analyzer:SampleReport())

    elseif cmd == "history" or cmd == "last" then
        BDR.Display:ShowLast()

    elseif cmd == "lock" then
        BDR.Display:SetLocked(true)
        BDR.Print(BDR.COLOR.OK .. "Window locked." .. BDR.COLOR.RESET)

    elseif cmd == "unlock" then
        BDR.Display:SetLocked(false)
        BDR.Print(BDR.COLOR.OK .. "Window unlocked — drag to move." .. BDR.COLOR.RESET)

    else
        BDR.Print("Commands: " .. BDR.COLOR.GRAY
            .. "/bdr (toggle) · /bdr test · /bdr history · /bdr lock · /bdr unlock" .. BDR.COLOR.RESET)
    end
end

SLASH_BETTERDEATHRECAP1 = "/bdr"
SLASH_BETTERDEATHRECAP2 = "/betterdeathrecap"
SlashCmdList["BETTERDEATHRECAP"] = Dispatch
