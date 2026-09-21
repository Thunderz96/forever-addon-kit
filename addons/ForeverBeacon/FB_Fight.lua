-- FB_Fight.lua -- can an addon follow a 1:1 fight on this client?
-- Author: Thunderz
--
-- Groundwork for a "will I win this fight?" predictor. That needs four numbers while in
-- combat: my health, the mob's health, damage coming in, damage going out. The modern
-- client hides some combat numbers from addons as "secret" values, and the classic
-- combat log event is gone, so this measures which of the four are still readable.
--
--   /fb fight         arm it; it reports by itself at the end of the next fight
--   /fb fight off     disarm

local ADDON, ns = ...

local function secret(v) return issecretvalue and issecretvalue(v) end
local function kind(v)
    if secret(v) then return "SECRET" end
    if v == nil then return "nil" end
    return type(v) == "number" and "number" or type(v)
end

local armed, f
local seen            -- what was observed during the fight
local function reset()
    seen = { samples = 0, health = {}, combat = { player = { n = 0, sum = 0, secret = 0 }, target = { n = 0, sum = 0, secret = 0 } } }
end

local HEALTH = {
    { "UnitHealth", UnitHealth }, { "UnitHealthMax", UnitHealthMax },
    { "UnitHealthPercent", UnitHealthPercent }, { "UnitHealthMissing", UnitHealthMissing },
}

local function sample()
    seen.samples = seen.samples + 1
    for _, unit in ipairs({ "player", "target" }) do
        for _, h in ipairs(HEALTH) do
            if h[2] then
                local ok, v = pcall(h[2], unit)
                local k = unit .. " " .. h[1]
                seen.health[k] = seen.health[k] or {}
                local what = ok and kind(v) or "ERROR"
                seen.health[k][what] = (seen.health[k][what] or 0) + 1
            end
        end
    end
end

local function report()
    ns.printf("fight: %d samples taken in combat.", seen.samples)
    local keys = {}
    for k in pairs(seen.health) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local parts = {}
        for what, n in pairs(seen.health[k]) do parts[#parts + 1] = what .. " x" .. n end
        ns.printf("fight: %-28s %s", k, table.concat(parts, ", "))
    end
    for _, unit in ipairs({ "player", "target" }) do
        local c = seen.combat[unit]
        ns.printf("fight: UNIT_COMBAT on %s: %d hits, %d readable damage total, %d secret amounts", unit, c.n, c.sum, c.secret)
    end
    if C_DamageMeter and C_DamageMeter.IsDamageMeterAvailable then
        local ok, avail = pcall(C_DamageMeter.IsDamageMeterAvailable)
        ns.printf("fight: built-in damage meter available: %s", ok and kind(avail) == "boolean" and tostring(avail) or kind(avail))
    end
    ns.printf("fight: combat log restricted: %s", C_CombatLog and C_CombatLog.IsCombatLogRestricted and tostring(C_CombatLog.IsCombatLogRestricted()) or "n/a")
end

function ns.Fight(arg)
    if (arg or ""):lower() == "off" then
        armed = false
        if f then f:UnregisterAllEvents() end
        ns.printf("fight: disarmed.")
        return
    end
    if not f then
        f = CreateFrame("Frame")
        f:SetScript("OnEvent", function(_, event, unit, action, _, amount)
            if event == "PLAYER_REGEN_DISABLED" then
                reset()
                f.ticker = C_Timer.NewTicker(0.5, sample)
            elseif event == "PLAYER_REGEN_ENABLED" then
                if f.ticker then f.ticker:Cancel() f.ticker = nil end
                if seen then report() end
            elseif event == "UNIT_COMBAT" and seen and (unit == "player" or unit == "target") then
                local c = seen.combat[unit]
                c.n = c.n + 1
                if secret(amount) then c.secret = c.secret + 1
                elseif type(amount) == "number" and action ~= "HEAL" then c.sum = c.sum + amount end
            end
        end)
    end
    armed = true
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:RegisterEvent("UNIT_COMBAT")
    ns.printf("fight: armed. Fight one mob solo; the report prints when combat ends. /fb fight off to stop.")
end
