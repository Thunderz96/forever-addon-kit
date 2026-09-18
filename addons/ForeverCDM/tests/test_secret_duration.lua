-- Focused regression harness for the actual updateCooldowns/updateBuffs functions.
-- Run with: lua tests/test_secret_duration.lua ForeverCDM.lua

local sourcePath = arg[1] or "ForeverCDM.lua"
local file = assert(io.open(sourcePath, "r"))
local source = file:read("*a")
file:close()

local function block(name, nextName)
    local start = assert(source:find("local function " .. name, 1, true))
    local finish = assert(source:find("local function " .. nextName, start, true))
    return source:sub(start, finish - 1):gsub("%s+$", "")
end

local secretValue = {}
local icons = { cds = {}, buffs = {} }
local db = { hideReady = true, buffDurations = {} }
local function secret(value) return value == secretValue end
local cooldownInfo, spellDuration, auraDuration
local spellCalls, auraCalls = 0, 0
local C_Spell = {
    GetSpellCooldown = function() return cooldownInfo end,
    GetSpellCooldownDuration = function() spellCalls = spellCalls + 1; return spellDuration end,
}
local C_UnitAuras = {
    GetPlayerAuraBySpellID = function() return icons.buffs[1].aura end,
    GetAuraDuration = function(unit, instanceID)
        assert(unit == "player" and instanceID == 7)
        auraCalls = auraCalls + 1
        return auraDuration
    end,
}

local cooldown = { calls = {} }
function cooldown:SetCooldown(start, duration, modRate)
    assert(not secret(start) and not secret(duration) and not secret(modRate), "raw SetCooldown received a secret")
    self.calls[#self.calls + 1] = { "raw", start, duration, modRate }
end
function cooldown:SetCooldownFromDurationObject(duration)
    assert(duration ~= nil, "duration-object sink received nil")
    self.calls[#self.calls + 1] = { "duration", duration }
end
function cooldown:Clear() self.calls[#self.calls + 1] = { "clear" } end

local function frame()
    return {
        cd = cooldown, spellID = 123,
        IsShown = function() return true end,
        SetAlpha = function(self, value) self.alpha = value end,
        icon = { SetDesaturated = function() end },
        count = { SetText = function() end },
    }
end
icons.cds[1] = frame()
icons.buffs[1] = frame()

local chunk = "local icons, db, secret, C_Spell, C_UnitAuras = ...; "
    .. block("updateCooldowns", "updateBuffs") .. "\n"
    .. block("updateBuffs", "refreshAll")
local updateCooldowns, updateBuffs = assert(load(chunk .. "\nreturn updateCooldowns, updateBuffs"))(icons, db, secret, C_Spell, C_UnitAuras)

cooldownInfo = { startTime = secretValue, duration = secretValue, modRate = secretValue, isEnabled = secretValue }
spellDuration = {}
updateCooldowns()
assert(spellCalls == 1 and cooldown.calls[#cooldown.calls][1] == "duration")
assert(icons.cds[1].alpha == 1, "unknown secret cooldown state must remain visible")

spellDuration = nil
updateCooldowns()
assert(cooldown.calls[#cooldown.calls][1] == "clear")

cooldownInfo = { startTime = 10, duration = 20, modRate = nil, isEnabled = true }
updateCooldowns()
local normal = cooldown.calls[#cooldown.calls]
assert(normal[1] == "raw" and normal[2] == 10 and normal[3] == 20 and normal[4] == 1)

icons.buffs[1].aura = { duration = secretValue, expirationTime = secretValue, auraInstanceID = 7, applications = 1 }
auraDuration = {}
updateBuffs()
assert(auraCalls == 1 and cooldown.calls[#cooldown.calls][1] == "duration")

icons.buffs[1].aura.auraInstanceID = secretValue
updateBuffs()
assert(auraCalls == 1 and cooldown.calls[#cooldown.calls][1] == "clear")

cooldownInfo.isEnabled = secretValue
cooldownInfo.modRate = secretValue
updateCooldowns()
assert(icons.cds[1].alpha == 1, "unknown enabled state must remain visible")

print("secret duration update regression checks passed")

-- A readable pre-combat instance can survive a restricted spell-ID lookup.
C_Secrets = { ShouldAurasBeSecret = function() return true end }
local tracked = { auraInstanceID = 7, duration = secretValue, expirationTime = secretValue, applications = 1 }
icons.buffs[1].auraInstanceID = 7
icons.buffs[1].aura = nil
C_UnitAuras.GetAuraDataByAuraInstanceID = function(unit, id)
    assert(unit == 'player' and id == 7)
    return tracked
end
updateBuffs()
assert(cooldown.calls[#cooldown.calls][1] == 'duration', 'known instance lost in combat')
tracked = nil
local callsBefore = #cooldown.calls
updateBuffs()
-- In combat every aura read is refused, so a buff known before combat keeps its
-- ticking duration object and is shown slightly dimmed, never cleared.
assert(icons.buffs[1].alpha == 0.85 and #cooldown.calls == callsBefore, 'known-before-combat aura must keep its swipe, dimmed')
icons.buffs[1].combatRemoved = true
updateBuffs()
assert(icons.buffs[1].alpha == 0.25 and cooldown.calls[#cooldown.calls][1] == 'clear', 'a removal reported by UNIT_AURA must clear it')
icons.buffs[1].combatRemoved = nil
icons.buffs[1].auraInstanceID = nil
updateBuffs()
assert(icons.buffs[1].alpha == 0.6 and cooldown.calls[#cooldown.calls][1] == 'clear', 'never-seen aura in combat is unknown')
C_Secrets.ShouldAurasBeSecret = function() return false end
updateBuffs()
assert(icons.buffs[1].alpha == 0.25 and icons.buffs[1].auraInstanceID == nil, 'confirmed absence must clear cached instance')
print('restricted aura lookup and recovery checks passed')
