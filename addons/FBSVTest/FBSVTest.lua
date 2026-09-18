-- FBSVTest.lua -- when, and whether, do pre-seeded SavedVariables arrive?
-- Author: Thunderz
--
-- Three saved globals, all pre-seeded on disk before first launch:
--   FBSVTestSeeded  never touched by this addon. Pure observation of the client.
--   FBSVTestEager   handled the way AceDB/BugSack/EllesmereUI do it: if it is
--                   nil at ADDON_LOADED, a fresh table is created and kept.
--   FBSVTestLog     the observations. Pre-seeded with a marker too, and
--                   re-attached lazily at every write so a late load cannot
--                   orphan it.
--
-- The question: does the client (a) deliver the seed late, replacing the eager
-- table, (b) skip the seed because the global already exists, or (c) never
-- read the seeded files at all?

local observations = {}
local eagerRef

local function describe(v)
    if type(v) ~= "table" then return type(v) end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    return "table:" .. n .. ":marker=" .. tostring(v.marker)
end

local function note(moment)
    observations[#observations + 1] = {
        moment = moment,
        t = GetTime(),
        seeded = describe(FBSVTestSeeded),
        eager = describe(FBSVTestEager),
        eagerIsOurTable = (eagerRef ~= nil) and (FBSVTestEager == eagerRef) or nil,
        logGlobal = describe(FBSVTestLog),
    }
end

local function flush()
    -- Re-read the global every time (the pattern that works on this client).
    if type(FBSVTestLog) ~= "table" then FBSVTestLog = {} end
    FBSVTestLog.sessions = FBSVTestLog.sessions or {}
    FBSVTestLog.current = observations
end

note("main chunk")

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("VARIABLES_LOADED")
f:RegisterEvent("SAVED_VARIABLES_TOO_LARGE")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_LOGOUT")
f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "FBSVTest" then return end
        note("ADDON_LOADED before eager init")
        if type(FBSVTestEager) ~= "table" then
            FBSVTestEager = { marker = "created-by-addon-at-ADDON_LOADED" }
        end
        eagerRef = FBSVTestEager
        note("ADDON_LOADED after eager init")
    elseif event == "PLAYER_LOGOUT" then
        note("PLAYER_LOGOUT")
        flush()
        if type(FBSVTestLog) == "table" then
            local s = FBSVTestLog.sessions
            s[#s + 1] = observations
            FBSVTestLog.current = nil
        end
        return
    else
        note(event .. (arg1 and (" " .. tostring(arg1)) or ""))
    end
    flush()
    if event == "PLAYER_LOGIN" then
        for _, delay in ipairs({ 1, 5, 15 }) do
            C_Timer.After(delay, function() note("login+" .. delay .. "s") flush() end)
        end
    end
end)
