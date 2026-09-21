-- FB_Range.lua -- what can an addon learn about distance to the target on this client?
-- Author: Thunderz
--
-- Groundwork for a hunter dead-zone indicator. Classic rules give Auto Shot a
-- MINIMUM range, so between melee reach and that minimum a hunter can do neither.
-- Whether an addon can see that depends on which range calls this client answers,
-- and whether the answers turn "secret" (unreadable) in combat. This measures it.
--
--   /fb range            one reading, printed
--   /fb range log        a reading every half second while you walk; /fb range stop
--   /fb range dump       what was logged, grouped, so the boundaries can be read off
--   /fb range swing      test Forever's C_SwingTimer range API and print its range events
--
-- Nothing here assumes a spell name works: every spell in the book is tried once
-- and the ones that have a range are kept, so it works for any class.

local ADDON, ns = ...

local function secret(v) return issecretvalue and issecretvalue(v) end

-- "true" / "false" / "nil" / "SECRET" / "ERR:..." for any call, never throws.
local function probe(fn, ...)
    if type(fn) ~= "function" then return "n/a" end
    local ok, v = pcall(fn, ...)
    if not ok then return "ERR" end
    if secret(v) then return "SECRET" end
    if v == nil then return "nil" end
    if v == true or v == 1 then return "yes" end
    if v == false or v == 0 then return "no" end
    return tostring(v)
end

-- Spells in the book that have a range, found once per session.
local ranged
local function rangedSpells()
    if ranged then return ranged end
    ranged = {}
    local book, bank = C_SpellBook, Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
    if not (book and book.GetNumSpellBookSkillLines and bank ~= nil) then return ranged end
    local seen = {}
    for line = 1, book.GetNumSpellBookSkillLines() do
        local info = book.GetSpellBookSkillLineInfo(line)
        if info then
            for slot = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                local item = book.GetSpellBookItemInfo(slot, bank)
                local id = item and item.spellID
                if id and not item.isPassive and not seen[id] then
                    seen[id] = true
                    local ok, has = pcall(C_Spell.SpellHasRange, id)
                    if ok and has and not secret(has) then
                        local s = C_Spell.GetSpellInfo(id)
                        ranged[#ranged + 1] = { id = id, name = item.name or (s and s.name) or tostring(id),
                                                min = s and s.minRange, max = s and s.maxRange }
                    end
                end
            end
        end
    end
    table.sort(ranged, function(a, b) return (a.max or 0) < (b.max or 0) end)
    return ranged
end

local function reading()
    local r = { combat = InCombatLockdown() and "combat" or "calm", spells = {}, interact = {} }
    if not UnitExists("target") then r.noTarget = true return r end
    r.hostile = probe(UnitCanAttack, "player", "target")
    for _, s in ipairs(rangedSpells()) do
        r.spells[#r.spells + 1] = { s = s, v = probe(C_Spell.IsSpellInRange, s.id, "target") }
    end
    for i = 1, 5 do r.interact[i] = probe(CheckInteractDistance, "target", i) end
    -- Forever's own swing-timer API: is the target in AUTO ATTACK range, per weapon?
    -- 0 = main hand (melee), 2 = ranged. nil means "no check possible", not "out of range".
    -- It answers nil until range checking has been switched on for that weapon (Blizzard's
    -- own swing bars do the same). Only ever switch it ON: the flag is shared with them.
    if C_SwingTimer and C_SwingTimer.EnableRangeCheck and not ns.swingRangeOn then
        ns.swingRangeOn = true
        pcall(C_SwingTimer.EnableRangeCheck, 0, true)
        pcall(C_SwingTimer.EnableRangeCheck, 2, true)
    end
    local swing = C_SwingTimer and C_SwingTimer.IsTargetWithinSwingRange
    r.melee, r.shot = probe(swing, 0), probe(swing, 2)
    return r
end

local function line(r)
    if r.noTarget then return "no target." end
    local parts = {}
    for _, e in ipairs(r.spells) do
        parts[#parts + 1] = string.format("%s[%s-%s]=%s", e.s.name, tostring(e.s.min or "?"), tostring(e.s.max or "?"), e.v)
    end
    return string.format("%s | SWING melee=%s ranged=%s | interact 1-5: %s | %s",
        r.combat, r.melee, r.shot, table.concat(r.interact, ","), #parts > 0 and table.concat(parts, "  ") or "no ranged spells found")
end

local ticker
local function key(r)
    local parts = { r.combat, r.melee or "", r.shot or "" }
    for _, e in ipairs(r.spells) do parts[#parts + 1] = e.v end
    for i = 1, 5 do parts[#parts + 1] = r.interact[i] end
    return table.concat(parts, "|")
end

function ns.Range(arg)
    arg = (arg or ""):lower()
    local db = ns.DB()
    db.range = db.range or { states = {}, order = {} }
    local log = db.range
    if arg == "log" then
        if ticker then ns.printf("range: already logging. /fb range stop") return end
        ns.printf("range: logging twice a second. Target a hostile mob, walk from point-blank out past max range and back, in and out of combat. /fb range stop when done.")
        ticker = C_Timer.NewTicker(0.5, function()
            local r = reading()
            if r.noTarget then return end
            local k = key(r)
            if not log.states[k] then
                log.states[k] = { n = 0, text = line(r) }
                log.order[#log.order + 1] = k
                ns.printf("range: NEW state  %s", log.states[k].text)     -- a boundary was crossed
            end
            log.states[k].n = log.states[k].n + 1
        end)
    elseif arg == "stop" then
        if ticker then ticker:Cancel() ticker = nil end
        ns.printf("range: stopped. %d distinct states seen; /fb range dump lists them.", #log.order)
    elseif arg == "dump" then
        for i, k in ipairs(log.order) do ns.printf("range %d (seen %dx): %s", i, log.states[k].n, log.states[k].text) end
        if #log.order == 0 then ns.printf("range: nothing logged yet. /fb range log") end
    elseif arg == "swing" then
        -- Can an addon use Forever's swing-range API at all? Shows each step's raw result.
        local T = Enum and Enum.PlayerSwingType
        ns.printf("swing: C_SwingTimer=%s  Enum.PlayerSwingType=%s", tostring(C_SwingTimer ~= nil), tostring(T ~= nil))
        if not C_SwingTimer then return end
        for _, w in ipairs({ { "MainHand", 0 }, { "Ranged", 2 } }) do
            local id = (T and T[w[1]]) or w[2]
            local ok, err = pcall(C_SwingTimer.EnableRangeCheck, id, true)
            local ok2, v = pcall(C_SwingTimer.IsTargetWithinSwingRange, id)
            ns.printf("swing %s(%s): enable ok=%s %s | read ok=%s value=%s", w[1], tostring(id), tostring(ok), ok and "" or tostring(err),
                tostring(ok2), secret(v) and "SECRET" or tostring(v))
        end
        if not ns.swingWatch then
            ns.swingWatch = CreateFrame("Frame")
            ns.swingWatch:RegisterEvent("PLAYER_SWING_RANGE_UPDATE")
            ns.swingWatch:SetScript("OnEvent", function(_, _, weapon, inRange, checked)
                ns.printf("swing EVENT: weapon=%s inRange=%s checked=%s", tostring(weapon),
                    secret(inRange) and "SECRET" or tostring(inRange), secret(checked) and "SECRET" or tostring(checked))
            end)
            ns.printf("swing: now printing every PLAYER_SWING_RANGE_UPDATE. Walk in and out of melee and the 8 yard line.")
        end
    elseif arg == "clear" then
        db.range = nil
        ns.printf("range: log cleared.")
    else
        ns.printf("range: %s", line(reading()))
        ns.printf("range: event API present: EnableActionRangeCheck=%s", tostring(C_ActionBar and C_ActionBar.EnableActionRangeCheck ~= nil))
    end
end
