-- FB_Probe.lua -- what does this client actually expose?
-- Author: Thunderz
--
-- Day-one questions for the Forever beta: which build, which interface
-- number, which C_ namespaces exist, which Blizzard UI addons load, and
-- whether anything named Legacy / Camp / Transmog / Ruleset / Layer is
-- reachable from Lua. All of it is written to db.probe so the answers travel
-- with the data instead of living in a screenshot.

local ADDON, ns = ...

local KEYWORDS = { "legacy", "camp", "transmog", "ruleset", "layer", "skyborne",
                   "forever", "blueprint", "campfire", "hardcore", "realmless" }

-- Names that contain a keyword by accident: "player" has "layer" in it and
-- "campaign" has "camp". Exclude before matching.
local FALSE_HITS = { "player", "campaign", "displayer", "multilayer", "keylayer" }

local function matchesKeyword(name)
    local lower = strlower(name)
    for _, bad in ipairs(FALSE_HITS) do
        lower = lower:gsub(bad, "")
    end
    for _, k in ipairs(KEYWORDS) do
        if lower:find(k, 1, true) then return k end
    end
    return nil
end

local function probeBuild(p)
    local version, build, date, toc = GetBuildInfo()
    p.version   = version
    p.build     = build
    p.buildDate = date
    p.interface = toc
    p.project   = WOW_PROJECT_ID
    p.projectConstants = {
        mainline = WOW_PROJECT_MAINLINE, classic = WOW_PROJECT_CLASSIC,
        bcc = WOW_PROJECT_BURNING_CRUSADE_CLASSIC, wrath = WOW_PROJECT_WRATH_CLASSIC,
        cata = WOW_PROJECT_CATACLYSM_CLASSIC, mists = WOW_PROJECT_MISTS_CLASSIC,
    }
    p.locale   = GetLocale()
    p.realm    = GetRealmName()
    p.portal   = GetCVar and GetCVar("portal")
    p.realmID  = GetRealmID and GetRealmID()
    p.probed   = time()
    if LE_EXPANSION_LEVEL_CURRENT then p.expansionLevel = LE_EXPANSION_LEVEL_CURRENT end
    if GetServerExpansionLevel then p.serverExpansion = GetServerExpansionLevel() end
    if GetMaxLevelForPlayerExpansion then p.maxLevel = GetMaxLevelForPlayerExpansion() end
    if GetMaxPlayerLevel then p.maxPlayerLevel = GetMaxPlayerLevel() end
end

-- Every C_ namespace and the function names inside it. This is the API map.
local function probeNamespaces(p)
    local out = {}
    for name, value in pairs(_G) do
        if type(name) == "string" and name:sub(1, 2) == "C_" and type(value) == "table" then
            local fns = {}
            for k, v in pairs(value) do
                if type(v) == "function" then fns[#fns + 1] = k end
            end
            table.sort(fns)
            out[name] = fns
        end
    end
    p.namespaces = out
end

-- Globals whose name mentions one of the Forever systems: functions, tables,
-- frames, constants. Cheap to gather and it points straight at the new UI.
local function probeKeywordGlobals(p)
    local out = {}
    local n = 0
    for name, value in pairs(_G) do
        if type(name) == "string" and n < 3000 then
            local k = matchesKeyword(name)
            if k then
                local t = type(value)
                local rec = { type = t, keyword = k }
                if t == "table" and type(value.GetObjectType) == "function" then
                    local ok, ot = pcall(value.GetObjectType, value)
                    rec.type = ok and ("frame:" .. tostring(ot)) or "frame"
                elseif t == "string" or t == "number" or t == "boolean" then
                    rec.value = value
                end
                out[name] = rec
                n = n + 1
            end
        end
    end
    p.keywordGlobals = out
end

-- Enum tables carry a lot of "what exists" signal for free.
local function probeEnums(p)
    local out = {}
    if type(Enum) ~= "table" then p.enums = out return end
    for name, value in pairs(Enum) do
        if type(value) == "table" then
            local k = matchesKeyword(name)
            if k then
                local fields = {}
                for field, num in pairs(value) do
                    if type(num) == "number" then fields[field] = num end
                end
                out[name] = fields
            end
        end
    end
    local names = {}
    for name in pairs(Enum) do names[#names + 1] = name end
    table.sort(names)
    p.enumNames = names
    p.enums = out
end

local function probeAddons(p)
    local out = {}
    local getNum   = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
    local getInfo  = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if not (getNum and getInfo) then p.addons = out return end
    for i = 1, getNum() do
        local name, title, _, loadable, reason = getInfo(i)
        out[#out + 1] = { name = name, loadable = loadable and true or false,
                          reason = reason, loaded = isLoaded and isLoaded(i) and true or false }
    end
    p.addons = out
end

-- Presence checks for the calls the collectors want. Missing ones are the
-- porting to-do list.
local WANTED = {
    "C_Map.GetBestMapForUnit", "C_Map.GetPlayerMapPosition", "C_Map.GetMapInfo",
    "C_QuestLog.GetQuestObjectives", "C_QuestLog.GetInfo", "C_QuestLog.GetNumQuestLogEntries",
    "C_QuestLog.GetTitleForQuestID", "GetQuestLogTitle", "GetNumQuestLogEntries",
    "C_GossipInfo.GetOptions", "GetGossipOptions",
    "C_UnitAuras.GetAuraDataByIndex", "UnitAura",
    "C_Container.GetContainerItemLink", "GetContainerItemLink",
    "C_Item.GetItemInfo", "GetItemInfo", "C_Spell.GetSpellInfo", "GetSpellInfo",
    "GetNumTalentTabs", "GetTalentInfo", "C_ClassTalents.GetActiveConfigID",
    "GetNumSpellTabs", "GetSpellBookItemInfo", "C_SpellBook.GetSpellBookSkillLineInfo",
    "TooltipDataProcessor.AddTooltipPostCall", "GetLootSourceInfo", "GetMerchantItemInfo",
    "GetTrainerServiceInfo", "NumTaxiNodes", "C_TransmogCollection.GetAppearanceSources",
    "C_Transmog.GetSlotInfo", "CombatLogGetCurrentEventInfo", "UnitCreatureType",
    "C_AddOns.GetNumAddOns", "GetNumAddOns", "C_Timer.After", "seterrorhandler",
}

local function resolve(path)
    local cur = _G
    for part in path:gmatch("[^%.]+") do
        if type(cur) ~= "table" then return nil end
        cur = cur[part]
    end
    return cur
end

local function probeWanted(p)
    local out = {}
    for _, path in ipairs(WANTED) do
        out[path] = type(resolve(path)) == "function"
    end
    p.wanted = out
end

-- Every global function and every named global frame. With this list, "what
-- will addon X be missing on this client" becomes an offline diff instead of
-- a crash-by-crash hunt.
local function probeGlobals(p)
    local fns, frames = {}, {}
    for name, value in pairs(_G) do
        if type(name) == "string" then
            local t = type(value)
            if t == "function" then
                fns[#fns + 1] = name
            elseif t == "table" and type(rawget(value, 0)) == "userdata" and #frames < 12000 then
                frames[#frames + 1] = name
            end
        end
    end
    table.sort(fns)
    table.sort(frames)
    p.globalFunctions = fns
    p.globalFrames = frames
end

-- What the client says about its own rules: secrecy, addon restrictions,
-- combat-log lockdown, game mode. Every zero-argument predicate in the
-- relevant namespaces is called and its answer recorded, so new predicates
-- show up without being listed here.
local RULE_NAMESPACES = { "C_Secrets", "C_RestrictedActions", "C_CombatLog", "C_GameRules",
                          "C_DamageMeter", "C_SwingTimer", "C_BlizzCon2026", "C_InputInterfaceStyle",
                          "C_Weather" }
local RULE_PREFIXES = { "Is", "Has", "Should", "Are", "Can", "Get", "Account", "Does" }
local RULE_SKIP = { GetGameRuleAsFloat = true, GetGameRuleAsFrameStrata = true, IsGameRuleActive = true }

local function probeRules(p)
    local out = {}
    for _, nsName in ipairs(RULE_NAMESPACES) do
        local tbl = _G[nsName]
        if type(tbl) == "table" then
            local res = {}
            for fname, fn in pairs(tbl) do
                if type(fn) == "function" and not RULE_SKIP[fname] then
                    local wanted = false
                    for _, pre in ipairs(RULE_PREFIXES) do
                        if fname:sub(1, #pre) == pre then wanted = true break end
                    end
                    if wanted then
                        local ok, v = pcall(fn)
                        if not ok then
                            res[fname] = "<error>"
                        elseif issecretvalue and issecretvalue(v) then
                            res[fname] = "<secret>"
                        elseif type(v) == "table" then
                            res[fname] = "<table>"
                        elseif v == nil then
                            res[fname] = "<nil>"
                        else
                            res[fname] = v
                        end
                    end
                end
            end
            out[nsName] = res
        end
    end
    -- Every numbered game rule that is switched on.
    if C_GameRules and C_GameRules.IsGameRuleActive and Enum and Enum.GameRule then
        local active = {}
        for name, id in pairs(Enum.GameRule) do
            local ok, on = pcall(C_GameRules.IsGameRuleActive, id)
            if ok and on then
                local okf, val = pcall(C_GameRules.GetGameRuleAsFloat, id)
                active[name] = okf and val or true
            end
        end
        out.activeGameRules = active
    end
    if C_AddOns and C_AddOns.GetScriptsDisallowedForBeta then
        local ok, list = pcall(C_AddOns.GetScriptsDisallowedForBeta)
        if ok then out.scriptsDisallowedForBeta = list end
    end
    p.rules = out
end

function ns.RunProbe(reason)
    local db = ns.DB()
    local p = db.probe
    p.reason = reason
    ns.try("probe.rules",    probeRules,          p)
    ns.try("probe.globals",  probeGlobals,        p)
    ns.try("probe.build",    probeBuild,          p)
    ns.try("probe.ns",       probeNamespaces,     p)
    ns.try("probe.keywords", probeKeywordGlobals, p)
    ns.try("probe.enums",    probeEnums,          p)
    ns.try("probe.addons",   probeAddons,         p)
    ns.try("probe.wanted",   probeWanted,         p)
end

-- Visible frames whose name matches a keyword. Run "/fb frames" with the
-- Legacy panel or a campfire window open.
function ns.ScanFrames()
    local db = ns.DB()
    db.probe.frames = db.probe.frames or {}
    local n = 0
    local f = EnumerateFrames()
    while f do
        local ok, name = pcall(f.GetName, f)
        if ok and name and matchesKeyword(name) then
            local rec = { t = time() }
            local ok2, shown = pcall(f.IsShown, f)
            rec.shown = ok2 and shown and true or false
            local ok3, parent = pcall(function() return f:GetParent() and f:GetParent():GetName() end)
            if ok3 then rec.parent = parent end
            local ok4, ot = pcall(f.GetObjectType, f)
            if ok4 then rec.type = ot end
            db.probe.frames[name] = rec
            n = n + 1
        end
        f = EnumerateFrames(f)
    end
    return n
end

-- Blizzard UI modules loading later (opening a panel loads its addon) get
-- logged too, and the keyword scan is re-run so their globals are captured.
ns.On("ADDON_LOADED", function(name)
    if type(name) ~= "string" or name:sub(1, 9) ~= "Blizzard_" then return end
    local db = ns.DB()
    db.probe.blizzardLoaded = db.probe.blizzardLoaded or {}
    db.probe.blizzardLoaded[name] = time()
    if matchesKeyword(name) then
        ns.try("probe.keywords", probeKeywordGlobals, db.probe)
        ns.try("probe.enums",    probeEnums,          db.probe)
    end
end)

ns.On("PLAYER_LOGIN", function()
    C_Timer.After(5, function() ns.RunProbe("login") end)
end)
