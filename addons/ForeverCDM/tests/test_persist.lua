-- Settings mirror: survives a "client restart" where SavedVariables come back empty.
-- Each session() reloads the addon from disk with fresh frames, the way a new
-- client launch does. Only the fake macro store lives across sessions, which is
-- what was measured to persist on the Forever beta. Run from ForeverCDM:
--   lua tests/test_persist.lua
unpack = table.unpack
strlower = string.lower
strtrim = function(s) return s:match('^%s*(.-)%s*$') end
issecretvalue = function() return false end

local frames, methods = {}, {}
local function noop() end
local function object(kind, name, parent)
    local f = { kind = kind, parent = parent, scripts = {}, events = {}, shown = true }
    setmetatable(f, { __index = methods })
    frames[#frames + 1] = f
    if name then _G[name] = f end
    return f
end
for _, name in ipairs({ 'SetTexCoord', 'ClearAllPoints', 'SetMovable', 'SetClampedToScreen', 'SetDrawEdge',
    'SetHideCountdownNumbers', 'SetDesaturated', 'SetCooldownFromDurationObject', 'SetAllPoints', 'SetCooldown',
    'Clear', 'SetColorTexture', 'RegisterForDrag', 'SetPoint', 'SetTexture', 'EnableMouse', 'SetAlpha',
    'SetText' }) do methods[name] = noop end
function methods:SetSize(w, h) self.width, self.height = w, h end
function methods:GetWidth() return self.width or 100 end
function methods:SetScript(k, fn) self.scripts[k] = fn end
function methods:RegisterEvent(e) self.events[e] = true end
function methods:RegisterUnitEvent(e) self.events[e] = true end
function methods:CreateTexture() return object('Texture', nil, self) end
function methods:CreateFontString() return object('FontString', nil, self) end
function methods:IsShown() return self.shown end
function methods:Show() self.shown = true end
function methods:Hide() self.shown = false end
function methods:SetShown(v) self.shown = v and true or false end

CreateFrame = object
C_Spell = {
    GetSpellName = function(id) return 'Spell ' .. id end,
    GetSpellTexture = function(id) return id end,
    GetSpellCooldown = function() return { startTime = 0, duration = 0, isEnabled = true } end,
    GetSpellCharges = function() return nil end,
}
C_UnitAuras = { GetPlayerAuraBySpellID = function() return nil end }

-- Timers are queued so a test can decide when the save debounce and the fallback timer fire.
local timers = {}
C_Timer = { NewTicker = noop, After = function(_, fn) timers[#timers + 1] = fn end }
local function runTimers()
    while #timers > 0 do table.remove(timers, 1)() end
end

-- The one thing that outlives a session: the account's macro list.
local macros = {}                       -- ordered list of { name =, body = }
local macrosLoaded, inCombat, slotsFull = true, false, false
local function find(name) for i, m in ipairs(macros) do if m.name == name then return i end end return 0 end
GetMacroIndexByName = function(name) if not macrosLoaded then return 0 end return find(name) end
GetMacroBody = function(i) return macros[i] and macros[i].body end
CreateMacro = function(name, icon, body, perCharacter)
    assert(not inCombat, 'CreateMacro called in combat')
    assert(macrosLoaded, 'CreateMacro before the macro list loaded')
    assert(#name <= 16, 'macro name longer than 16 characters: ' .. name)
    assert(#body <= 255, 'macro body longer than 255 characters')
    assert(not perCharacter, 'expected a general macro')
    if slotsFull then return nil end
    macros[#macros + 1] = { name = name, body = body }
    return #macros
end
EditMacro = function(i, name, icon, body)
    assert(not inCombat, 'EditMacro called in combat')
    assert(macros[i] and #body <= 255, 'bad EditMacro')
    macros[i].body = body
    return i
end
DeleteMacro = function(i) assert(not inCombat, 'DeleteMacro called in combat') table.remove(macros, i) end
InCombatLockdown = function() return inCombat end

local player = 'Thunderz'
UnitName = function() return player end
GetRealmName = function() return 'Beta Realm' end

local printed
print = function(...) printed[#printed + 1] = table.concat({ ... }, ' ') end

local function fire(event)
    for _, f in ipairs(frames) do if f.events[event] then f.scripts.OnEvent(f, event) end end
end
local function session(savedVariables)
    frames, timers, printed = {}, {}, {}
    UIParent = object('Frame')
    SlashCmdList = {}
    ForeverCDM, ForeverCDMDB = nil, savedVariables
    assert(loadfile('ForeverCDM.lua'))('ForeverCDM')
    fire('PLAYER_LOGIN')
    runTimers()
    return ForeverCDMDB
end
local function slash(msg) SlashCmdList.FOREVERCDM(msg) runTimers() end
local function said(fragment)
    for _, line in ipairs(printed) do if line:find(fragment, 1, true) then return true end end
    return false
end

-- 1. First launch: defaults, and no macro appears on its own.
local db = session(nil)
assert(#db.cds == 0 and db.rowSize.buffs == 36 and db.locked == true, 'fresh install should start on defaults')
slash('add 101')
assert(#macros == 0, 'a macro was created without the player opting in')
assert(said('Keep settings in a macro'), 'player was not told their setup will be forgotten')
printed = {}
slash('add 102')
assert(not said('Keep settings in a macro'), 'the hint should appear once per session, not on every change')

-- The player opts in and sets things up.
slash('mirror on')
assert(#macros == 1, 'opting in should create the macro')
assert(macros[1].body:match('^/fcdm store 1/1 '), 'macro body must be a slash command so a click is harmless')
slash('addutility 103')
slash('addutility item:6948')     -- items are stored as negative IDs
slash('addbuff 201')
slash('size buffs 50')
slash('spacing cds 8')
slash('unlock')
slash('hideready on')
db.pos.buffs = { 'TOPLEFT', 123.4, -56.7 }
db.minimap.angle, db.minimap.hide = -42.4, true
db.buffDurations[201] = 1800
slash('names on')            -- any later change saves the manual edits above too
assert(#macros == 1, 'a normal setup should fit in one macro')

-- 2. Restart. The beta client hands back NO SavedVariables. Everything returns.
db = session(nil)
assert(said('restored from your settings macro'), 'player was not told where their settings came from')
assert(db.cds[1] == 101 and db.cds[2] == 102 and #db.cds == 2, 'cooldown list or its order was lost')
assert(db.utilities[1] == 103 and db.utilities[2] == -6948 and db.buffs[1] == 201, 'utility/buff lists (including an item) were lost')
assert(db.rowSize.buffs == 50 and db.rowSize.cds == 36, 'per-bar size was lost')
assert(db.rowSpacing.cds == 8 and db.rowSpacing.buffs == 4, 'per-bar spacing was lost')
assert(db.locked == false and db.hideReady == true and db.showNames == true, 'toggles were lost')
assert(db.pos.buffs[1] == 'TOPLEFT' and db.pos.buffs[2] == 123.4 and db.pos.buffs[3] == -56.7, 'bar position was lost')
assert(db.pos.cds[1] == 'CENTER' and db.pos.cds[3] == -170, 'untouched bar position changed')
assert(db.minimap.angle == -42 and db.minimap.hide == true, 'minimap button state was lost')
assert(db.buffDurations[201] == 1800, 'learned buff duration was lost')
assert(db.macroMirror == true, 'the macro existing should switch the option back on')
assert(not said('Keep settings in a macro'), 'no hint needed once opted in')

-- 3. Cold start where the macro list arrives AFTER login. Nothing may be written
--    before it is read, or the stored setup would be replaced by defaults.
macrosLoaded = false
frames, timers, printed = {}, {}, {}
UIParent = object('Frame') SlashCmdList = {} ForeverCDM, ForeverCDMDB = nil, nil
assert(loadfile('ForeverCDM.lua'))('ForeverCDM')
fire('PLAYER_LOGIN')
local before = macros[1].body
SlashCmdList.FOREVERCDM('add 555')                 -- an early change, macros still not loaded
assert(#timers == 2, 'expected the save debounce and the fallback timer to be queued')
table.remove(timers, 1)()                          -- the 1s save debounce fires; the fallback has not yet
assert(macros[1].body == before, 'wrote to the macro before it had been read')
macrosLoaded = true
fire('UPDATE_MACROS')
runTimers()
assert(said('restored from your settings macro') and ForeverCDMDB.cds[1] == 101, 'late-arriving macro was not restored')

-- 4. A real SavedVariables table always wins (the day Blizzard fixes the client).
db = session({ cds = { 999 }, buffs = {}, utilities = {} })
assert(db.cds[1] == 999 and #db.cds == 1, 'macro overwrote settings the client actually loaded')
assert(not said('restored'), 'claimed a restore it should not have done')
assert(db.macroMirror == true, 'option should still read as on, since the macro exists')
slash('lock')
db = session(nil)
assert(db.cds[1] == 999, 'macro did not follow the loaded settings')

-- 5. Combat: no macro calls until it ends (the fake API asserts on any).
inCombat = true
slash('add 4242')
slash('mirror')
assert(said('waiting for combat to end'), 'status should say why nothing was written')
inCombat = false
fire('PLAYER_REGEN_ENABLED')
db = session(nil)
assert(db.cds[2] == 4242, 'change made in combat was not saved after combat')

-- 6. Longer setups spread over more macros; a shorter save removes the extras.
for id = 1000, 1079 do db.cds[#db.cds + 1] = id end          -- about 400 characters of IDs
slash('lock')
assert(#macros >= 2, 'long settings should have spilled into a second macro')
local long = session(nil)
assert(#long.cds == 82 and long.cds[82] == 1079, 'long list did not survive chunking')
slash('reset')
slash('mirror on')
slash('add 7')
assert(#macros == 1, 'extra macros were left behind after the settings shrank')
db = session(nil)
assert(#db.cds == 1 and db.cds[1] == 7, 'restore after shrinking was wrong')

-- 7. Too big even for three macros: keep the last good copy, never a cut-off one.
for id = 100000, 100200 do db.cds[#db.cds + 1] = id end      -- about 1400 characters
slash('lock')
slash('mirror')
assert(said('too large'), 'status should report the oversize')
db = session(nil)
assert(#db.cds == 1 and db.cds[1] == 7, 'oversized settings should leave the previous macro intact')

-- 8. Another character gets its own macro.
player = 'Someone Else'
db = session(nil)
assert(#db.cds == 0 and not said('restored') and not db.macroMirror, "one character used another character's macro")
player = 'Thunderz'
db = session(nil)
assert(db.cds[1] == 7, 'the first character lost its macro after an alt logged in')

-- 9. No free macro slot: reported, nothing breaks.
player = 'Third'
db = session(nil)
slotsFull = true
slash('mirror on')
slash('mirror')
assert(said('could not create the macro'), 'a full macro list should be reported')
slotsFull, player = false, 'Thunderz'

-- 10. Opting out removes the macro.
db = session(nil)
local count = #macros
slash('mirror off')
assert(#macros == count - 1 and db.macroMirror == false, 'opting out should delete the macro')
db = session(nil)
assert(#db.cds == 0 and not db.macroMirror, 'settings came back after opting out')

-- 11. A hand-edited or foreign macro body is ignored, not applied.
macros[#macros + 1] = { name = 'placeholder', body = '' }
slash('mirror on')
for _, m in ipairs(macros) do if m.body:match('^/fcdm store') then m.body = '/fcdm store 1/1 this is not a settings string' end end
db = session(nil)
assert(#db.cds == 0 and not said('restored'), 'unrecognised macro contents were applied')

-- 12. Clicking the macro explains itself.
slash('store 1/1 anything')
assert(said('clicking it does nothing'), 'the macro click handler is missing')

-- 13. A client without the macro API: everything still loads.
CreateMacro = nil
db = session(nil)
slash('add 5')
slash('mirror on')
slash('mirror')
assert(db.cds[1] == 5 and said('no macro API'), 'addon should run without the mirror')

io.write('settings macro: opt-in, restart, late macro list, combat, chunking, per-character and fallback checks passed\n')
