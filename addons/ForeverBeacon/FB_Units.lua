-- FB_Units.lua -- creatures, vendors, trainers, gossip
-- Author: Thunderz

local ADDON, ns = ...

-- Creature catalog ----------------------------------------------------------

local function unitLevel(unit)
    local lvl = UnitLevel(unit)
    if lvl == -1 then return "??" end
    return lvl
end

-- Records the creature behind a unit token. Called on mouseover and target
-- changes, so the same mob is merged and its level range and positions grow.
function ns.RecordUnit(unit, source)
    if not UnitExists(unit) or UnitIsPlayer(unit) then return end
    local guid = UnitGUID(unit)
    local kind, npcID = ns.ParseGUID(guid)
    if not npcID or (kind ~= "Creature" and kind ~= "Vehicle") then return end

    local db = ns.DB()
    local rec = db.npcs[npcID]
    if not rec then
        rec = { id = npcID, name = UnitName(unit), first = time(), n = 0, levels = {}, sources = {} }
        db.npcs[npcID] = rec
    end
    rec.n = rec.n + 1
    rec.last = time()
    rec.sources[source] = (rec.sources[source] or 0) + 1

    local lvl = unitLevel(unit)
    rec.levels[tostring(lvl)] = (rec.levels[tostring(lvl)] or 0) + 1
    rec.classification = UnitClassification(unit)
    rec.creatureType   = UnitCreatureType(unit)
    rec.creatureFamily = UnitCreatureFamily and UnitCreatureFamily(unit) or nil
    rec.reaction       = UnitReaction("player", unit)
    rec.isTapDenied    = UnitIsTapDenied and UnitIsTapDenied(unit) or nil
    rec.powerType      = UnitPowerType(unit)
    local hp = ns.Num(UnitHealthMax(unit))
    if hp and hp > 0 then
        rec.hpMax = math.max(rec.hpMax or 0, hp)
        rec.hpMin = math.min(rec.hpMin or hp, hp)
    elseif hp == nil then
        rec.hpSecret = true
    end
    local mana = ns.Num(UnitPowerMax(unit))
    if mana and mana > 0 then rec.powerMax = math.max(rec.powerMax or 0, mana) end
    if UnitIsPVP(unit) then rec.pvp = true end
    if UnitPlayerControlled(unit) then rec.playerControlled = true end
    if UnitFactionGroup then
        local fac = UnitFactionGroup(unit)
        if fac then rec.faction = fac end
    end
    ns.AddSighting(rec)
    return rec
end

ns.On("UPDATE_MOUSEOVER_UNIT", function() ns.RecordUnit("mouseover", "mouseover") end)
ns.On("PLAYER_TARGET_CHANGED", function() ns.RecordUnit("target", "target") end)

-- Unit tooltips carry the "<NPC title>" line and quest-giver text.
function ns.OnUnitTooltip(tt)
    local _, unit = tt:GetUnit()
    if not unit or not UnitExists(unit) or UnitIsPlayer(unit) then return end
    local _, npcID = ns.ParseGUID(UnitGUID(unit))
    if not npcID then return end
    local rec = ns.RecordUnit(unit, "tooltip")
    if not rec then return end
    local lines = ns.TooltipLines(tt)
    if lines[2] and not lines[2]:find("^Level ") then rec.title = lines[2] end
    rec.tooltip = lines
end

-- Vendors -----------------------------------------------------------------

local function npcFromWindow()
    local guid = UnitGUID("npc")
    local _, npcID = ns.ParseGUID(guid)
    return npcID, UnitName("npc")
end

local function merchantCost(i)
    if not GetMerchantItemCostInfo then return nil end
    local ok, itemCount, honor, arena = pcall(GetMerchantItemCostInfo, i)
    if not ok or (itemCount or 0) == 0 and (honor or 0) == 0 then return nil end
    local cost = { honor = honor, arena = arena, items = {} }
    for j = 1, itemCount or 0 do
        local ok2, _, value, link, name = pcall(GetMerchantItemCostItem, i, j)
        if ok2 then cost.items[#cost.items + 1] = { link = link, name = name, value = value } end
    end
    return cost
end

ns.On("MERCHANT_SHOW", function()
    if not GetMerchantNumItems then return end
    local npcID, npcName = npcFromWindow()
    if not npcID then return end
    local db = ns.DB()
    ns.RecordUnit("npc", "merchant")
    local rec = { npc = npcID, name = npcName, t = time(), pos = ns.Pos(), items = {} }
    for i = 1, GetMerchantNumItems() do
        local name, price, quantity, numAvailable, isPurchasable, isUsable, extendedCost, _
        if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
            -- 11.0+ / Forever 1.60: the global is gone, the namespace returns a table.
            local info = C_MerchantFrame.GetItemInfo(i) or {}
            name, price, quantity = info.name, info.price, info.stackCount
            numAvailable, isPurchasable = info.numAvailable, info.isPurchasable
            isUsable, extendedCost = info.isUsable, info.hasExtendedCost
        else
            name, _, price, quantity, numAvailable, isPurchasable, isUsable, extendedCost = GetMerchantItemInfo(i)
        end
        local link = GetMerchantItemLink(i)
        local itemID = link and tonumber(link:match("item:(%d+)"))
        rec.items[#rec.items + 1] = {
            itemID = itemID, name = name, link = link, price = price, stack = quantity,
            available = numAvailable, purchasable = isPurchasable and true or false,
            usable = isUsable and true or false, extended = extendedCost and merchantCost(i) or nil,
        }
    end
    if CanMerchantRepair and CanMerchantRepair() then rec.repair = true end
    db.vendors[npcID] = rec
end)

-- Trainers ----------------------------------------------------------------

ns.On("TRAINER_SHOW", function()
    if not GetNumTrainerServices then return end
    local npcID, npcName = npcFromWindow()
    if not npcID then return end
    local db = ns.DB()
    ns.RecordUnit("npc", "trainer")
    local rec = { npc = npcID, name = npcName, t = time(), pos = ns.Pos(), services = {} }
    if GetTrainerServiceTypeFilter then
        rec.filters = { available = GetTrainerServiceTypeFilter("available"),
                        unavailable = GetTrainerServiceTypeFilter("unavailable"),
                        used = GetTrainerServiceTypeFilter("used") }
    end
    for i = 1, GetNumTrainerServices() do
        local name, rank, category = GetTrainerServiceInfo(i)
        if category ~= "header" then
            local svc = { name = name, rank = rank, category = category }
            local ok, cost = pcall(GetTrainerServiceCost, i)
            if ok then svc.cost = cost end
            local ok2, lvl = pcall(GetTrainerServiceLevelReq, i)
            if ok2 then svc.level = lvl end
            if GetTrainerServiceSkillReq then
                local ok3, skill, skillLvl = pcall(GetTrainerServiceSkillReq, i)
                if ok3 and skill then svc.skill = skill; svc.skillLevel = skillLvl end
            end
            if GetTrainerServiceItemLink then
                local ok4, link = pcall(GetTrainerServiceItemLink, i)
                if ok4 then svc.link = link end
            end
            rec.services[#rec.services + 1] = svc
        end
    end
    db.trainers[npcID] = rec
end)

-- Gossip ------------------------------------------------------------------

ns.On("GOSSIP_SHOW", function()
    local npcID, npcName = npcFromWindow()
    if not npcID then return end
    local db = ns.DB()
    ns.RecordUnit("npc", "gossip")
    local rec = { npc = npcID, name = npcName, t = time(), pos = ns.Pos(), options = {}, quests = {} }
    if C_GossipInfo and C_GossipInfo.GetText then
        local ok, text = pcall(C_GossipInfo.GetText)
        if ok then rec.text = text end
    elseif GetGossipText then
        rec.text = GetGossipText()
    end
    if C_GossipInfo and C_GossipInfo.GetOptions then
        local ok, opts = pcall(C_GossipInfo.GetOptions)
        if ok and type(opts) == "table" then
            for _, o in ipairs(opts) do
                rec.options[#rec.options + 1] = { name = o.name, icon = o.icon, id = o.gossipOptionID, type = o.type }
            end
        end
    elseif GetGossipOptions then
        local opts = { GetGossipOptions() }
        for i = 1, #opts, 2 do
            rec.options[#rec.options + 1] = { name = opts[i], type = opts[i + 1] }
        end
    end
    if C_GossipInfo and C_GossipInfo.GetAvailableQuests then
        local ok, qs = pcall(C_GossipInfo.GetAvailableQuests)
        if ok and type(qs) == "table" then
            for _, q in ipairs(qs) do
                rec.quests[#rec.quests + 1] = { id = q.questID, title = q.title, level = q.questLevel, available = true }
            end
        end
        local ok2, qs2 = pcall(C_GossipInfo.GetActiveQuests)
        if ok2 and type(qs2) == "table" then
            for _, q in ipairs(qs2) do
                rec.quests[#rec.quests + 1] = { id = q.questID, title = q.title, level = q.questLevel, active = true }
            end
        end
    end
    db.gossip[npcID] = rec
end)
