-- ActionPlace.lua -- put abilities on action bars without dragging.
-- Author: Thunderz
--
-- WHY: build 1.60.1.69893 of the Forever beta ships
-- Blizzard_RestrictedAddOnEnvironment/RestrictedExecution.lua calling
-- loadstring_untainted(), a function the client does not provide. Every secure
-- handler snippet therefore fails to compile, and action bar addons
-- (EllesmereUI, Bartender4, Dominos, ElvUI) wrap drag start / drop in exactly
-- such snippets, so dragging an ability does nothing.
--
-- Placing an action does not need any of that: pick the thing up onto the
-- cursor and PlaceAction(slot). Both are ordinary calls out of combat.
--
--   /place <name>            hover a bar button, then type this
--   /place <slot> <name>     or give the slot number
--   /place macro:<name> | item:<name> | <spellID>
--   /unplace [slot]          empty the hovered (or given) slot
--   /swapslot <a> <b>        swap two slots
--   /slot                    print the hovered button's slot number and content
--
-- Delete this file once Blizzard fixes the build.

local function say(fmt, ...)
    print("|cffd2621fForever|r: " .. string.format(fmt, ...))
end

local function hoveredSlot()
    local foci = GetMouseFoci and GetMouseFoci() or {}
    for _, f in ipairs(foci) do
        local cur = f
        for _ = 1, 4 do                       -- the button or a few parents up
            if not cur or not cur.GetAttribute then break end
            local ok, slot = pcall(cur.GetAttribute, cur, "action")
            slot = ok and tonumber(slot) or nil
            if slot and slot > 0 then return slot end
            cur = cur.GetParent and cur:GetParent() or nil
        end
    end
    return nil
end

local function describe(slot)
    if not HasAction(slot) then return "empty" end
    local kind, id = GetActionInfo(slot)
    if kind == "spell" and id and C_Spell and C_Spell.GetSpellName then
        return "spell: " .. (C_Spell.GetSpellName(id) or id)
    elseif kind == "macro" then
        return "macro: " .. (GetActionText(slot) or id or "?")
    elseif kind == "item" and id and C_Item and C_Item.GetItemNameByID then
        return "item: " .. (C_Item.GetItemNameByID(id) or id)
    end
    return tostring(kind) .. " " .. tostring(id)
end

local function blocked()
    if InCombatLockdown() then
        say("not in combat. Action slots can only be changed out of combat.")
        return true
    end
    return false
end

-- Returns true when something is now on the cursor.
local function pickup(what)
    ClearCursor()
    local kind, name = what:match("^(%a+):(.+)$")
    kind = kind and kind:lower()
    if kind == "macro" then
        local idx = GetMacroIndexByName(name)
        if not idx or idx == 0 then say("no macro named \"%s\".", name) return false end
        PickupMacro(idx)
    elseif kind == "item" then
        C_Item.PickupItem(name)
    else
        local ident = tonumber(what) or what
        local id = C_Spell.GetSpellIDForSpellIdentifier and C_Spell.GetSpellIDForSpellIdentifier(ident) or ident
        if not id then say("no spell called \"%s\" (it has to be in your spellbook).", what) return false end
        C_Spell.PickupSpell(id)
    end
    if not GetCursorInfo() then
        say("could not pick up \"%s\". Check the spelling, or that you know it.", what)
        return false
    end
    return true
end

SLASH_FOREVERPLACE1 = "/place"
SlashCmdList.FOREVERPLACE = function(msg)
    msg = strtrim(msg or "")
    if msg == "" then
        say("hover a bar button and type /place <spell name>. Also: /place <slot> <name>, /place macro:<name>, /place item:<name>, /unplace, /swapslot a b, /slot")
        return
    end
    if blocked() then return end
    local slot, what = msg:match("^(%d+)%s+(.+)$")
    slot = tonumber(slot)
    if not slot then
        slot, what = hoveredSlot(), msg
    end
    if not slot then say("hover an action button first, or give a slot number: /place 5 %s", msg) return end
    if not pickup(what) then return end
    PlaceAction(slot)
    ClearCursor()   -- whatever was in the slot comes back on the cursor; drop it
    say("slot %d is now %s", slot, describe(slot))
end

SLASH_FOREVERUNPLACE1 = "/unplace"
SlashCmdList.FOREVERUNPLACE = function(msg)
    if blocked() then return end
    local slot = tonumber(strtrim(msg or "")) or hoveredSlot()
    if not slot then say("hover an action button first, or give a slot number: /unplace 5") return end
    local was = describe(slot)
    PickupAction(slot)
    ClearCursor()
    say("slot %d cleared (was %s)", slot, was)
end

SLASH_FOREVERSWAPSLOT1 = "/swapslot"
SlashCmdList.FOREVERSWAPSLOT = function(msg)
    if blocked() then return end
    local a, b = (msg or ""):match("^%s*(%d+)%s+(%d+)%s*$")
    a, b = tonumber(a), tonumber(b)
    if not (a and b) then say("usage: /swapslot <slotA> <slotB>") return end
    ClearCursor()
    PickupAction(a)
    PlaceAction(b)      -- b's old content is now on the cursor
    if GetCursorInfo() then PlaceAction(a) end
    ClearCursor()
    say("slot %d: %s  |  slot %d: %s", a, describe(a), b, describe(b))
end

SLASH_FOREVERSLOT1 = "/slot"
SlashCmdList.FOREVERSLOT = function()
    local slot = hoveredSlot()
    if not slot then say("hover an action button first.") return end
    say("slot %d: %s", slot, describe(slot))
end
