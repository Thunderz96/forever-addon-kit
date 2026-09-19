-- FB_Items.lua -- item tooltips and loot
-- Author: Thunderz
--
-- Items are catalogued from tooltips (the only way to read the new stat and
-- trinket text) and loot is logged per source so drop rates can be worked out
-- later. Tooltip hooking differs between the Classic-style client and the
-- 10.0+ TooltipDataProcessor API; both are wired and whichever exists wins.

local ADDON, ns = ...

-- Item catalog -------------------------------------------------------------

local function itemInfo(link)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getInfo then return nil end
    local ok, name, _, quality, ilvl, minLevel, class, subclass, stack, equipLoc, icon,
          sellPrice, classID, subclassID, bindType, expansionID = pcall(getInfo, link)
    if not ok then return nil end
    return { name = name, quality = quality, ilvl = ilvl, minLevel = minLevel, class = class,
             subclass = subclass, stack = stack, equipLoc = equipLoc, sellPrice = sellPrice,
             classID = classID, subclassID = subclassID, bindType = bindType, expansion = expansionID }
end

function ns.RecordItem(link, tt)
    if not link then return end
    local itemID = tonumber(link:match("item:(%d+)"))
    if not itemID then return end
    local db = ns.DB()
    local rec = db.items[itemID]
    if not rec then
        rec = { id = itemID, first = time(), n = 0 }
        db.items[itemID] = rec
    end
    rec.n = rec.n + 1
    rec.last = time()
    rec.link = link
    if not rec.info or not rec.info.name then rec.info = itemInfo(link) end
    if tt then
        local lines = ns.TooltipLines(tt)
        if #lines > 0 and (not rec.tooltip or #lines > #rec.tooltip) then
            rec.tooltip = lines
        end
    end
    return rec
end

function ns.OnItemTooltip(tt)
    local _, link = tt:GetItem()
    if link then ns.RecordItem(link, tt) end
end

-- Tooltip wiring -------------------------------------------------------------

local function wireTooltips()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        local T = Enum.TooltipDataType
        local function guard(fn)
            return function(tt)
                if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
                local ok, e = pcall(fn, tt)
                if not ok then ns.err("tooltip", e) end
            end
        end
        TooltipDataProcessor.AddTooltipPostCall(T.Item,  guard(ns.OnItemTooltip))
        TooltipDataProcessor.AddTooltipPostCall(T.Unit,  guard(ns.OnUnitTooltip))
        TooltipDataProcessor.AddTooltipPostCall(T.Spell, guard(ns.OnSpellTooltip))
        ns.DB().probe.tooltipMode = "TooltipDataProcessor"
    else
        local function guard(fn)
            return function(tt)
                local ok, e = pcall(fn, tt)
                if not ok then ns.err("tooltip", e) end
            end
        end
        for _, tt in ipairs({ GameTooltip, ItemRefTooltip }) do
            tt:HookScript("OnTooltipSetItem",  guard(ns.OnItemTooltip))
            tt:HookScript("OnTooltipSetSpell", guard(ns.OnSpellTooltip))
        end
        GameTooltip:HookScript("OnTooltipSetUnit", guard(ns.OnUnitTooltip))
        ns.DB().probe.tooltipMode = "HookScript"
    end
end

-- Collectors defined in later files must exist before wiring, so wait for login.
ns.On("PLAYER_LOGIN", function() ns.try("tooltip.wire", wireTooltips) end)

-- Loot ----------------------------------------------------------------------

local lastLootKey

-- LOOT_READY fires before LOOT_OPENED. A fast auto-looter (SpeedyAutoLoot acts on
-- LOOT_READY) has emptied the corpse by the time LOOT_OPENED arrives, which left
-- records that knew who was looted but not what dropped. So read on whichever
-- comes first; the key below stops the same corpse being recorded twice.
local function captureLoot()
    if not GetNumLootItems then return end
    local db = ns.DB()
    local n = GetNumLootItems()
    if n == 0 then return end

    -- Source: creature, game object, or the player (fishing, containers).
    local sourceGUID
    if GetLootSourceInfo then
        local ok, guid = pcall(GetLootSourceInfo, 1)
        if ok then sourceGUID = guid end
    end
    local kind, sourceID = ns.ParseGUID(sourceGUID)
    if kind == "Player" then kind = "self" end

    -- Re-opening the same corpse is not a second drop. Keyed on the corpse alone:
    -- the slot count shrinks between LOOT_READY and LOOT_OPENED once auto-loot starts.
    local key = sourceGUID or ("?|" .. n)
    if key == lastLootKey then return end
    lastLootKey = key

    local rec = { t = time(), char = ns.CharKey(), kind = kind, sourceID = sourceID,
                  pos = ns.Pos(), items = {} }
    if kind == "Creature" and sourceID then
        local npc = db.npcs[sourceID]
        rec.sourceName = npc and npc.name
    end
    for slot = 1, n do
        local icon, name, quantity, currencyID, quality, locked, isQuestItem = GetLootSlotInfo(slot)
        local link = GetLootSlotLink(slot)
        local slotType = GetLootSlotType and GetLootSlotType(slot) or nil
        local itemID = link and tonumber(link:match("item:(%d+)"))
        rec.items[#rec.items + 1] = { itemID = itemID, name = name, qty = quantity, quality = quality,
                                      quest = isQuestItem and true or nil, slotType = slotType,
                                      currency = currencyID }
        if link then ns.RecordItem(link, nil) end
    end
    ns.push(db.lootEvents, ns.CAP.lootEvents, rec)

    -- A game object we looted is worth a catalog entry even if the tooltip
    -- never fired for it (gathering nodes with auto-loot).
    if kind == "GameObject" and sourceID then
        local existing
        for _, o in pairs(db.objects) do
            if o.objectID == sourceID then existing = o break end
        end
        local name = existing and existing.name or ("object " .. sourceID)
        ns.RecordObject(name, sourceID, "loot")
    end
end

ns.On("LOOT_READY", captureLoot)
ns.On("LOOT_OPENED", captureLoot)

-- Item links seen in chat (drops announced by others, trade links) are cheap
-- catalog entries even without a tooltip.
ns.On("CHAT_MSG_LOOT", function(msg)
    for link in msg:gmatch("|Hitem:[^|]+|h[^|]+|h") do
        ns.RecordItem(link, nil)
    end
end)
