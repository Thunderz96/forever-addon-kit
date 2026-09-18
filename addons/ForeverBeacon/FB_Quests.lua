-- FB_Quests.lua -- quest givers, text, rewards, turn-ins, objective locations
-- Author: Thunderz
--
-- The 1,000 new quests have no public data yet. Every accept, turn-in and
-- objective tick is logged with a position; the quest text and rewards are
-- read off the quest frame while it is open.

local ADDON, ns = ...

local function questRec(questID, title)
    local db = ns.DB()
    local rec = db.quests[questID]
    if not rec then
        rec = { id = questID, title = title, first = time() }
        db.quests[questID] = rec
    end
    if title and title ~= "" then rec.title = title end
    return rec
end

local function npcFromFrame()
    local unit = UnitExists("questnpc") and "questnpc" or "npc"
    local guid = UnitGUID(unit)
    local kind, id = ns.ParseGUID(guid)
    return kind, id, UnitName(unit)
end

local function logEvent(kind, questID, extra)
    local db = ns.DB()
    local rec = { t = time(), char = ns.CharKey(), kind = kind, questID = questID, pos = ns.Pos() }
    if extra then for k, v in pairs(extra) do rec[k] = v end end
    ns.push(db.questEvents, ns.CAP.questEvents, rec)
end

local function rewards()
    local out = { fixed = {}, choice = {} }
    local ok, xp = pcall(GetRewardXP)
    if ok then out.xp = xp end
    local ok2, money = pcall(GetRewardMoney)
    if ok2 then out.money = money end
    if GetNumQuestRewards then
        for i = 1, GetNumQuestRewards() do
            local name, _, num = GetQuestItemInfo("reward", i)
            out.fixed[#out.fixed + 1] = { name = name, qty = num, link = GetQuestItemLink("reward", i) }
        end
    end
    if GetNumQuestChoices then
        for i = 1, GetNumQuestChoices() do
            local name, _, num = GetQuestItemInfo("choice", i)
            out.choice[#out.choice + 1] = { name = name, qty = num, link = GetQuestItemLink("choice", i) }
        end
    end
    if GetNumRewardSpells then
        local ok3, n = pcall(GetNumRewardSpells)
        if ok3 and n and n > 0 then out.spells = n end
    end
    if GetRewardTitle then
        local ok4, title = pcall(GetRewardTitle)
        if ok4 and title and title ~= "" then out.title = title end
    end
    if GetNumQuestLogRewardFactions then
        local ok5, n = pcall(GetNumQuestLogRewardFactions)
        if ok5 and n and n > 0 then out.reputations = n end
    end
    return out
end

-- Quest offered (QUEST_DETAIL): giver, text, objectives, rewards on offer.
ns.On("QUEST_DETAIL", function()
    local questID = GetQuestID()
    if not questID or questID == 0 then return end
    local rec = questRec(questID, GetTitleText())
    local kind, id, name = npcFromFrame()
    rec.giver = { kind = kind, id = id, name = name, pos = ns.Pos() }
    rec.text = GetQuestText()
    rec.objectiveText = GetObjectiveText()
    rec.offered = rewards()
    if QuestIsDaily and QuestIsDaily() then rec.daily = true end
    if QuestIsWeekly and QuestIsWeekly() then rec.weekly = true end
    logEvent("offered", questID, { npc = id })
end)

ns.On("QUEST_ACCEPTED", function(a, b)
    -- Classic passes (questLogIndex, questID); modern clients pass (questID).
    local questID = type(b) == "number" and b or a
    if not questID then return end
    local title
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local ok, t = pcall(C_QuestLog.GetTitleForQuestID, questID)
        if ok then title = t end
    end
    local rec = questRec(questID, title)
    rec.accepted = (rec.accepted or 0) + 1
    rec.level = rec.level or UnitLevel("player")
    if C_QuestLog and C_QuestLog.GetQuestObjectives then
        local ok, objs = pcall(C_QuestLog.GetQuestObjectives, questID)
        if ok and type(objs) == "table" then
            rec.objectives = {}
            for _, o in ipairs(objs) do
                rec.objectives[#rec.objectives + 1] = { text = o.text, type = o.type, needed = o.numRequired }
            end
        end
    end
    logEvent("accepted", questID)
end)

-- Turn-in window (QUEST_COMPLETE): who takes it and what it actually pays.
ns.On("QUEST_COMPLETE", function()
    local questID = GetQuestID()
    if not questID or questID == 0 then return end
    local rec = questRec(questID, GetTitleText())
    local kind, id, name = npcFromFrame()
    rec.ender = { kind = kind, id = id, name = name, pos = ns.Pos() }
    rec.completeText = GetRewardText and GetRewardText() or nil
    rec.rewards = rewards()
end)

ns.On("QUEST_PROGRESS", function()
    local questID = GetQuestID()
    if not questID or questID == 0 then return end
    local rec = questRec(questID, GetTitleText())
    rec.progressText = GetProgressText and GetProgressText() or nil
    if GetNumQuestItems then
        rec.required = {}
        for i = 1, GetNumQuestItems() do
            local name, _, num = GetQuestItemInfo("required", i)
            rec.required[#rec.required + 1] = { name = name, qty = num, link = GetQuestItemLink("required", i) }
        end
    end
end)

ns.On("QUEST_TURNED_IN", function(questID, xp, money)
    if not questID then return end
    local rec = questRec(questID)
    rec.turnedIn = (rec.turnedIn or 0) + 1
    rec.xpEarned = xp
    rec.moneyEarned = money
    rec.turnInLevel = UnitLevel("player")
    logEvent("turnedin", questID, { xp = xp, money = money })
end)

-- Objective progress with a position: where the kills, loot and clicks
-- actually happened. QUEST_WATCH_UPDATE gives the quest, UI_INFO_MESSAGE the
-- "Boars slain: 3/10" text.
ns.On("QUEST_WATCH_UPDATE", function(a)
    local questID = type(a) == "number" and a or nil
    if questID and questID > 100000 then questID = nil end -- older clients pass a log index
    local db = ns.DB()
    local p = ns.Pos()
    p.t = time()
    p.questID = questID
    ns.push(db.objProgress, ns.CAP.objProgress, p)
end)

ns.On("UI_INFO_MESSAGE", function(_, text)
    if type(text) ~= "string" or text == "" then return end
    local db = ns.DB()
    local p = ns.Pos()
    p.t = time()
    p.text = text
    ns.push(db.infoMsgs, ns.CAP.infoMsgs, p)
end)

-- Quest log dump at login: titles and levels for everything currently held,
-- which fills in quests accepted before the addon was installed.
local function dumpQuestLog()
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        for i = 1, C_QuestLog.GetNumQuestLogEntries() do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and info.questID then
                local rec = questRec(info.questID, info.title)
                rec.level = info.level
                rec.header = info.campaignID and ("campaign:" .. info.campaignID) or rec.header
            end
        end
    elseif GetNumQuestLogEntries and GetQuestLogTitle then
        local header
        for i = 1, GetNumQuestLogEntries() do
            local title, level, _, isHeader, _, isComplete, frequency, questID = GetQuestLogTitle(i)
            if isHeader then
                header = title
            elseif questID and questID > 0 then
                local rec = questRec(questID, title)
                rec.level = level
                rec.header = header
                rec.frequency = frequency
            end
        end
    end
end

ns.On("PLAYER_LOGIN", function() C_Timer.After(12, function() ns.try("questlog", dumpQuestLog) end) end)
