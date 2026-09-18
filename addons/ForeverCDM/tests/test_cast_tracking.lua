-- Buff tracking in combat: per-spell secrecy, learned durations, cast-based timers.
-- Loads the real addon against a tiny fake UI. Run from ForeverCDM:
--   lua tests/test_cast_tracking.lua
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
-- widget calls the addon makes that the test does not care about
for _, name in ipairs({ 'SetTexCoord', 'ClearAllPoints', 'SetMovable', 'SetClampedToScreen', 'SetDrawEdge',
    'SetHideCountdownNumbers', 'SetDesaturated', 'SetCooldownFromDurationObject', 'SetAllPoints',
    'SetColorTexture', 'RegisterForDrag', 'SetPoint', 'SetTexture', 'EnableMouse' }) do methods[name] = noop end
function methods:SetSize(w, h) self.width, self.height = w, h end
function methods:GetWidth() return self.width or 100 end
function methods:SetText(t) self.textValue = t end
function methods:SetAlpha(a) self.alpha = a end
function methods:SetScript(k, fn) self.scripts[k] = fn end
function methods:RegisterEvent(e) self.events[e] = true end
function methods:RegisterUnitEvent(e) self.events[e] = true end
function methods:CreateTexture() return object('Texture', nil, self) end
function methods:CreateFontString() return object('FontString', nil, self) end
function methods:IsShown() return self.shown end
function methods:Show() self.shown = true end
function methods:Hide() self.shown = false end
function methods:SetShown(v) self.shown = v and true or false end
-- record what the cooldown widget was told
function methods:SetCooldown(start, dur) self.cdStart, self.cdDur = start, dur end
function methods:Clear() self.cdStart, self.cdDur = nil, nil end

CreateFrame = object
UIParent = object('Frame')
C_Timer = { NewTicker = noop }

local now = 1000
GetTime = function() return now end

local SEAL, SEAL_R2, OTHER = 201, 202, 300
local names = { [SEAL] = 'Seal of Testing', [SEAL_R2] = 'Seal of Testing', [OTHER] = 'Unrelated' }
C_Spell = {
    GetSpellName = function(id) return names[id] end,
    GetSpellTexture = function(id) return id end,
    GetSpellCooldown = function() return { startTime = 0, duration = 0, isEnabled = true } end,
    GetSpellCharges = function() return nil end,
}

-- Combat model: aurasLocked makes every aura read throw, as measured on the client.
local aurasLocked, auraUp = false, false
local neverSecret = {}
C_Secrets = {
    ShouldAurasBeSecret = function() return aurasLocked end,
    ShouldSpellAuraBeSecret = function(id) return aurasLocked and not neverSecret[id] end,
}
C_UnitAuras = {
    GetPlayerAuraBySpellID = function(id)
        if aurasLocked and not neverSecret[id] then error('Auras cannot be accessed when secret while tainted') end
        if auraUp and id == SEAL then
            return { auraInstanceID = 77, duration = 30, expirationTime = now + 30, applications = 1 }
        end
        return nil
    end,
}

ForeverCDMDB = { buffs = { SEAL } }
assert(loadfile('ForeverCDM.lua'))('ForeverCDM')

local function fire(event, ...)
    for _, f in ipairs(frames) do
        if f.events[event] then f.scripts.OnEvent(f, event, ...) end
    end
end
fire('PLAYER_LOGIN')

local icon
for _, f in ipairs(frames) do if f.spellID == SEAL and f.parent == ForeverCDM_buffs then icon = f end end
assert(icon, 'buff icon was not created')
assert(frames[1] and ForeverCDMDB.buffDurations, 'buffDurations table missing after login')

-- 1. Out of combat with the buff up: the real duration is learned.
auraUp = true
fire('UNIT_AURA', 'player', { isFullUpdate = true })
assert(ForeverCDMDB.buffDurations[SEAL] == 30, 'duration was not learned out of combat')
assert(icon.alpha == 1 and icon.cd.cdDur == 30, 'readable buff should draw its real timer')

-- 2. Buff drops out of combat, then combat starts: nothing known, so "?".
auraUp = false
fire('UNIT_AURA', 'player', { isFullUpdate = true })
assert(icon.alpha == 0.25, 'absent buff should be dim out of combat')
aurasLocked = true
fire('UNIT_AURA', 'player', { isFullUpdate = true })
assert(icon.count.textValue == '?', 'unknown buff in combat should show "?" before any cast')

-- 3. We cast a DIFFERENT RANK in combat: the name match starts a timer from
--    our own clock and the learned length. No aura read is involved.
now = 1010
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', SEAL_R2)
assert(icon.alpha == 0.85, 'cast in combat should light the icon')
assert(icon.cd.cdStart == 1010 and icon.cd.cdDur == 30, 'cast timer should be castAt + learned duration')
assert(icon.count.textValue == '', '"?" should clear once we saw the cast')

-- 4. An unrelated cast changes nothing.
now = 1015
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', OTHER)
assert(icon.cd.cdStart == 1010, 'unrelated cast must not restart the timer')

-- 5. Someone else's cast is ignored.
fire('UNIT_SPELLCAST_SUCCEEDED', 'target', 'cast-guid', SEAL)
assert(icon.cd.cdStart == 1010, "another unit's cast must be ignored")

-- 6. Our own timer runs out while still in combat: icon goes dim.
now = 1041
fire('UNIT_AURA', 'player', nil)
assert(icon.alpha == 0.25 and icon.cd.cdDur == nil, 'expired estimate should dim the icon')

-- 7. Recast, then leave combat with the buff really up: real data replaces the estimate.
now = 1050
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', SEAL)
assert(icon.alpha == 0.85, 'recast should relight the icon')
aurasLocked, auraUp = false, true
fire('UNIT_AURA', 'player', { isFullUpdate = true })
assert(icon.alpha == 1 and icon.cd.cdStart == now, 'real aura data should replace the estimate')

-- 8. A NeverSecret buff stays readable in combat: a failed read there means
--    "not up" (dim), not "unknown" ("?").
auraUp = false
fire('UNIT_AURA', 'player', { isFullUpdate = true })
neverSecret[SEAL] = true
aurasLocked = true
fire('UNIT_AURA', 'player', nil)
assert(icon.alpha == 0.25 and icon.count.textValue == '', 'NeverSecret buff that is absent should be dim, not "?"')
auraUp = true
fire('UNIT_AURA', 'player', nil)
assert(icon.alpha == 1 and icon.cd.cdDur == 30, 'NeverSecret buff should be read normally in combat')

-- 9. A secret spellID on the cast event is ignored rather than compared.
issecretvalue = function(v) return v == 'SECRET' end
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', 'SECRET')

print('cast tracking, learned durations, and per-spell secrecy checks passed')
