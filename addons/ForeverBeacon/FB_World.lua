-- FB_World.lua -- maps, zones, subzones, game objects, taxi nodes
-- Author: Thunderz

local ADDON, ns = ...

-- Maps: walk the parent chain so the new zones' place in the map tree is
-- recorded the first time we stand in them.
local function recordMap(mapID)
    if not mapID or not (C_Map and C_Map.GetMapInfo) then return end
    local db = ns.DB()
    local depth = 0
    while mapID and not db.maps[mapID] and depth < 10 do
        local info = C_Map.GetMapInfo(mapID)
        if not info then break end
        db.maps[mapID] = { name = info.name, type = info.mapType, parent = info.parentMapID }
        mapID = info.parentMapID
        depth = depth + 1
    end
end

local lastZoneKey

local function onZone()
    local db = ns.DB()
    local p = ns.Pos()
    recordMap(p.map)

    local key = table.concat({ tostring(p.map or "?"), p.zone or "?", p.sub or "" }, "|")
    local rec = db.zones[key]
    if not rec then
        rec = { map = p.map, zone = p.zone, sub = p.sub, first = time(), n = 0 }
        local name, instType, diffID, diffName, maxPlayers, _, _, instMapID = GetInstanceInfo()
        rec.instance = { name = name, type = instType, difficulty = diffID,
                         difficultyName = diffName, maxPlayers = maxPlayers, mapID = instMapID }
        if p.x then rec.enterX, rec.enterY = p.x, p.y end
        db.zones[key] = rec
    end
    rec.n = rec.n + 1
    rec.last = time()

    if key ~= lastZoneKey then
        lastZoneKey = key
        p.t = time()
        p.char = ns.CharKey()
        ns.push(db.zoneVisits, ns.CAP.zoneVisits, p)
    end
end

ns.On("ZONE_CHANGED_NEW_AREA", onZone)
ns.On("ZONE_CHANGED", onZone)
ns.On("ZONE_CHANGED_INDOORS", onZone)
ns.On("PLAYER_ENTERING_WORLD", onZone)

-- Game objects: herbs, ore, chests, campfires, quest objects. The tooltip is
-- the only general handle on them: when GameTooltip shows with no unit, item
-- or spell behind it and the mouse is over the world, line one is the object
-- name. Retail-style tooltip data can also carry the object's GUID.
function ns.RecordObject(name, objectID, source)
    if not name or name == "" then return end
    local db = ns.DB()
    local key = objectID and ("id:" .. objectID) or ("name:" .. name)
    local rec = db.objects[key]
    if not rec then
        rec = { name = name, objectID = objectID, first = time(), n = 0, sources = {} }
        db.objects[key] = rec
    end
    rec.n = rec.n + 1
    rec.last = time()
    rec.sources[source] = (rec.sources[source] or 0) + 1
    ns.AddSighting(rec)
    return rec
end

local function tooltipObjectGUID(tt)
    if type(tt.GetPrimaryTooltipData) ~= "function" then return nil end
    local ok, data = pcall(tt.GetPrimaryTooltipData, tt)
    if ok and type(data) == "table" and data.guid then
        local kind, id = ns.ParseGUID(data.guid)
        if kind == "GameObject" then return id end
    end
    return nil
end

local lastObjectSeen = {}

local function onTooltipShow(tt)
    if tt ~= GameTooltip then return end
    if UnitExists("mouseover") then return end
    local _, itemLink = tt:GetItem()
    if itemLink then return end
    local _, spellID = tt:GetSpell()
    if spellID then return end
    if tt:GetOwner() ~= UIParent and tt:GetOwner() ~= WorldFrame then return end

    local lines = ns.TooltipLines(tt)
    local name = lines[1]
    if not name then return end
    local now = GetTime()
    if lastObjectSeen[name] and now - lastObjectSeen[name] < 2 then return end
    lastObjectSeen[name] = now

    local objectID = tooltipObjectGUID(tt)
    local rec = ns.RecordObject(name, objectID, "tooltip")
    if rec and #lines > 1 then rec.tooltip = lines end
end

GameTooltip:HookScript("OnShow", function(tt)
    local ok, e = pcall(onTooltipShow, tt)
    if not ok then ns.err("object.tooltip", e) end
end)

-- Taxi map: node names, costs and which nodes connect from here.
ns.On("TAXIMAP_OPENED", function()
    if not NumTaxiNodes then return end
    local db = ns.DB()
    local current
    for i = 1, NumTaxiNodes() do
        if TaxiNodeGetType(i) == "CURRENT" then current = TaxiNodeName(i) end
    end
    local npcGUID = UnitGUID("npc")
    local _, npcID = ns.ParseGUID(npcGUID)
    local rec = db.taxi[current or "?"] or { first = time(), links = {} }
    rec.npc = npcID
    rec.npcName = UnitName("npc")
    rec.pos = ns.Pos()
    rec.last = time()
    for i = 1, NumTaxiNodes() do
        local kind = TaxiNodeGetType(i)
        if kind == "REACHABLE" then
            local cost = TaxiNodeCost and TaxiNodeCost(i) or nil
            rec.links[TaxiNodeName(i)] = { cost = cost }
        elseif kind == "DISTANT" then
            rec.links[TaxiNodeName(i)] = rec.links[TaxiNodeName(i)] or { distant = true }
        end
    end
    db.taxi[current or "?"] = rec
end)
