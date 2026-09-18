-- Compat.lua -- global function names Retail addons expect, mapped onto the
-- WoW: Forever client (1.60.x, interface 16001).
-- Author: Thunderz
--
-- Forever runs the Retail 12.x API but ships WITHOUT Blizzard's deprecated
-- global wrappers, so a Retail addon calling GetItemInfo() or
-- GetSpecialization() hits "attempt to call a nil value". Every name below is
-- defined ONLY if the client does not already provide it, and each simply
-- forwards to the modern C_ namespace equivalent. Names and signatures follow
-- Blizzard's own Blizzard_Deprecated wrappers.
--
-- Found by scanning addon source against the API surface Forever Beacon
-- captured from the live client (Forever\tools\api_scan.py).

local function define(name, fn)
    if _G[name] == nil and type(fn) == "function" then _G[name] = fn end
end

-- Items ---------------------------------------------------------------------
if C_Item then
    define("GetItemInfo",         C_Item.GetItemInfo)
    define("GetItemInfoInstant",  C_Item.GetItemInfoInstant)
    define("GetItemQualityColor", C_Item.GetItemQualityColor)
    define("GetItemIcon",         C_Item.GetItemIconByID)
    define("GetItemCount",        C_Item.GetItemCount)
    define("GetItemSpell",        C_Item.GetItemSpell)
    define("GetItemCooldown",     C_Item.GetItemCooldown)
    define("IsEquippedItem",      C_Item.IsEquippedItem)
    define("IsUsableItem",        C_Item.IsUsableItem)
    define("GetDetailedItemLevelInfo", C_Item.GetDetailedItemLevelInfo)
    define("IsEquippableItem",    C_Item.IsEquippableItem)      -- EllesmereUIBags line 50
    define("IsCosmeticItem",      C_Item.IsCosmeticItem)
    define("GetItemFamily",       C_Item.GetItemFamily)
    define("GetItemClassInfo",    C_Item.GetItemClassInfo)
    define("GetItemSubClassInfo", C_Item.GetItemSubClassInfo)
    define("GetItemStats",        C_Item.GetItemStats)
    define("GetItemSetInfo",      C_Item.GetItemSetInfo)
    define("GetItemInventorySlotInfo", C_Item.GetItemInventorySlotInfo)
    define("GetItemQualityByID",  C_Item.GetItemQualityByID)
    define("GetItemUniqueness",   C_Item.GetItemUniqueness)
    define("IsCorruptedItem",     C_Item.IsCorruptedItem)
end

-- Containers, old multi-return shape rebuilt from the table ---------------------
if C_Container then
    define("ContainerIDToInventoryID",  C_Container.ContainerIDToInventoryID)
    define("GetBagName",                C_Container.GetBagName)
    define("GetContainerItemCooldown",  C_Container.GetContainerItemCooldown)
    define("GetContainerItemDurability", C_Container.GetContainerItemDurability)
    define("GetContainerFreeSlots",     C_Container.GetContainerFreeSlots)
    define("SplitContainerItem",        C_Container.SplitContainerItem)
    if C_Container.GetContainerItemInfo then
        define("GetContainerItemInfo", function(bag, slot)
            local i = C_Container.GetContainerItemInfo(bag, slot)
            if not i then return nil end
            return i.iconFileID, i.stackCount, i.isLocked, i.quality, i.isReadable, i.hasLoot,
                   i.hyperlink, i.isFiltered, i.hasNoValue, i.itemID, i.isBound
        end)
    end
    if C_Container.GetContainerItemQuestInfo then
        define("GetContainerItemQuestInfo", function(bag, slot)
            local q = C_Container.GetContainerItemQuestInfo(bag, slot)
            if not q then return nil end
            return q.isQuestItem, q.questID, q.isActive
        end)
    end
end

-- Currency / money text -------------------------------------------------------
if C_CurrencyInfo then
    define("GetCoinTextureString", C_CurrencyInfo.GetCoinTextureString)
    define("GetCoinText",          C_CurrencyInfo.GetCoinText)
end

-- Addon comms -------------------------------------------------------------------
if C_ChatInfo then
    define("SendAddonMessage",           C_ChatInfo.SendAddonMessage)
    define("RegisterAddonMessagePrefix", C_ChatInfo.RegisterAddonMessagePrefix)
end

-- Spells (old multi-return signatures rebuilt from the table returns) ---------
if C_Spell then
    if C_Spell.GetSpellInfo then
        define("GetSpellInfo", function(spell)
            if not spell then return nil end
            local i = C_Spell.GetSpellInfo(spell)
            if not i then return nil end
            return i.name, nil, i.iconID, i.castTime, i.minRange, i.maxRange, i.spellID, i.originalIconID
        end)
    end
    if C_Spell.GetSpellCooldown then
        define("GetSpellCooldown", function(spell)
            local c = C_Spell.GetSpellCooldown(spell)
            if not c then return nil end
            return c.startTime, c.duration, c.isEnabled and 1 or 0, c.modRate
        end)
    end
    if C_Spell.GetSpellCharges then
        define("GetSpellCharges", function(spell)
            local c = C_Spell.GetSpellCharges(spell)
            if not c then return nil end
            return c.currentCharges, c.maxCharges, c.cooldownStartTime, c.cooldownDuration, c.chargeModRate
        end)
    end
    define("GetSpellTexture",     C_Spell.GetSpellTexture)
    define("GetSpellLink",        C_Spell.GetSpellLink)
    define("GetSpellDescription", C_Spell.GetSpellDescription)
    define("IsUsableSpell",       C_Spell.IsSpellUsable)
    define("IsSpellInRange",      C_Spell.IsSpellInRange)
    define("IsPressHoldReleaseSpell", C_Spell.IsPressHoldReleaseSpell)
    define("IsPassiveSpell",      C_Spell.IsSpellPassive)
    define("IsCurrentSpell",      C_Spell.IsCurrentSpell)
    define("IsAutoRepeatSpell",   C_Spell.IsAutoRepeatSpell)
    define("GetSpellSubtext",     C_Spell.GetSpellSubtext)
    define("GetSpellPowerCost",   C_Spell.GetSpellPowerCost)
    define("GetSpellBaseCooldown", C_Spell.GetSpellBaseCooldown)
end

-- Auras (old positional UnitAura family) -------------------------------------
if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex and AuraUtil and AuraUtil.UnpackAuraData then
    define("UnitAura", function(unit, index, filter)
        return AuraUtil.UnpackAuraData(C_UnitAuras.GetAuraDataByIndex(unit, index, filter))
    end)
    define("UnitBuff", function(unit, index, filter)
        return AuraUtil.UnpackAuraData(C_UnitAuras.GetBuffDataByIndex(unit, index, filter))
    end)
    define("UnitDebuff", function(unit, index, filter)
        return AuraUtil.UnpackAuraData(C_UnitAuras.GetDebuffDataByIndex(unit, index, filter))
    end)
end

-- Specializations. Forever has no Retail-style spec choice, but the
-- namespace exists and answers; addons call the bare globals ~100 times.
if C_SpecializationInfo then
    define("GetSpecialization",               C_SpecializationInfo.GetSpecialization)
    define("GetSpecializationInfo",           C_SpecializationInfo.GetSpecializationInfo)
    define("GetNumSpecializationsForClassID", C_SpecializationInfo.GetNumSpecializationsForClassID)
    define("GetActiveSpecGroup",              C_SpecializationInfo.GetActiveSpecGroup)
    define("GetInspectSpecialization",        C_SpecializationInfo.GetInspectSpecialization)
end

-- AddOns ----------------------------------------------------------------------
if C_AddOns then
    define("IsAddOnLoaded",      C_AddOns.IsAddOnLoaded)
    define("GetAddOnMetadata",   C_AddOns.GetAddOnMetadata)
    define("GetNumAddOns",       C_AddOns.GetNumAddOns)
    define("GetAddOnInfo",       C_AddOns.GetAddOnInfo)
    define("LoadAddOn",          C_AddOns.LoadAddOn)
    define("IsAddOnLoadOnDemand", C_AddOns.IsAddOnLoadOnDemand)
end

-- Containers ------------------------------------------------------------------
if C_Container then
    define("GetContainerNumSlots",     C_Container.GetContainerNumSlots)
    define("GetContainerItemLink",     C_Container.GetContainerItemLink)
    define("GetContainerItemID",       C_Container.GetContainerItemID)
    define("GetContainerNumFreeSlots", C_Container.GetContainerNumFreeSlots)
    define("PickupContainerItem",      C_Container.PickupContainerItem)
    define("UseContainerItem",         C_Container.UseContainerItem)
end

-- Misc ------------------------------------------------------------------------
if GetMouseFoci then
    define("GetMouseFocus", function()
        local t = GetMouseFoci()
        return t and t[1] or nil
    end)
end
if C_EquipmentSet then
    define("GetEquipmentSetItemIDs", C_EquipmentSet.GetItemIDs)
end
if TogglePlayerSpellsFrame then
    define("ToggleTalentFrame", function() TogglePlayerSpellsFrame() end)
end

ForeverCompat_Loaded = true
