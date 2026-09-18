-- FB_Spells.lua -- spellbook, talents, player auras, NPC abilities from the combat log
-- Author: Thunderz

local ADDON, ns = ...

local function spellInfo(spellID)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
        if ok and type(info) == "table" then
            return info.name, info.iconID, info.castTime, info.minRange, info.maxRange
        end
    elseif GetSpellInfo then
        local ok, name, _, icon, castTime, minRange, maxRange = pcall(GetSpellInfo, spellID)
        if ok then return name, icon, castTime, minRange, maxRange end
    end
    return nil
end

function ns.RecordSpell(spellID, source, tt)
    if not spellID then return end
    local db = ns.DB()
    local rec = db.spells[spellID]
    if not rec then
        local name, icon, castTime, minRange, maxRange = spellInfo(spellID)
        rec = { id = spellID, name = name, icon = icon, castTime = castTime,
                minRange = minRange, maxRange = maxRange, first = time(), n = 0, sources = {} }
        db.spells[spellID] = rec
    end
    -- Description text without needing a hover. It loads asynchronously, so
    -- keep asking until it comes back non-empty.
    if (not rec.desc or rec.desc == "") and C_Spell and C_Spell.GetSpellDescription then
        local ok, desc = pcall(C_Spell.GetSpellDescription, spellID)
        if ok and type(desc) == "string" and desc ~= "" then rec.desc = desc end
    end
    if not rec.subtext and C_Spell and C_Spell.GetSpellSubtext then
        local ok, sub = pcall(C_Spell.GetSpellSubtext, spellID)
        if ok and type(sub) == "string" and sub ~= "" then rec.subtext = sub end
    end
    rec.n = rec.n + 1
    rec.last = time()
    rec.sources[source] = (rec.sources[source] or 0) + 1
    if tt then
        local lines = ns.TooltipLines(tt)
        if #lines > 0 and (not rec.tooltip or #lines > #rec.tooltip) then rec.tooltip = lines end
    end
    return rec
end

function ns.OnSpellTooltip(tt)
    local _, spellID = tt:GetSpell()
    if not spellID and type(tt.GetPrimaryTooltipData) == "function" then
        local ok, data = pcall(tt.GetPrimaryTooltipData, tt)
        if ok and type(data) == "table" and data.id then spellID = data.id end
    end
    if spellID then ns.RecordSpell(spellID, "tooltip", tt) end
end

-- Spellbook ------------------------------------------------------------------

local function dumpSpellbook()
    local db = ns.DB()
    local _, class = UnitClass("player")
    local out = { level = UnitLevel("player"), t = time(), spells = {} }

    if GetNumSpellTabs and GetSpellBookItemInfo then
        for tab = 1, GetNumSpellTabs() do
            local tabName, _, offset, numSpells = GetSpellTabInfo(tab)
            for i = offset + 1, offset + numSpells do
                local kind, id = GetSpellBookItemInfo(i, BOOKTYPE_SPELL or "spell")
                if kind == "SPELL" and id then
                    local name, rank = GetSpellBookItemName(i, BOOKTYPE_SPELL or "spell")
                    out.spells[#out.spells + 1] = { id = id, name = name, rank = rank, tab = tabName }
                    ns.RecordSpell(id, "spellbook", nil)
                end
            end
        end
    elseif C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
        local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if info then
                for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                    local item = C_SpellBook.GetSpellBookItemInfo(i, bank)
                    if item and item.spellID and not item.isPassive then
                        out.spells[#out.spells + 1] = { id = item.spellID, name = item.name, tab = info.name }
                        ns.RecordSpell(item.spellID, "spellbook", nil)
                    end
                end
            end
        end
    else
        out.unsupported = true
    end
    db.spellbook[class or "?"] = out
end

-- Talents (Classic tree layout). The whole tree is recorded, not just the
-- points spent, so the 31-point capstones and prerequisites are captured.
local function dumpTalents()
    local db = ns.DB()
    if db.talents.unsupported then return end
    -- Some clients keep the function but throw "API unsupported" when called.
    local okTabs, numTabs = pcall(function() return GetNumTalentTabs and GetTalentInfo and GetNumTalentTabs() end)
    if not okTabs or type(numTabs) ~= "number" then
        db.talents.unsupported = true
        return
    end
    local _, class = UnitClass("player")
    local tabs = {}
    for t = 1, numTabs do
        local name, icon, pointsSpent, background = GetTalentTabInfo(t)
        if type(name) ~= "string" then
            -- some clients return a table or shifted args; keep what we can
            name = tostring(name)
        end
        local tab = { name = name, spent = pointsSpent, talents = {} }
        local num = GetNumTalents and GetNumTalents(t) or 0
        for i = 1, num do
            local tName, tIcon, tier, column, rank, maxRank, isExceptional, available = GetTalentInfo(t, i)
            local rec = { name = tName, tier = tier, col = column, rank = rank, max = maxRank }
            if GetTalentPrereqs then
                local ok, pTier, pCol = pcall(GetTalentPrereqs, t, i)
                if ok and pTier then rec.prereq = { tier = pTier, col = pCol } end
            end
            if GetTalentLink then
                local ok, link = pcall(GetTalentLink, t, i)
                if ok and link then rec.link = link end
            end
            tab.talents[#tab.talents + 1] = rec
        end
        tabs[#tabs + 1] = tab
    end
    db.talents[class or "?"] = { t = time(), level = UnitLevel("player"), tabs = tabs }
end

-- Trait trees. The Forever client (1.60.x) builds class talents AND the Legacy
-- trees on Retail's C_Traits system, so one walker covers both. Every config
-- the client will tell us about is dumped: the active class config, every
-- TraitConfigType, and system-based configs found by probing system IDs.
local function dumpTraits()
    if not (C_Traits and C_Traits.GetConfigInfo and C_Traits.GetTreeNodes) then return end
    local db = ns.DB()
    local configs = {}

    if C_ClassTalents and C_ClassTalents.GetActiveConfigID then
        local ok, id = pcall(C_ClassTalents.GetActiveConfigID)
        if ok and id then configs[id] = "class" end
    end
    if Enum and Enum.TraitConfigType and C_Traits.GetConfigsByType then
        for name, val in pairs(Enum.TraitConfigType) do
            local ok, ids = pcall(C_Traits.GetConfigsByType, val)
            if ok and type(ids) == "table" then
                for _, id in ipairs(ids) do configs[id] = configs[id] or ("type:" .. name) end
            end
        end
    end
    if C_Traits.GetConfigIDBySystemID then
        for sys = 1, 120 do
            local ok, id = pcall(C_Traits.GetConfigIDBySystemID, sys)
            if ok and id then configs[id] = configs[id] or ("system:" .. sys) end
        end
    end

    for configID, kind in pairs(configs) do
        local ok, info = pcall(C_Traits.GetConfigInfo, configID)
        if ok and type(info) == "table" then
            local _, class = UnitClass("player")
            local rec = { kind = kind, name = info.name, type = info.type, class = class,
                          level = UnitLevel("player"), t = time(), trees = {} }
            for _, treeID in ipairs(info.treeIDs or {}) do
                local tree = { nodes = {} }
                local okc, cur = pcall(C_Traits.GetTreeCurrencyInfo, configID, treeID, false)
                if okc and type(cur) == "table" then tree.currencies = cur end
                local oks, sysID = pcall(C_Traits.GetSystemIDByTreeID, treeID)
                if oks then tree.systemID = sysID end
                local okn, nodes = pcall(C_Traits.GetTreeNodes, treeID)
                for _, nodeID in ipairs(okn and nodes or {}) do
                    local okNode, node = pcall(C_Traits.GetNodeInfo, configID, nodeID)
                    if okNode and type(node) == "table" and node.ID and node.ID ~= 0 then
                        local n = { id = nodeID, x = node.posX, y = node.posY, type = node.type,
                                    maxRanks = node.maxRanks, ranks = node.ranksPurchased,
                                    visible = node.isVisible, available = node.isAvailable,
                                    entries = {}, edges = {} }
                        for _, e in ipairs(node.visibleEdges or {}) do n.edges[#n.edges + 1] = e.targetNode end
                        for _, entryID in ipairs(node.entryIDs or {}) do
                            local er = { id = entryID }
                            local okE, entry = pcall(C_Traits.GetEntryInfo, configID, entryID)
                            if okE and type(entry) == "table" then
                                er.maxRanks = entry.maxRanks
                                er.def = entry.definitionID
                                if entry.definitionID then
                                    local okD, def = pcall(C_Traits.GetDefinitionInfo, entry.definitionID)
                                    if okD and type(def) == "table" then
                                        er.spellID = def.spellID
                                        er.overrideName = def.overrideName
                                        er.overrideDesc = def.overrideDescription
                                        if def.spellID then
                                            local s = ns.RecordSpell(def.spellID, "trait", nil)
                                            if s then er.name = s.name; er.desc = s.desc end
                                        end
                                    end
                                end
                            end
                            n.entries[#n.entries + 1] = er
                        end
                        local okCost, cost = pcall(C_Traits.GetNodeCost, configID, nodeID)
                        if okCost and type(cost) == "table" then n.cost = cost end
                        tree.nodes[#tree.nodes + 1] = n
                    end
                end
                rec.trees[tostring(treeID)] = tree
            end
            db.traits[tostring(configID)] = rec
        end
    end
end
ns.DumpTraits = dumpTraits

local pendingBook
local function bookSoon()
    if pendingBook then return end
    pendingBook = true
    C_Timer.After(3, function()
        pendingBook = false
        ns.try("spellbook", dumpSpellbook)
        ns.try("talents", dumpTalents)
        ns.try("traits", dumpTraits)
    end)
end

ns.On("TRAIT_CONFIG_UPDATED", bookSoon)
ns.On("TRAIT_CONFIG_LIST_UPDATED", bookSoon)
ns.On("TRAIT_TREE_CURRENCY_INFO_UPDATED", bookSoon)
ns.On("TRAIT_SYSTEM_INTERACTION_STARTED", bookSoon)

ns.On("PLAYER_LOGIN", function() C_Timer.After(8, bookSoon) end)
ns.On("SPELLS_CHANGED", bookSoon)
ns.On("LEARNED_SPELL_IN_TAB", bookSoon)
ns.On("CHARACTER_POINTS_CHANGED", bookSoon)
ns.On("PLAYER_TALENT_UPDATE", bookSoon)

-- Player auras: campfire buffs, food buffs, Legacy perks if they show as auras.
local function scanAuras()
    -- In combat every aura read throws on this client; skip instead of
    -- filing the same error on every UNIT_AURA.
    if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then return end
    local db = ns.DB()
    local function note(spellID, name, duration, source, isHelpful)
        -- Aura fields can be secret in combat on this client; a secret spell
        -- ID cannot even be used as a table key, so screen everything.
        spellID  = ns.Num(spellID)
        duration = ns.Num(duration)
        if issecretvalue then
            if issecretvalue(name) then name = nil end
            if issecretvalue(source) then source = nil end
            if issecretvalue(isHelpful) then isHelpful = nil end
        end
        if not spellID then
            db.auraSecretHits = (db.auraSecretHits or 0) + 1
            return
        end
        local rec = db.auras[spellID]
        if not rec then
            rec = { id = spellID, name = name, first = time(), n = 0 }
            db.auras[spellID] = rec
        end
        rec.n = rec.n + 1
        rec.last = time()
        rec.helpful = isHelpful
        if duration and duration > 0 then rec.duration = math.max(rec.duration or 0, duration) end
        if source then rec.source = source end
        ns.RecordSpell(spellID, "aura", nil)
    end

    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
            for i = 1, 60 do
                local a = C_UnitAuras.GetAuraDataByIndex("player", i, filter)
                if not a then break end
                note(a.spellId, a.name, a.duration, a.sourceUnit, a.isHelpful)
            end
        end
    elseif UnitAura then
        for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
            for i = 1, 60 do
                local name, _, _, _, duration, _, source, _, _, spellID = UnitAura("player", i, filter)
                if not name then break end
                note(spellID, name, duration, source, filter == "HELPFUL")
            end
        end
    end
end

local pendingAura
ns.On("UNIT_AURA", function(unit)
    if unit ~= "player" or pendingAura then return end
    pendingAura = true
    C_Timer.After(1, function()
        pendingAura = false
        ns.try("auras", scanAuras)
    end)
end)

-- NPC abilities from the combat log: what each creature casts, hits for, and
-- applies. This is the raw material for dungeon guides.
local WATCH = {
    SPELL_CAST_START = true, SPELL_CAST_SUCCESS = true, SPELL_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true, SPELL_AURA_APPLIED = true, SPELL_HEAL = true,
    SPELL_INTERRUPT = true, SPELL_SUMMON = true,
}

-- On clients with the Midnight restrictions (Retail 12.x, Forever 1.60) the
-- reader function is gone and even REGISTERING this event is a forbidden
-- action that taints the addon. Only wire it where it can work.
if not CombatLogGetCurrentEventInfo then
    ns.combatLogUnavailable = true
    return
end

ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
    local _, sub, _, srcGUID, srcName, srcFlags, _, dstGUID, dstName, _, _,
          a1, a2, a3, a4 = CombatLogGetCurrentEventInfo()
    local db = ns.DB()

    if sub == "UNIT_DIED" then
        local kind, npcID = ns.ParseGUID(dstGUID)
        if kind == "Creature" and npcID then
            local rec = db.npcs[npcID]
            if not rec then
                rec = { id = npcID, name = dstName, first = time(), n = 0, levels = {}, sources = {} }
                db.npcs[npcID] = rec
            end
            rec.kills = (rec.kills or 0) + 1
        end
        return
    end

    local kind, npcID = ns.ParseGUID(srcGUID)
    if not npcID or (kind ~= "Creature" and kind ~= "Vehicle") then return end

    if sub == "SWING_DAMAGE" then
        local amount = ns.Num(a1)
        if amount and amount > 0 then
            local rec = db.npcs[npcID]
            if rec then
                rec.swingMax = math.max(rec.swingMax or 0, amount)
                rec.swingMin = math.min(rec.swingMin or amount, amount)
                rec.swings = (rec.swings or 0) + 1
            end
        end
        return
    end

    if not WATCH[sub] then return end
    local spellID, spellName, school = a1, a2, a3
    if type(spellID) ~= "number" then return end

    local byNpc = db.npcAbilities[npcID]
    if not byNpc then
        byNpc = { name = srcName }
        db.npcAbilities[npcID] = byNpc
    end
    local ab = byNpc[spellID]
    if not ab then
        ab = { name = spellName, school = school, n = 0, subs = {} }
        byNpc[spellID] = ab
        ns.RecordSpell(spellID, "npc:" .. npcID, nil)
    end
    ab.n = ab.n + 1
    ab.subs[sub] = (ab.subs[sub] or 0) + 1
    if sub == "SPELL_DAMAGE" or sub == "SPELL_PERIODIC_DAMAGE" then
        local dmg = ns.Num(a4)
        if dmg then ab.maxDmg = math.max(ab.maxDmg or 0, dmg) end
    end
end)
