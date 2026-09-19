-- FB_Datamine.lua -- ask the client and the server for quests you have not played
-- Author: Thunderz
--
-- WHY: on this client quest data is server-side. The shipped tables have no
-- objectives and only a handful of quest areas. A quest's title, level and
-- objectives reach this machine only when the client ASKS the server about that
-- quest, and the full record (including objective target IDs, which no addon API
-- exposes) then lands in Cache\WDB\enUS\questcache.wdb for offline decoding.
--
-- Two tools:
--   /fb zonequests [uiMapID]   what quests does the client say are on offer on this
--                              map? Uses the quest-line API that feeds Blizzard's own
--                              map pins: quest ID, name and map position for quests
--                              you have NOT visited, then every quest in each chain.
--   /fb sweep <from> <to>      ask the server for every quest ID in a range, slowly.
--                              Records what comes back; fills the WDB cache.
--   /fb sweep stop | status
--
-- Results go into the normal quest catalog (db.quests) marked src = "zone" or
-- "sweep", so fb_extract.py and the Questie overlay pick them up unchanged. Exit
-- the game normally afterwards: the client writes the WDB cache at exit, and the
-- sync task archives it.

local ADDON, ns = ...

local function questRec(questID)
    local db = ns.DB()
    local rec = db.quests[questID]
    if not rec then
        rec = { id = questID, first = time() }
        db.quests[questID] = rec
    end
    return rec
end

-- Whatever the client now knows about a quest, written into its record.
local function absorb(questID, src)
    local rec = questRec(questID)
    rec.src = rec.src or src
    if C_QuestLog.GetTitleForQuestID then
        local ok, title = pcall(C_QuestLog.GetTitleForQuestID, questID)
        if ok and type(title) == "string" and title ~= "" then rec.title = title end
    end
    if C_QuestLog.GetQuestDifficultyLevel then
        local ok, lvl = pcall(C_QuestLog.GetQuestDifficultyLevel, questID)
        if ok and type(lvl) == "number" and lvl > 0 then rec.level = lvl rec.levelSource = "quest" end
    end
    if C_QuestLog.GetQuestObjectives and not (rec.objectives and #rec.objectives > 0) then
        local ok, objs = pcall(C_QuestLog.GetQuestObjectives, questID)
        if ok and type(objs) == "table" and #objs > 0 then
            rec.objectives = {}
            for _, o in ipairs(objs) do
                rec.objectives[#rec.objectives + 1] = { text = o.text, type = o.type, needed = o.numRequired }
            end
        end
    end
    if GetQuestUiMapID then
        local ok, map = pcall(GetQuestUiMapID, questID)
        if ok and type(map) == "number" and map > 0 then rec.uiMap = map end
    end
    return rec
end

-- The server's reply event also fires during ordinary play and for requests made
-- by other addons, so only replies to OUR requests are recorded.
local asked = {}
local function ask(questID, src)
    asked[questID] = src
    pcall(C_QuestLog.RequestLoadQuestByID, questID)
end

-- Zone quests -------------------------------------------------------------------------

local pendingMap

local function readZone(mapID)
    local ok, lines = pcall(C_QuestLine.GetAvailableQuestLines, mapID)
    if not ok or type(lines) ~= "table" then
        ns.printf("zonequests: the quest-line API gave nothing for map %d (%s).", mapID, tostring(lines))
        return
    end
    local chains, extra = {}, 0
    for _, l in ipairs(lines) do
        local rec = absorb(l.questID, "zone")
        rec.title = rec.title or l.questName
        rec.offer = { map = mapID, x = l.x, y = l.y, line = l.questLineID, lineName = l.questLineName,
                      hidden = l.isHidden or nil, daily = l.isDaily or nil }
        chains[l.questLineID] = l.questLineName
        if C_QuestLog.RequestLoadQuestByID then ask(l.questID, "zone") end
    end
    for lineID, lineName in pairs(chains) do            -- every quest in each chain, not just the next one
        local ok2, ids = pcall(C_QuestLine.GetQuestLineQuests, lineID)
        if ok2 and type(ids) == "table" then
            for order, questID in ipairs(ids) do
                local rec = questRec(questID)
                rec.src = rec.src or "zone"
                rec.chain = { line = lineID, lineName = lineName, order = order, of = #ids, map = mapID }
                if not rec.title and C_QuestLog.RequestLoadQuestByID then
                    ask(questID, "zone")
                    extra = extra + 1
                end
            end
        end
    end
    if C_QuestLine.GetForceVisibleQuests then
        local ok3, ids = pcall(C_QuestLine.GetForceVisibleQuests, mapID)
        if ok3 and type(ids) == "table" then
            for _, questID in ipairs(ids) do
                questRec(questID).src = questRec(questID).src or "zone"
                if C_QuestLog.RequestLoadQuestByID then ask(questID, "zone") end
            end
        end
    end
    local nChains = 0
    for _ in pairs(chains) do nChains = nChains + 1 end
    ns.printf("zonequests map %d: %d quests on offer in %d chains; asked the server about %d more chain quests.",
        mapID, #lines, nChains, extra)
    for i = 1, math.min(#lines, 8) do
        local l = lines[i]
        ns.printf("   %d  %s  @ %.1f, %.1f  [%s]", l.questID, tostring(l.questName), (l.x or 0) * 100, (l.y or 0) * 100, tostring(l.questLineName))
    end
    if #lines == 0 then
        ns.printf("   nothing on offer here for this character. That can be real (all done, wrong level or faction) or it can mean the API is not populated on this client.")
    end
end

function ns.ZoneQuests(arg)
    if not (C_QuestLine and C_QuestLine.GetAvailableQuestLines) then ns.printf("zonequests: no quest-line API on this client.") return end
    local mapID = tonumber(arg)
    if not mapID and C_Map and C_Map.GetBestMapForUnit then mapID = C_Map.GetBestMapForUnit("player") end
    if not mapID then ns.printf("usage: /fb zonequests [uiMapID]   (Tirisfal Glades 1420, Silverpine Forest 1421)") return end
    pendingMap = mapID
    if C_QuestLine.RequestQuestLinesForMap then pcall(C_QuestLine.RequestQuestLinesForMap, mapID) end
    readZone(mapID)                                       -- whatever is cached now ...
    C_Timer.After(3, function()                           -- ... and again once the server has answered
        if pendingMap == mapID then pendingMap = nil readZone(mapID) end
    end)
end

ns.On("QUESTLINE_UPDATE", function()
    if pendingMap then
        local mapID = pendingMap
        pendingMap = nil
        readZone(mapID)
    end
end)

-- ID sweep ----------------------------------------------------------------------------

local sweep        -- { from, to, next, asked, found, rate, started }
local RATE = 10    -- requests per second: deliberately gentle on the server

local function sweepTick()
    if not sweep then return end
    for _ = 1, sweep.rate do
        if sweep.next > sweep.to then
            ns.printf("sweep %d-%d finished: %d asked, %d real quests. Exit the game normally so the WDB cache is written.",
                sweep.from, sweep.to, sweep.asked, sweep.found)
            sweep = nil
            return
        end
        ask(sweep.next, "sweep")
        sweep.asked = sweep.asked + 1
        sweep.next = sweep.next + 1
    end
    if sweep.asked % 1000 < sweep.rate then
        ns.printf("sweep: at %d of %d-%d, %d real quests so far.", sweep.next, sweep.from, sweep.to, sweep.found)
    end
    C_Timer.After(1, sweepTick)
end

ns.On("QUEST_DATA_LOAD_RESULT", function(questID, success)
    if type(questID) ~= "number" then return end
    local src = asked[questID]
    if not src then return end                      -- not a request of ours
    asked[questID] = nil
    if not success then return end                  -- no such quest: nothing to record
    local known = ns.DB().quests[questID]
    local hadTitle = known and known.title          -- read before absorb() fills the same record in
    local rec = absorb(questID, src)
    if sweep and questID >= sweep.from and questID <= sweep.to and rec.title and not hadTitle then
        sweep.found = sweep.found + 1
    end
end)

function ns.Sweep(arg)
    arg = strtrim(arg or "")
    if arg == "stop" then
        if sweep then ns.printf("sweep stopped at %d (%d real quests).", sweep.next, sweep.found) end
        sweep = nil
        return
    end
    if arg == "" or arg == "status" then
        if sweep then ns.printf("sweep running: at %d of %d-%d, %d real quests.", sweep.next, sweep.from, sweep.to, sweep.found)
        else ns.printf("usage: /fb sweep <fromID> <toID>   |   /fb sweep stop.  About %d IDs a second, so 10,000 IDs takes ~%d minutes.", RATE, math.ceil(10000 / RATE / 60)) end
        return
    end
    if not (C_QuestLog and C_QuestLog.RequestLoadQuestByID) then ns.printf("sweep: this client cannot request quests by ID.") return end
    local from, to = arg:match("^(%d+)%s+(%d+)$")
    from, to = tonumber(from), tonumber(to)
    if not from or not to or to < from then ns.printf("usage: /fb sweep <fromID> <toID>") return end
    if to - from > 30000 then ns.printf("sweep: that is %d IDs. Keep a sweep to 30,000 or fewer.", to - from + 1) return end
    if sweep then ns.printf("a sweep is already running; /fb sweep stop first.") return end
    sweep = { from = from, to = to, next = from, asked = 0, found = 0, rate = RATE }
    ns.printf("sweep %d-%d started: about %d minutes. Play normally; /fb sweep status or /fb sweep stop.",
        from, to, math.ceil((to - from + 1) / RATE / 60))
    sweepTick()
end
