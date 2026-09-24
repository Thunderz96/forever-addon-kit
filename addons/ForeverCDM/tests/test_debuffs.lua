-- Debuffs bar (your debuffs on the target) and the "hide inactive auras" option.
-- Loads the real addon against a tiny fake UI. Run from ForeverCDM:
--   lua tests/test_debuffs.lua
unpack = table.unpack
strlower = string.lower
strtrim = function(s) return s:match('^%s*(.-)%s*$') end
issecretvalue = function() return false end
UISpecialFrames, SlashCmdList = {}, {}

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
    'SetHideCountdownNumbers', 'SetDesaturated', 'SetCooldownFromDurationObject', 'SetAllPoints',
    'SetColorTexture', 'RegisterForDrag', 'SetTexture', 'EnableMouse' }) do methods[name] = noop end
function methods:SetSize(w, h) self.width, self.height = w, h end
function methods:GetWidth() return self.width or 100 end
-- frame geometry the Edit Mode anchoring code reads; this harness does not test it
function methods:GetEffectiveScale() return 1 end
function methods:GetCenter() return 0, 0 end
function methods:GetNumPoints() return 0 end
function methods:IsShown() return true end
function methods:SetText(t) self.textValue = t end
function methods:SetAlpha(a) self.alpha = a end
function methods:SetPoint(_, _, _, x) self.x = x end          -- remember the horizontal offset
function methods:SetScript(k, fn) self.scripts[k] = fn end
function methods:RegisterEvent(e) self.events[e] = true end
function methods:RegisterUnitEvent(e) self.events[e] = true end
function methods:CreateTexture() return object('Texture', nil, self) end
function methods:CreateFontString() return object('FontString', nil, self) end
function methods:IsShown() return self.shown end
function methods:Show() self.shown = true end
function methods:Hide() self.shown = false end
function methods:SetShown(v) self.shown = v and true or false end
function methods:SetCooldown(start, dur) self.cdStart, self.cdDur = start, dur end
function methods:Clear() self.cdStart, self.cdDur = nil, nil end

CreateFrame = object
UIParent = object('Frame')
C_Timer = { NewTicker = noop }

local now = 1000
GetTime = function() return now end

local STING, STING_R2, MARK, PROC = 1978, 13549, 1130, 500
local names = { [STING] = 'Serpent Sting', [STING_R2] = 'Serpent Sting', [MARK] = "Hunter's Mark", [PROC] = 'Quick Shots' }
C_Spell = {
    GetSpellName = function(id) return names[id] end,
    GetSpellTexture = function(id) return id end,
    GetSpellCooldown = function() return { startTime = 0, duration = 0, isEnabled = true } end,
    GetSpellCharges = function() return nil end,
    GetSpellInfo = function(text) for id, n in pairs(names) do if n == text and id ~= 13549 then return { spellID = id } end end end,
    GetSpellDescription = function(id) return id == STING and 'Stings the target, causing 20 Nature damage over 15 sec.' or '' end,
}

-- World model: one current target, and the debuffs each mob really has.
local target, locked = nil, false
local mobDebuffs = {}                  -- guid -> list of aura tables
UnitExists = function(unit) return unit == 'target' and target ~= nil end
UnitGUID = function(unit) return unit == 'target' and target or nil end
C_Secrets = { ShouldAurasBeSecret = function() return locked end, ShouldSpellAuraBeSecret = function() return locked end }
C_UnitAuras = {
    GetPlayerAuraBySpellID = function() if locked then error('secret') end return nil end,
    GetAuraDataByIndex = function(unit, i, filter)
        assert(unit == 'target' and filter == 'HARMFUL|PLAYER', 'debuffs must be read from the target, own casts only')
        if locked then error('Auras cannot be accessed when secret while tainted') end
        return (mobDebuffs[target] or {})[i]
    end,
}

ForeverCDMDB = { debuffs = { MARK, STING }, buffs = { PROC } }
assert(loadfile('ForeverCDM.lua'))('ForeverCDM')

local function fire(event, ...)
    for _, f in ipairs(frames) do
        if f.events[event] then f.scripts.OnEvent(f, event, ...) end
    end
end
fire('PLAYER_LOGIN')

local function iconFor(id, row)
    for _, f in ipairs(frames) do if f.spellID == id and f.parent == row then return f end end
end
assert(ForeverCDM_debuffs, 'the Debuffs row was not created')
local sting, mark, proc = iconFor(STING, ForeverCDM_debuffs), iconFor(MARK, ForeverCDM_debuffs), iconFor(PROC, ForeverCDM_buffs)
assert(sting and mark and proc, 'icons were not created')

-- 1. No target: dim.
assert(sting.alpha == 0.25, 'no target should leave the debuff dim')

-- 2. Target has a HIGHER RANK of the sting, readable: lit with the real timer, length learned.
target = 'mob-A'
mobDebuffs['mob-A'] = { { spellId = STING_R2, name = 'Serpent Sting', duration = 15, expirationTime = now + 15, auraInstanceID = 5 } }
fire('PLAYER_TARGET_CHANGED')
assert(sting.alpha == 1 and sting.cd.cdDur == 15, 'readable debuff (matched by name across ranks) should draw its real timer')
assert(ForeverCDMDB.buffDurations[STING] == 15, 'debuff duration was not learned')
assert(mark.alpha == 0.25, 'a debuff the target does not have stays dim')

-- 3. Swap to a clean mob: dim again.
target = 'mob-B'
fire('PLAYER_TARGET_CHANGED')
assert(sting.alpha == 0.25, 'a different target without the debuff should be dim')

-- 4. Combat locks aura reads. Casting on mob-B starts an estimate from our own clock.
locked = true
ForeverCDMDB.buffDurations[STING] = nil            -- force the tooltip fallback ("over 15 sec")
now = 1010
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', STING)
assert(sting.alpha == 0.85 and sting.cd.cdStart == 1010 and sting.cd.cdDur == 15, 'cast in combat should start a tooltip-length timer')

-- 5. The estimate belongs to mob-B only, and comes back when we swap back.
target = 'mob-C'
fire('PLAYER_TARGET_CHANGED')
assert(sting.alpha == 0.25, 'the estimate must not follow us to another target')
target = 'mob-B'
fire('PLAYER_TARGET_CHANGED')
assert(sting.alpha == 0.85 and sting.cd.cdStart == 1010, 'swapping back should restore that target\'s timer')

-- 6. It runs out on our own clock.
now = 1026
fire('UNIT_AURA', 'target', nil)
assert(sting.alpha == 0.25 and sting.cd.cdDur == nil, 'expired estimate should dim the icon')

-- 7. Hide inactive auras: absent icons vanish and the visible one slides into the first slot.
locked = false
mobDebuffs['mob-B'] = { { spellId = STING, name = 'Serpent Sting', duration = 15, expirationTime = now + 15, auraInstanceID = 6 } }
SlashCmdList.FOREVERCDM('hideinactive on')
assert(ForeverCDMDB.hideInactive == true, 'option was not stored')
assert(mark.alpha == 0 and proc.alpha == 0, 'inactive buff and debuff icons should be hidden')
assert(sting.alpha == 1 and sting.x == 0, 'the active debuff should be visible in the first slot')

-- 8. Unlocked rows show everything again, dimmed, so the bar can be seen while dragging.
ForeverCDM_SetLocked(false)
fire('UNIT_AURA', 'target', nil)
assert(mark.alpha == 0.25 and mark.x == 0 and sting.x > 0, 'unlocked rows should show inactive icons in their own slots')
ForeverCDM_SetLocked(true)

-- 9. Option off again: dimmed, original order.
SlashCmdList.FOREVERCDM('hideinactive off')
assert(mark.alpha == 0.25 and mark.x == 0 and sting.x > 0, 'turning the option off should restore dim icons in list order')

-- 10. Hunter's Mark pattern: applied BEFORE the pull (readable), then combat locks
--     aura reads. The timer must carry across on the real start time, not vanish.
now = 2000
target = 'mob-D'
mobDebuffs['mob-D'] = { { spellId = MARK, name = "Hunter's Mark", duration = 120, expirationTime = 2110, auraInstanceID = 9 } }
fire('PLAYER_TARGET_CHANGED')
assert(mark.alpha == 1 and mark.cd.cdStart == 1990, 'readable mark should draw from its real start')
locked = true
fire('UNIT_AURA', 'target', nil)
assert(mark.alpha == 0.85 and mark.cd.cdStart == 1990 and mark.cd.cdDur == 120, 'a pre-pull debuff must keep its timer once combat hides auras')
locked = false
mobDebuffs['mob-D'] = {}
fire('UNIT_AURA', 'target', nil)
assert(mark.alpha == 0.25, 'readable and absent means it really dropped')
locked = true
fire('UNIT_AURA', 'target', nil)
assert(mark.alpha == 0.25, 'a dropped debuff must not come back when combat starts')
locked = false

-- 11. Opener: Serpent Sting cast while auras are still readable, the aura lands a
--     moment later, and combat locks reads. The fresh estimate must survive.
now = 3000
target = 'mob-E'
mobDebuffs['mob-E'] = {}
fire('PLAYER_TARGET_CHANGED')
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', STING)   -- readable, aura not applied yet
assert(sting.alpha == 0.25, 'readable and absent right after the cast: not lit yet')
now = 3000.2
locked = true
fire('UNIT_AURA', 'target', nil)
assert(sting.alpha == 0.85 and sting.cd.cdStart == 3000, 'the opener estimate must not be discarded before the aura lands')

-- 12. /fcdm duration sets a length by hand.
SlashCmdList.FOREVERCDM("duration Hunter's Mark 120")
assert(ForeverCDMDB.buffDurations[MARK] == 120, '/fcdm duration did not store the length')

print('debuff bar, per-target estimates, hide-inactive and manual duration checks passed')
