-- FB_Core.lua -- database, helpers, event dispatch, slash commands, payload
-- Author: Thunderz
--
-- Forever Beacon is Beacon's shell pointed at the world instead of the
-- character: every collector writes into ForeverBeaconDB, the JSON payload is
-- encoded at logout, and tools/fb_extract.py turns it into CSV/JSONL.
--
-- Two storage shapes are used everywhere:
--   * "catalogs" are dictionaries keyed by an ID (npcID, itemID, questID...)
--     so repeat sightings merge instead of piling up
--   * "logs" are capped lists of events (loot drops, quest turn-ins...)
--     where every occurrence matters
--
-- Nothing here assumes a particular client. Every API call that might not
-- exist on the Forever client is wrapped, and a missing function is recorded
-- in db.errors so the gap itself becomes data.

local ADDON, ns = ...

ns.SCHEMA = 1

-- Logs are trimmed oldest-first when they pass these sizes.
ns.CAP = {
    errors      = 200,
    luaErrors   = 100,
    notes       = 500,
    lootEvents  = 20000,
    questEvents = 5000,
    objProgress = 10000,
    infoMsgs    = 3000,
    zoneVisits  = 3000,
    tooltipsRaw = 4000,
    posPerEntity = 12,   -- sightings kept per NPC / object
    eventFirst  = 2000,  -- distinct event names tracked by the firehose
}

local frame = CreateFrame("Frame")
ns.frame = frame

function ns.printf(fmt, ...)
    print("|cffd2621fForever Beacon|r: " .. string.format(fmt, ...))
end

function ns.trim(t, cap)
    while #t > cap do
        table.remove(t, 1)
    end
end

function ns.push(list, cap, rec)
    list[#list + 1] = rec
    if #list > cap then ns.trim(list, cap) end
end

-- Database -----------------------------------------------------------------

function ns.DB()
    ForeverBeaconDB = ForeverBeaconDB or {}
    local db = ForeverBeaconDB
    db.schema = ns.SCHEMA
    -- catalogs
    db.probe      = db.probe      or {}
    db.events     = db.events     or {}   -- firehose: name -> {n, first, args}
    db.maps       = db.maps       or {}   -- mapID -> map info
    db.zones      = db.zones      or {}   -- "map|zone|sub" -> {…, pos}
    db.npcs       = db.npcs       or {}   -- npcID -> creature record
    db.objects    = db.objects    or {}   -- name or objectID -> object record
    db.vendors    = db.vendors    or {}   -- npcID -> item list
    db.trainers   = db.trainers   or {}   -- npcID -> service list
    db.gossip     = db.gossip     or {}   -- npcID -> gossip text/options
    db.taxi       = db.taxi       or {}   -- node name -> connections
    db.items      = db.items      or {}   -- itemID -> tooltip record
    db.spells     = db.spells     or {}   -- spellID -> spell record
    db.auras      = db.auras      or {}   -- spellID -> aura seen on player
    db.npcAbilities = db.npcAbilities or {} -- npcID -> spellID -> stats
    db.quests     = db.quests     or {}   -- questID -> quest record
    db.talents    = db.talents    or {}   -- class -> tab -> talents
    db.spellbook  = db.spellbook  or {}   -- class -> spells
    db.legacy     = db.legacy     or {}   -- anything the Legacy/Camping probes find
    db.traits     = db.traits     or {}   -- configID -> trait trees (class talents, Legacy trees)
    -- logs
    db.lootEvents  = db.lootEvents  or {}
    db.questEvents = db.questEvents or {}
    db.objProgress = db.objProgress or {}
    db.infoMsgs    = db.infoMsgs    or {}
    db.zoneVisits  = db.zoneVisits  or {}
    db.tooltipsRaw = db.tooltipsRaw or {}
    db.notes       = db.notes       or {}
    db.errors      = db.errors      or {}
    db.luaErrors   = db.luaErrors   or {}
    db.chars       = db.chars       or {}
    return db
end

function ns.err(domain, e)
    local db = ns.DB()
    ns.push(db.errors, ns.CAP.errors, { t = time(), domain = domain, err = tostring(e) })
end

-- Runs fn under pcall and files the failure under `domain`.
function ns.try(domain, fn, ...)
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then
        ns.err(domain, a)
        return nil
    end
    return a, b, c, d
end

-- Helpers ------------------------------------------------------------------

function ns.CharKey()
    local name  = UnitName("player") or "?"
    local realm = GetRealmName() or "?"
    return name .. "-" .. realm
end

-- Midnight-era clients hand back "secret" numbers for some combat values
-- (unit health, damage amounts) that Lua may hold but not compare. Returns
-- nil for those so collectors record "unavailable" instead of erroring.
function ns.Num(v)
    if type(v) ~= "number" then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    -- Belt and braces: a secret number errors on comparison, so try one.
    local ok = pcall(function() return v > 0 end)
    if not ok then return nil end
    return v
end

-- "Creature-0-4379-0-9-3123-000041A3F1" -> "Creature", 3123
function ns.ParseGUID(guid)
    if type(guid) ~= "string" then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind == "Player" then return kind, nil end
    return kind, tonumber(id)
end

-- Current player position. Returns nil inside instances where the map API
-- gives nothing, which is itself worth knowing.
function ns.Pos()
    local rec = { zone = GetRealZoneText(), sub = GetSubZoneText() }
    if C_Map and C_Map.GetBestMapForUnit then
        local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
        if ok and mapID then
            rec.map = mapID
            local ok2, v = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
            if ok2 and v then
                local x, y = v:GetXY()
                if x and y then
                    rec.x = math.floor(x * 10000) / 10000
                    rec.y = math.floor(y * 10000) / 10000
                end
            end
        end
    end
    return rec
end

function ns.PosString(p)
    if not p or not p.x then return "?" end
    return string.format("%s %.1f,%.1f", p.zone or "?", p.x * 100, p.y * 100)
end

-- Adds a sighting to a catalog entry without letting it grow unbounded.
function ns.AddSighting(rec)
    rec.sightings = rec.sightings or {}
    local p = ns.Pos()
    p.t = time()
    local last = rec.sightings[#rec.sightings]
    if last and last.map == p.map and last.x and p.x
        and math.abs(last.x - p.x) < 0.003 and math.abs(last.y - p.y) < 0.003 then
        last.t = p.t
        last.n = (last.n or 1) + 1
        return
    end
    ns.push(rec.sightings, ns.CAP.posPerEntity, p)
end

-- Tooltip lines of any GameTooltip-like frame as a flat list of strings.
function ns.TooltipLines(tt)
    local out = {}
    local name = tt:GetName()
    if not name then return out end
    for i = 1, tt:NumLines() do
        local left  = _G[name .. "TextLeft"  .. i]
        local right = _G[name .. "TextRight" .. i]
        local l = left  and left:GetText()
        local r = right and right:GetText()
        if l and l ~= "" then
            out[#out + 1] = r and r ~= "" and (l .. " || " .. r) or l
        end
    end
    return out
end

-- Manual annotations: "/fb note campfire with 3 slots here" while exploring.
function ns.Note(text)
    local db = ns.DB()
    local p = ns.Pos()
    p.t = time()
    p.text = text
    p.char = ns.CharKey()
    ns.push(db.notes, ns.CAP.notes, p)
    ns.printf("noted at %s: %s", ns.PosString(p), text)
end

-- Event dispatch -----------------------------------------------------------

ns.handlers = {}

-- Collectors register with ns.On("EVENT", fn). Several collectors may share
-- an event.
function ns.On(event, fn)
    local list = ns.handlers[event]
    if not list then
        list = {}
        ns.handlers[event] = list
        -- Registering an event the client does not know throws. On a new
        -- client that is expected, so record it and carry on loading.
        local ok = pcall(frame.RegisterEvent, frame, event)
        if not ok then
            ns.unknownEvents = ns.unknownEvents or {}
            ns.unknownEvents[#ns.unknownEvents + 1] = event
        end
    end
    list[#list + 1] = fn
end

frame:SetScript("OnEvent", function(_, event, ...)
    local list = ns.handlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, e = pcall(list[i], ...)
        if not ok then ns.err(event, e) end
    end
end)

-- Event firehose: every event the client fires, with a count and the first
-- set of scalar arguments seen. New events (LEGACY_*, CAMP_*, whatever they
-- turn out to be) show up here without anyone having to guess the names.
local SKIP_ARGS = { COMBAT_LOG_EVENT_UNFILTERED = true, CHAT_MSG_ADDON = true }
local fire = CreateFrame("Frame")
fire:RegisterAllEvents()
fire:SetScript("OnEvent", function(_, event, ...)
    local db = ns.DB()
    local rec = db.events[event]
    if not rec then
        local n = 0
        for _ in pairs(db.events) do n = n + 1 end
        if n >= ns.CAP.eventFirst then return end
        rec = { n = 0, first = time() }
        db.events[event] = rec
        if not SKIP_ARGS[event] then
            local args = {}
            for i = 1, math.min(select("#", ...), 8) do
                local v = select(i, ...)
                local t = type(v)
                if issecretvalue and issecretvalue(v) then
                    args[i] = "<secret " .. t .. ">"
                elseif t == "string" then
                    args[i] = #v > 120 and (v:sub(1, 120) .. "…") or v
                elseif t == "number" then
                    args[i] = ns.Num(v) or "<secret>"
                elseif t == "boolean" then
                    args[i] = v
                else
                    args[i] = "<" .. t .. ">"
                end
            end
            rec.args = args
        end
    end
    rec.n = rec.n + 1
    rec.last = time()
end)

-- Lua errors from any addon: on a brand-new client the errors are the map of
-- what broke. Chains whatever handler was there before.
do
    local prev = geterrorhandler and geterrorhandler()
    if seterrorhandler then
        local ok = pcall(seterrorhandler, function(msg)
            local db = ForeverBeaconDB
            if db and db.luaErrors then
                ns.push(db.luaErrors, ns.CAP.luaErrors, { t = time(), err = tostring(msg) })
            end
            if prev then return prev(msg) end
        end)
        if not ok then ns.err("errorhandler", "seterrorhandler refused") end
    end
end

-- Payload ------------------------------------------------------------------

function ns.EncodePayload()
    local db = ns.DB()
    local version, build, _, tocversion = GetBuildInfo()
    local doc = {
        schema    = ns.SCHEMA,
        generated = time(),
        client    = { version = version, build = build, interface = tocversion,
                      project = WOW_PROJECT_ID, locale = GetLocale() },
    }
    for k, v in pairs(db) do
        if k ~= "payload" and k ~= "payloadBytes" and k ~= "payloadError" then
            doc[k] = v
        end
    end
    local ok, result = pcall(ns.JSON.encode, doc)
    if ok then
        db.payload      = result
        db.payloadBytes = #result
        db.payloadError = nil
    else
        db.payload      = nil
        db.payloadError = tostring(result)
    end
    return ok, result
end

-- Lifecycle ----------------------------------------------------------------

ns.On("PLAYER_LOGIN", function()
    local db = ns.DB()
    local key = ns.CharKey()
    local _, class = UnitClass("player")
    local _, race  = UnitRace("player")
    db.chars[key] = { class = class, race = race, level = UnitLevel("player"),
                      faction = UnitFactionGroup("player"), lastLogin = time() }
    db.probe.unknownEvents = ns.unknownEvents or {}
    -- The optional !!FBSVDiag addon records when other addons' SavedVariables
    -- appear. Pull its results in once it has finished.
    C_Timer.After(8, function()
        if type(FBSVDiag_Data) == "table" then
            ns.DB().svDiag = { t = FBSVDiag_Data.t, loaded = FBSVDiag_Data.loaded, order = FBSVDiag_Data.order }
        end
    end)
    ns.printf("collecting. /fb for status.")
end)

ns.On("PLAYER_LEVEL_UP", function(level)
    local db = ns.DB()
    local rec = db.chars[ns.CharKey()]
    if rec then rec.level = level end
end)

ns.On("PLAYER_LOGOUT", function()
    ns.EncodePayload()
end)

-- Slash --------------------------------------------------------------------

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

SLASH_FOREVERBEACON1 = "/fb"
SLASH_FOREVERBEACON2 = "/foreverbeacon"
SlashCmdList.FOREVERBEACON = function(msg)
    msg = strtrim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = strlower(cmd or "")
    local db = ns.DB()

    if cmd == "flush" then
        local ok = ns.EncodePayload()
        if ok then
            ns.printf("encoded %d bytes. /reload or log out to write it to disk.", db.payloadBytes or 0)
        else
            ns.printf("|cffff6666encode failed|r: %s", db.payloadError or "unknown")
        end

    elseif cmd == "note" then
        if rest == "" then ns.printf("usage: /fb note <text>") else ns.Note(rest) end

    elseif cmd == "probe" then
        if ns.RunProbe then ns.RunProbe("manual") end
        ns.printf("probe re-run. %d C_ namespaces, %d keyword globals.",
            count(db.probe.namespaces or {}), count(db.probe.keywordGlobals or {}))

    elseif cmd == "frames" then
        if ns.ScanFrames then
            local n = ns.ScanFrames()
            ns.printf("%d matching visible frames recorded under probe.frames.", n)
        end

    elseif cmd == "bugs" then
        -- Errors straight from BugGrabber, no BugSack window needed.
        local n = tonumber(rest) or 8
        local list = BugGrabber and BugGrabber.GetDB and BugGrabber:GetDB() or nil
        if type(list) ~= "table" then
            ns.printf("BugGrabber is not loaded; %d errors in my own log.", #db.luaErrors)
            list = {}
        end
        local session = BugGrabber and BugGrabber.GetSessionId and BugGrabber:GetSessionId() or nil
        local shown = 0
        for i = #list, 1, -1 do
            local e = list[i]
            if not session or e.session == session then
                local msg = tostring(e.message or ""):gsub("|", "||")
                ns.printf("|cffff6666x%d|r %s", e.counter or 1, msg:sub(1, 260))
                -- Where it came from: the first non-Blizzard, non-BugGrabber
                -- addon frames in the stack. Errors raised inside Blizzard's
                -- secure code only make sense with these.
                local shownFrames = 0
                for line in tostring(e.stack or ""):gmatch("[^\n]+") do
                    if line:find("AddOns/", 1, true) and not line:find("AddOns/Blizzard_", 1, true)
                        and not line:find("BugGrabber", 1, true) and not line:find("ForeverBeacon", 1, true) then
                        ns.printf("      |cff999999from|r %s", line:gsub("|", "||"):gsub("^%s*%[?Interface/AddOns/", ""):sub(1, 160))
                        shownFrames = shownFrames + 1
                        if shownFrames >= 2 then break end
                    end
                end
                shown = shown + 1
                if shown >= n then break end
            end
        end
        if shown == 0 then ns.printf("no errors this session.") end
        if BugSack and BugSack.OpenSack then
            local ok, err = pcall(BugSack.OpenSack, BugSack)
            if not ok then ns.printf("BugSack window failed to open: %s", tostring(err):sub(1, 240)) end
        else
            ns.printf("BugSack did not finish loading (no BugSack.OpenSack), which is why /bugsack does nothing.")
        end

    elseif cmd == "frame" then
        -- Why can't I see this frame? Shown/visible/alpha/scale/size/anchors and
        -- the first hidden ancestor.
        local f = _G[rest]
        if type(f) ~= "table" or not f.IsShown then
            ns.printf("no frame named \"%s\".", rest)
        else
            local function safe(fn, ...) local ok, a, b, c, d, e = pcall(fn, ...) if ok then return a, b, c, d, e end end
            ns.printf("%s: shown=%s visible=%s alpha=%.2f effAlpha=%.2f scale=%.2f effScale=%.2f size=%dx%d strata=%s level=%s",
                rest, tostring(f:IsShown()), tostring(f:IsVisible()), f:GetAlpha() or -1, safe(f.GetEffectiveAlpha, f) or -1,
                f:GetScale() or -1, f:GetEffectiveScale() or -1, f:GetWidth() or 0, f:GetHeight() or 0,
                tostring(safe(f.GetFrameStrata, f)), tostring(safe(f.GetFrameLevel, f)))
            for i = 1, (f:GetNumPoints() or 0) do
                local p, rel, rp, x, y = f:GetPoint(i)
                ns.printf("  point %d: %s -> %s %s  x=%.0f y=%.0f", i, tostring(p),
                    tostring(rel and rel.GetName and rel:GetName() or rel), tostring(rp), x or 0, y or 0)
            end
            local l, b, w, h = safe(f.GetRect, f)
            if l then ns.printf("  rect: left=%.0f bottom=%.0f w=%.0f h=%.0f  (screen %dx%d)", l, b, w, h, GetScreenWidth(), GetScreenHeight())
            else ns.printf("  rect: none (no valid anchors, so it cannot draw)") end
            local p, depth = f:GetParent(), 0
            while p and depth < 12 do
                if not p:IsShown() then
                    ns.printf("  HIDDEN ANCESTOR: %s", tostring(p.GetName and p:GetName() or "<unnamed>"))
                    break
                end
                p, depth = p:GetParent(), depth + 1
            end
        end

    elseif cmd == "mouse" then
        -- What is drawing under the cursor? Every frame with mouse focus, its
        -- debug name, and its parent chain. Run it while hovering the thing.
        local foci = GetMouseFoci and GetMouseFoci() or {}
        if #foci == 0 then ns.printf("nothing under the cursor.") end
        for i, f in ipairs(foci) do
            local ok, name = pcall(f.GetDebugName, f)
            ns.printf("%d: %s  level=%s strata=%s", i, ok and name or "?",
                tostring(pcall(f.GetFrameLevel, f) and select(2, pcall(f.GetFrameLevel, f))),
                tostring(pcall(f.GetFrameStrata, f) and select(2, pcall(f.GetFrameStrata, f))))
            local p, depth = f:GetParent(), 0
            while p and depth < 8 do
                local ok2, pn = pcall(p.GetDebugName, p)
                ns.printf("   ^ %s", ok2 and pn or "?")
                p, depth = p:GetParent(), depth + 1
            end
        end
        -- Mouse-disabled frames never get focus, so also walk every visible
        -- frame whose rectangle contains the cursor (named ones only, capped).
        if EnumerateFrames then
            local cx, cy = GetCursorPosition()
            local n, f = 0, EnumerateFrames()
            ns.printf("visible named frames under the cursor:")
            while f and n < 60 do
                -- IsVisible can hand back a secret boolean; testing it throws, so test inside the pcall.
                local ok, hit = pcall(function()
                    if f:IsForbidden() or not f:IsVisible() then return false end
                    local s = f:GetEffectiveScale()
                    local l, b, w, h = f:GetRect()
                    return l and w and w > 0 and h > 0 and cx / s >= l and cx / s <= l + w and cy / s >= b and cy / s <= b + h
                end)
                if ok and hit then
                    n = n + 1
                    local okn, name = pcall(f.GetDebugName, f)
                    -- visible textures: what this frame actually paints (path/atlas or "color")
                    local tex = {}
                    pcall(function()
                        for j = 1, select("#", f:GetRegions()) do
                            local r = select(j, f:GetRegions())
                            if r and r:IsObjectType("Texture") and r:IsShown() and (r:GetAlpha() or 0) > 0 then
                                local t = (r.GetAtlas and r:GetAtlas()) or r:GetTexture()
                                tex[#tex + 1] = tostring(t or "color")
                            end
                        end
                    end)
                    ns.printf("  %s  level=%s strata=%s mouse=%s tex=%s", okn and name or "?",
                        tostring(f:GetFrameLevel()), tostring(f:GetFrameStrata()), tostring(f:IsMouseEnabled()),
                        #tex > 0 and table.concat(tex, ",", 1, math.min(#tex, 3)) or "-")
                end
                f = EnumerateFrames(f)
            end
        end

    elseif cmd == "cdm" then
        -- What Blizzard's Cooldown Manager thinks, category by category, and
        -- what is actually on screen in its viewers and EllesmereUI's bars.
        if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet) then
            ns.printf("C_CooldownViewer is not available on this client.")
            return
        end
        local okA, avail = pcall(C_CooldownViewer.IsCooldownViewerAvailable)
        ns.printf("IsCooldownViewerAvailable=%s  Enum.CooldownViewerCategory=%s",
            tostring(okA and avail), Enum and Enum.CooldownViewerCategory and "yes" or "no")
        local cats = (Enum and Enum.CooldownViewerCategory) or { Essential = 0, Utility = 1, TrackedBuff = 2, TrackedBar = 3 }
        for name, cat in pairs(cats) do
            if type(cat) == "number" then
                local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, cat, true)
                if ok and type(ids) == "table" then
                    local parts = {}
                    for _, id in ipairs(ids) do
                        local ok2, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, id)
                        local sname = ok2 and info and info.spellID and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(info.spellID) or "?"
                        local flags = ""
                        if ok2 and info then
                            if info.overrideSpellID then flags = flags .. " ovr:" .. tostring(info.overrideSpellID) end
                            if info.hasAura ~= nil then flags = flags .. " aura:" .. tostring(info.hasAura) end
                        end
                        parts[#parts + 1] = string.format("%s(%s%s)", tostring(sname), tostring(ok2 and info and info.spellID), flags)
                    end
                    ns.printf("  %s [%d]: %s", name, #ids, #parts > 0 and table.concat(parts, ", "):sub(1, 300) or "none")
                else
                    ns.printf("  %s: %s", name, tostring(ids))
                end
            end
        end
        for _, fname in ipairs({ "EssentialCooldownViewer", "UtilityCooldownViewer", "BuffIconCooldownViewer", "BuffBarCooldownViewer" }) do
            local f = _G[fname]
            if f then
                local kids, shownKids = 0, 0
                for _, c in ipairs({ f:GetChildren() }) do
                    kids = kids + 1
                    if c:IsShown() then shownKids = shownKids + 1 end
                end
                ns.printf("  %s: shown=%s children=%d shownChildren=%d", fname, tostring(f:IsShown()), kids, shownKids)
            end
        end
        for _, fname in ipairs({ "ECME_CDMBar_cooldowns", "ECME_CDMBar_utility", "ECME_CDMBar_buffs" }) do
            local f = _G[fname]
            if f then
                local kids, shownKids = 0, 0
                for _, c in ipairs({ f:GetChildren() }) do
                    kids = kids + 1
                    if c:IsShown() then shownKids = shownKids + 1 end
                end
                ns.printf("  %s: shown=%s size=%dx%d children=%d shownChildren=%d", fname, tostring(f:IsShown()),
                    f:GetWidth(), f:GetHeight(), kids, shownKids)
            end
        end
        local okS, secret = pcall(function() return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() end)
        ns.printf("  auras secret right now: %s  (in combat: %s)", tostring(okS and secret), tostring(InCombatLockdown()))
        -- Blizzard keys the Cooldown Manager's lists by specialization, so
        -- show exactly what the client believes about the character's spec.
        if C_SpecializationInfo then
            local S = C_SpecializationInfo
            local function try(fn, ...) if type(fn) ~= "function" then return "n/a" end local ok, a, b, c = pcall(fn, ...) if not ok then return "err" end return a, b, c end
            local spec = try(S.GetSpecialization)
            local id, sname = try(S.GetSpecializationInfo, type(spec) == "number" and spec or 1)
            ns.printf("  spec index=%s  specID=%s name=%s  group=%s  init=%s  specSelectionEnabled=%s",
                tostring(spec), tostring(id), tostring(sname), tostring(try(S.GetActiveSpecGroup)),
                tostring(try(S.IsInitialized)), tostring(try(S.IsSpecSelectionEnabled)))
            local _, class, classID = UnitClass("player")
            local n = try(S.GetNumSpecializationsForClassID, classID)
            local ids = {}
            for i = 1, (type(n) == "number" and n or 0) do
                local sid, sn = try(S.GetSpecializationInfoForClassID, classID, i)
                ids[#ids + 1] = tostring(sid) .. ":" .. tostring(sn)
            end
            ns.printf("  class %s (%s) has %s specs: %s", tostring(class), tostring(classID), tostring(n), table.concat(ids, ", "))
            local okT, cfg = pcall(function() return C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID() end)
            ns.printf("  active talent config: %s  level=%d", tostring(okT and cfg), UnitLevel("player"))
        end
        if C_CooldownViewer.GetLayoutData then
            local okL, layout = pcall(C_CooldownViewer.GetLayoutData)
            local n = 0
            if okL and type(layout) == "table" then for _ in pairs(layout) do n = n + 1 end end
            ns.printf("  Blizzard CDM layout data: %s (%d top-level entries)", tostring(okL and type(layout)), n)
        end

    elseif cmd == "bagtest" then
        local before = EUI_Bags and EUI_Bags:IsShown()
        local ok, err = pcall(ToggleAllBags)
        ns.printf("ToggleAllBags ok=%s err=%s | EUI_Bags shown %s -> %s", tostring(ok), tostring(err),
            tostring(before), tostring(EUI_Bags and EUI_Bags:IsShown()))

    elseif cmd == "traits" then
        if ns.DumpTraits then ns.try("traits", ns.DumpTraits) end
        ns.printf("%d trait configs recorded (class talents, Legacy trees).", count(db.traits))

    elseif cmd == "pos" then
        ns.printf("%s", ns.PosString(ns.Pos()))

    elseif cmd == "errors" then
        if #db.errors == 0 then ns.printf("no collector errors.") end
        for i = math.max(1, #db.errors - 15), #db.errors do
            local e = db.errors[i]
            ns.printf("  [%s] %s -- %s", date("%m-%d %H:%M", e.t), e.domain, e.err)
        end
        ns.printf("%d Lua errors captured from all addons.", #db.luaErrors)

    elseif cmd == "wipe" then
        ForeverBeaconDB = nil
        ns.DB()
        ns.printf("database cleared. /reload to start clean.")

    else
        ns.printf("npcs %d | objects %d | items %d | spells %d | quests %d | vendors %d | trainers %d | zones %d",
            count(db.npcs), count(db.objects), count(db.items), count(db.spells),
            count(db.quests), count(db.vendors), count(db.trainers), count(db.zones))
        ns.printf("loot events %d | quest events %d | objective hits %d | events seen %d | notes %d | errors %d",
            #db.lootEvents, #db.questEvents, #db.objProgress, count(db.events), #db.notes, #db.errors)
        ns.printf("payload: %s bytes. /fb help lists every command.", db.payloadBytes or "not yet encoded")
    end
end

-- /fb help -----------------------------------------------------------------
-- Kept out of the status branch so it stays readable. Also covers the
-- !!ForeverCompat commands, since the two addons travel together.
local HELP = {
    { "|cffffd100Forever Beacon|r" },
    { "/fb",                 "status: counts per domain and payload size" },
    { "/fb help",            "this list" },
    { "/fb flush",           "encode the payload now, then /reload to write it to disk" },
    { "/fb note <text>",     "timestamped, positioned annotation (campfire slots, Legacy costs...)" },
    { "/fb bugs [n]",        "print this session's errors from BugGrabber, newest first (default 8)" },
    { "/fb errors",          "collector failures (which API was missing) and Lua error count" },
    { "/fb frame <Name>",    "why can't I see this frame: shown/alpha/scale/size/anchors/hidden ancestor" },
    { "/fb mouse",           "list every frame under the cursor with its parent chain" },
    { "/fb bagtest",         "call ToggleAllBags under pcall and report what happened" },
    { "/fb cdm",             "what Blizzard's Cooldown Manager tracks per category, and what the viewers/EUI bars hold" },
    { "/fb probe",           "re-run the API probe (after opening a new Blizzard panel)" },
    { "/fb traits",          "dump class talents and Legacy trees (open the Legacy panel first)" },
    { "/fb frames",          "record visible frames named Legacy/Camp/Transmog/Ruleset/Layer" },
    { "/fb pos",             "print current map position" },
    { "/fb wipe",            "clear the whole database" },
    { "|cffffd100Forever Compat (action bars without dragging)|r" },
    { "/place <spell>",      "hover a bar button first; also /place <slot> <spell>, macro:<name>, item:<name>" },
    { "/unplace [slot]",     "empty the hovered (or given) slot" },
    { "/swapslot <a> <b>",   "swap two slots" },
    { "/slot",               "hovered button's slot number and content" },
    { "|cffffd100Other|r" },
    { "/bugsack show",       "open the BugSack window (plain /bugsack opens its settings)" },
    { "/reload",             "type it yourself: addons cannot trigger a reload on this client" },
}

local function printHelp()
    for _, row in ipairs(HELP) do
        if row[2] then
            print(string.format("  |cffd2621f%-22s|r %s", row[1], row[2]))
        else
            print(row[1])
        end
    end
end

local oldHandler = SlashCmdList.FOREVERBEACON
SlashCmdList.FOREVERBEACON = function(msg)
    local cmd = strlower(strtrim(msg or ""))
    if cmd == "help" or cmd == "?" or cmd == "commands" then
        printHelp()
        return
    end
    oldHandler(msg)
end
