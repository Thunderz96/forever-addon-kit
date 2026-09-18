-- ForeverCDM.lua -- a small cooldown manager that needs no Blizzard CDM data
-- Author: Thunderz
--
-- WHY: on the Forever beta, Blizzard's Cooldown Manager has no authored data
-- for Forever specs (every category empty, even with unlearned shown), so every
-- addon that skins it shows nothing. This reads the spellbook and the player's
-- auras directly and draws its own icon rows.
--
-- WHAT IT DOES: three rows of icons. "cds" and "utilities" show chosen spells
-- with cooldown swipes and charge counts. "buffs" shows selected player auras,
-- with a remaining-time swipe when readable. Display only: it never casts
-- and never makes decisions, so it stays inside the Midnight-era addon rules.
-- Secret timing values (in combat) are handed to the Cooldown widget as duration
-- objects; Lua never reads or compares the protected timing values.
--
-- COMMANDS (see /fcdm help):
--   /fcdm add <spell>         add a spell cooldown icon (name or spellID)
--   /fcdm addbuff <spell>     add a buff to watch on yourself
--   /fcdm remove <spell>      remove from either row
--   /fcdm auto                add every active, non-passive spellbook spell with a cooldown
--   /fcdm list | lock | unlock | size <px> | spacing <px> | reset

local ADDON = ...
local NAME = "|cffd2621fForever CDM|r"

local DEFAULTS = {
    size = 36, spacing = 4, locked = true,
    cds = {},     -- ordered list of spellIDs
    buffs = {},   -- ordered list of spellIDs
    utilities = {}, -- ordered list of utility spellIDs
    pos = { cds = { "CENTER", 0, -170 }, utilities = { "CENTER", 0, -220 }, buffs = { "CENTER", 0, -270 } },
    hideReady = false,  -- hide cooldown icons that are ready (off by default: it is a manager, not an alert)
    showNames = false,
}

local db
local rows = {}          -- key -> row frame
local icons = { cds = {}, utilities = {}, buffs = {} }
local BAR_KEYS = { "cds", "utilities", "buffs" }

local function say(fmt, ...) print(NAME .. ": " .. string.format(fmt, ...)) end

local function secret(v) return issecretvalue and issecretvalue(v) end

-- Settings ------------------------------------------------------------------

local function ensureDB()
    ForeverCDMDB = ForeverCDMDB or {}
    db = ForeverCDMDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then
            if type(v) == "table" then
                db[k] = {}
                for k2, v2 in pairs(v) do
                    if type(v2) == "table" then db[k][k2] = { unpack(v2) } else db[k][k2] = v2 end
                end
            else
                db[k] = v
            end
        end
    end
    -- Migration for existing profiles: never replace existing ordered lists or positions.
    db.utilities = db.utilities or {}
    db.pos.utilities = db.pos.utilities or { "CENTER", 0, -220 }
end

-- Spell helpers ---------------------------------------------------------------

local function resolveSpell(text)
    if not text or text == "" then return nil end
    local id = tonumber(text)
    if not id and C_Spell and C_Spell.GetSpellIDForSpellIdentifier then
        id = C_Spell.GetSpellIDForSpellIdentifier(text)
    end
    if not id and C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(text)
        id = info and info.spellID
    end
    return id
end

local function spellName(id)
    return (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or ("spell " .. tostring(id))
end

local function spellIcon(id)
    return (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(id)) or 134400
end

local function contains(list, id)
    for i, v in ipairs(list) do if v == id then return i end end
    return nil
end

-- Icon frames -------------------------------------------------------------------

local function newIcon(parent)
    local f = CreateFrame("Frame", nil, parent)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    f.cd:SetAllPoints()
    f.cd:SetDrawEdge(true)
    f.cd:SetHideCountdownNumbers(false)
    f.count = f:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    f.count:SetPoint("BOTTOMRIGHT", -2, 2)
    f.name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.name:SetPoint("TOP", f, "BOTTOM", 0, -1)
    f.name:Hide()
    f:EnableMouse(false)
    return f
end

local function layoutRow(key)
    local row = rows[key]
    local list = db[key]
    local size, gap = db.size, db.spacing
    local shown = 0
    for i, id in ipairs(list) do
        local f = icons[key][i]
        if not f then
            f = newIcon(row)
            icons[key][i] = f
        end
        if f.spellID ~= id then f.auraInstanceID = nil end
        f.spellID = id
        f.icon:SetTexture(spellIcon(id))
        f:SetSize(size, size)
        f.name:SetText(spellName(id))
        f.name:SetShown(db.showNames)
        f:ClearAllPoints()
        f:SetPoint("LEFT", row, "LEFT", shown * (size + gap), 0)
        f:Show()
        shown = shown + 1
    end
    for i = #list + 1, #icons[key] do icons[key][i]:Hide() end
    row:SetSize(math.max(shown, 1) * (size + gap) - gap, size)
    row.label:SetShown(not db.locked)
end

local function applyPosition(key)
    local row = rows[key]
    local p = db.pos[key]
    row:ClearAllPoints()
    row:SetPoint(p[1], UIParent, p[1], p[2], p[3])
end

local function newRow(key, label)
    local rowName = key == "utilities" and "ForeverCDM_utility" or "ForeverCDM_" .. key
    local row = CreateFrame("Frame", rowName, UIParent)
    row:SetSize(40, 40)
    row:SetMovable(true)
    row:SetClampedToScreen(true)
    row:EnableMouse(false)   -- switched on while unlocked so clicks pass through otherwise
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(0.82, 0.38, 0.12, 0.25)
    row.bg:Hide()
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.label:SetPoint("BOTTOM", row, "TOP", 0, 2)
    row.label:SetText(label .. "  (drag; /fcdm lock when done)")
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", function(self) if not db.locked then self:StartMoving() end end)
    row:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        db.pos[key] = { point, x, y }
    end)
    rows[key] = row
    return row
end

function ForeverCDM_SetLocked(locked)
    db.locked = locked
    for _, row in pairs(rows) do
        row:EnableMouse(not locked)
        row.bg:SetShown(not locked)
        row.label:SetShown(not locked)
        -- an empty row still needs something to grab
        if not locked and row:GetWidth() < 40 then row:SetSize(40, db.size) end
    end
end

-- Updates -------------------------------------------------------------------------

local function updateCooldowns(key)
    for _, f in ipairs(icons[key or "cds"]) do
        if f:IsShown() and f.spellID then
            local c = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(f.spellID)
            if c then
                -- Secret values go straight to the widget; it may draw what Lua may
                -- not read. Never "or"/compare them: even a boolean test throws.
                local onCD = false
                local cooldownStateKnown = true
                if secret(c.startTime) or secret(c.duration) then
                    cooldownStateKnown = false
                    local duration = C_Spell.GetSpellCooldownDuration and C_Spell.GetSpellCooldownDuration(f.spellID)
                    if duration and f.cd.SetCooldownFromDurationObject then
                        f.cd:SetCooldownFromDurationObject(duration)
                    else
                        f.cd:Clear()
                    end
                else
                    local modRate = not secret(c.modRate) and (c.modRate or 1) or 1
                    cooldownStateKnown = not secret(c.isEnabled)
                    local enabled = cooldownStateKnown and c.isEnabled ~= false
                    f.cd:SetCooldown(c.startTime or 0, c.duration or 0, modRate)
                    onCD = (c.duration or 0) > 1.5 and enabled
                end
                f.icon:SetDesaturated(onCD)
                f:SetAlpha((not db.hideReady or not cooldownStateKnown or onCD) and 1 or 0)
            end
            local ch = C_Spell and C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(f.spellID)
            if ch and not secret(ch.maxCharges) and (ch.maxCharges or 0) > 1 and not secret(ch.currentCharges) then
                f.count:SetText(ch.currentCharges)
            else
                f.count:SetText("")
            end
        end
    end
end

local function updateBuffs()
    local restricted = C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()
    for _, f in ipairs(icons.buffs) do
        if f:IsShown() and f.spellID then
            -- In combat this call THROWS rather than returning nil, so it must be
            -- protected or it burns the client's 100-error cap in under a minute.
            local okA, a = pcall(C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID or function() end, f.spellID)
            if not okA or secret(a) or (issecrettable and issecrettable(a)) then a = nil end
            -- A spell-ID lookup may stop identifying an aura during combat. Only
            -- reuse an instance we previously identified; never guess its spell.
            if not a and restricted and f.auraInstanceID and C_UnitAuras.GetAuraDataByAuraInstanceID then
                local ok, knownAura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", f.auraInstanceID)
                if ok and not secret(knownAura) then a = knownAura end
            end
            if a then
                if not secret(a.auraInstanceID) and a.auraInstanceID ~= nil then
                    f.auraInstanceID = a.auraInstanceID
                end
                f:SetAlpha(1)
                f.icon:SetDesaturated(false)
                local dur, exp = a.duration, a.expirationTime
                if secret(dur) or secret(exp) then
                    local duration
                    if C_UnitAuras.GetAuraDuration and not secret(a.auraInstanceID) and a.auraInstanceID ~= nil then
                        duration = C_UnitAuras.GetAuraDuration("player", a.auraInstanceID)
                    end
                    if duration and f.cd.SetCooldownFromDurationObject then
                        f.cd:SetCooldownFromDurationObject(duration)
                    else
                        f.cd:Clear()
                    end
                elseif dur and dur > 0 then
                    f.cd:SetCooldown(exp - dur, dur)
                else
                    f.cd:Clear()
                end
                if not secret(a.applications) and (a.applications or 0) > 1 then f.count:SetText(a.applications) else f.count:SetText("") end
            elseif restricted then
                -- In combat this client refuses EVERY aura read to addon code
                -- ("Auras cannot be accessed when secret while tainted"), so the
                -- aura cannot be confirmed. Keep the last known state: the duration
                -- object handed to the widget before combat keeps ticking on its
                -- own. Only the UNIT_AURA payload (see OnAuraEvent) can tell us it
                -- dropped; when it does, f.combatRemoved is set.
                if f.combatRemoved then
                    f:SetAlpha(0.25)
                    f.icon:SetDesaturated(true)
                    f.cd:Clear()
                    f.count:SetText("")
                elseif f.auraInstanceID then
                    f:SetAlpha(0.85)              -- known before combat, unverifiable now
                    f.icon:SetDesaturated(false)
                    f.count:SetText("")
                else
                    f:SetAlpha(0.6)
                    f.icon:SetDesaturated(false)
                    f.cd:Clear()
                    f.count:SetText("?")
                end
            else
                f.combatRemoved = nil
                f.auraInstanceID = nil
                f:SetAlpha(0.25)
                f.icon:SetDesaturated(true)
                f.cd:Clear()
                f.count:SetText("")
            end
        end
    end
end

-- UNIT_AURA carries an updateInfo payload (addedAuras / updatedAuraInstanceIDs /
-- removedAuraInstanceIDs). MEASURED on build 1.60.1.69893 (2026-09-17): out of
-- combat these are plain tables; in combat they are SECRET tables and
-- isFullUpdate a secret boolean, so a buff dropping off mid-fight cannot be
-- detected by addon code at all. Out of combat this path keeps things exact.
local auraDebugLeft = 0
local function onAuraEvent(unit, info)
    if unit ~= "player" then return end
    if type(info) ~= "table" or (issecrettable and issecrettable(info)) then
        if auraDebugLeft > 0 then auraDebugLeft = auraDebugLeft - 1 say("UNIT_AURA payload: %s", type(info)) end
        return
    end
    local full = not secret(info.isFullUpdate) and info.isFullUpdate
    if auraDebugLeft > 0 then
        auraDebugLeft = auraDebugLeft - 1
        local function readable(t) return type(t) == "table" and not (issecrettable and issecrettable(t)) end
        local function n(t) if t == nil then return "nil" end if secret(t) then return "S" end if not readable(t) then return "ST" end return tostring(#t) end
        -- Measured 2026-09-17: in combat these are secret tables; indexing one throws.
        local firstRemoved = readable(info.removedAuraInstanceIDs) and info.removedAuraInstanceIDs[1]
        local firstAdded = readable(info.addedAuras) and info.addedAuras[1]
        if firstAdded ~= nil and not readable(firstAdded) then firstAdded = nil end
        say("UNIT_AURA combat=%s full=%s added=%s updated=%s removed=%s | removed[1]=%s added[1].spellId=%s",
            tostring(InCombatLockdown()), tostring(full), n(info.addedAuras), n(info.updatedAuraInstanceIDs), n(info.removedAuraInstanceIDs),
            firstRemoved == nil and "nil" or (secret(firstRemoved) and "S" or tostring(firstRemoved)),
            type(firstAdded) == "table" and (secret(firstAdded.spellId) and "S" or tostring(firstAdded.spellId)) or "nil")
    end
    if full then return end
    local removed = info.removedAuraInstanceIDs
    if type(removed) == "table" and not (issecrettable and issecrettable(removed)) then
        for _, rid in ipairs(removed) do
            if not secret(rid) then
                for _, f in ipairs(icons.buffs) do
                    if f.auraInstanceID == rid then f.combatRemoved = true f.auraInstanceID = nil end
                end
            end
        end
    end
    local added = info.addedAuras
    if type(added) == "table" and not (issecrettable and issecrettable(added)) then
        for _, a in ipairs(added) do
            if type(a) == "table" and not (issecrettable and issecrettable(a)) and not secret(a.spellId) then
                for _, f in ipairs(icons.buffs) do
                    if f.spellID == a.spellId then
                        f.combatRemoved = nil
                        if not secret(a.auraInstanceID) then f.auraInstanceID = a.auraInstanceID end
                    end
                end
            end
        end
    end
end
ForeverCDM_AuraDebug = function(n) auraDebugLeft = n or 6 end

local function refreshAll()
    for _, key in ipairs(BAR_KEYS) do
        layoutRow(key)
        applyPosition(key)
    end
    updateCooldowns("cds")
    updateCooldowns("utilities")
    updateBuffs()
end

-- Auto-populate from the spellbook: active, non-passive spells that have a
-- cooldown longer than the global one.
local function autoPopulate()
    if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then say("spellbook API not available.") return 0 end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local added = 0
    for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if info then
            for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                local item = C_SpellBook.GetSpellBookItemInfo(i, bank)
                if item and item.spellID and not item.isPassive and not item.isOffSpec then
                    local id = item.spellID
                    local c = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(id)
                    local ch = C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(id)
                    local hasCD = false
                    if ch and not secret(ch.cooldownDuration) and (ch.cooldownDuration or 0) > 1.5 then hasCD = true end
                    if c and not secret(c.duration) and (c.duration or 0) > 1.5 then hasCD = true end
                    -- No base-cooldown API on this client; a spell not on cooldown right
                    -- now cannot be told from a no-cooldown spell, so also accept a
                    -- tooltip mention of "Cooldown".
                    if not hasCD and C_Spell.GetSpellDescription then
                        -- cheap heuristic: instant utility spells rarely say "cooldown"
                        local d = C_Spell.GetSpellDescription(id) or ""
                        hasCD = d:lower():find("cooldown", 1, true) ~= nil
                    end
                    if hasCD and not contains(db.cds, id) then
                        db.cds[#db.cds + 1] = id
                        added = added + 1
                    end
                end
            end
        end
    end
    return added
end

-- Shared with the config window.
ForeverCDM = ForeverCDM or {}
function ForeverCDM.GetDB() return db end
function ForeverCDM.Refresh() refreshAll() end
function ForeverCDM.SpellName(id) return spellName(id) end
function ForeverCDM.SpellIcon(id) return spellIcon(id) end
function ForeverCDM.Resolve(text) return resolveSpell(text) end
function ForeverCDM.Contains(list, id) return contains(list, id) end
function ForeverCDM.Auto() return autoPopulate() end

-- Events ---------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        ensureDB()
        newRow("cds", "Cooldowns")
        newRow("utilities", "Utilities")
        newRow("buffs", "Buffs")
        refreshAll()
        self:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        self:RegisterEvent("SPELL_UPDATE_CHARGES")
        self:RegisterUnitEvent("UNIT_AURA", "player")
        self:RegisterEvent("SPELLS_CHANGED")
        local ver = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"
        say("v%s loaded. /fcdm opens settings.", tostring(ver))
    elseif event == "UNIT_AURA" then
        onAuraEvent(...)
        updateBuffs()
    elseif event == "SPELLS_CHANGED" then
        refreshAll()
        if ForeverCDM_RefreshConfig then ForeverCDM_RefreshConfig() end
    else
        updateCooldowns("cds")
        updateCooldowns("utilities")
    end
end)

-- Light periodic refresh so buff swipes stay honest across secret transitions.
C_Timer.NewTicker(0.5, function() if db then updateBuffs() end end)

-- Slash ------------------------------------------------------------------------------

local HELP = {
    "/fcdm add <spell>       add a spell cooldown icon (name as in spellbook, or spellID)",
    "/fcdm addbuff <spell>   watch a buff on yourself (shows bright while active)",
    "/fcdm addutility <spell> add a spell to the Utility row",
    "/fcdm remove <spell>    remove from all rows",
    "/fcdm auto              add every spellbook spell that has a cooldown",
    "/fcdm list              show what is tracked",
    "/fcdm unlock | lock     drag the rows, then lock",
    "/fcdm size <px>         icon size (default 36)   /fcdm spacing <px>",
    "/fcdm hideready on|off  hide cooldown icons while ready",
    "/fcdm names on|off      show spell names under icons",
    "/fcdm reset             back to defaults",
}

SLASH_FOREVERCDM1 = "/fcdm"
SlashCmdList.FOREVERCDM = function(msg)
    msg = strtrim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = strlower(cmd or "")
    if not db then say("not loaded yet.") return end

    if cmd == "add" or cmd == "addbuff" or cmd == "addutility" then
        local id = resolveSpell(rest)
        if not id then say("no spell called \"%s\". Use the name from your spellbook, or a spellID.", rest) return end
        local key = cmd == "add" and "cds" or cmd == "addutility" and "utilities" or "buffs"
        if contains(db[key], id) then say("%s is already tracked.", spellName(id)) return end
        db[key][#db[key] + 1] = id
        refreshAll()
        say("added %s to %s.", spellName(id), key == "cds" and "Cooldowns" or key == "utilities" and "Utility" or "Buffs")

    elseif cmd == "remove" or cmd == "rem" or cmd == "del" then
        local id = resolveSpell(rest)
        local removed = false
        for _, key in ipairs(BAR_KEYS) do
            local i = id and contains(db[key], id)
            if i then table.remove(db[key], i) removed = true end
        end
        refreshAll()
        say(removed and ("removed " .. spellName(id) .. ".") or "nothing tracked by that name.")

    elseif cmd == "auto" then
        local n = autoPopulate()
        refreshAll()
        say("added %d spells from your spellbook. Remove any you do not want with /fcdm remove <spell>.", n)

    elseif cmd == "list" then
        for _, key in ipairs(BAR_KEYS) do
            local names = {}
            for _, id in ipairs(db[key]) do names[#names + 1] = spellName(id) end
            say("%s: %s", key == "cds" and "Cooldowns" or key == "utilities" and "Utility" or "Buffs", #names > 0 and table.concat(names, ", ") or "none")
        end

    elseif cmd == "unlock" or cmd == "lock" then
        ForeverCDM_SetLocked(cmd == "lock")
        say(db.locked and "locked." or "unlocked: drag the orange rows, then /fcdm lock.")

    elseif cmd == "" or cmd == "config" or cmd == "options" then
        if ForeverCDM_ToggleConfig then ForeverCDM_ToggleConfig() else say("config window not loaded.") end

    elseif cmd == "size" or cmd == "spacing" then
        local n = tonumber(rest)
        if not n then say("usage: /fcdm %s <pixels>", cmd) return end
        db[cmd] = math.max(cmd == "size" and 12 or 0, math.min(cmd == "size" and 96 or 30, n))
        refreshAll()

    elseif cmd == "hideready" or cmd == "names" then
        local on = rest == "on" or rest == "1" or rest == "true"
        if cmd == "hideready" then db.hideReady = on else db.showNames = on end
        for _, f in ipairs(icons.cds) do f:SetAlpha(1) end
        refreshAll()
        say("%s %s.", cmd, on and "on" or "off")

    elseif cmd == "probe" then
        -- What does each aura lookup return for this spell RIGHT NOW? Run it
        -- once out of combat and once in combat with the buff up.
        local id = resolveSpell(rest)
        if not id then say("usage: /fcdm probe <spell>") return end
        local function desc(v)
            if v == nil then return "nil" end
            if secret(v) then return "<secret " .. type(v) .. ">" end
            if issecrettable and issecrettable(v) then return "<secret table>" end
            if type(v) == "table" then
                local keys = {}
                for k, val in pairs(v) do keys[#keys + 1] = k .. "=" .. (secret(val) and "S" or tostring(val):sub(1, 12)) end
                table.sort(keys)
                return "{" .. table.concat(keys, " "):sub(1, 220) .. "}"
            end
            return tostring(v)
        end
        local okR, restricted = pcall(function() return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() end)
        say("probe %s (%d) | combat=%s aurasSecret=%s", spellName(id), id, tostring(InCombatLockdown()), tostring(okR and restricted))
        local ok1, a = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
        say("  GetPlayerAuraBySpellID -> ok=%s %s", tostring(ok1), desc(a))
        local inst = (ok1 and type(a) == "table" and not secret(a.auraInstanceID)) and a.auraInstanceID or nil
        for _, f in ipairs(icons.buffs) do if f.spellID == id and f.auraInstanceID then inst = inst or f.auraInstanceID end end
        say("  instance id in use: %s", tostring(inst))
        if inst and C_UnitAuras.GetAuraDataByAuraInstanceID then
            local ok2, b = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", inst)
            say("  GetAuraDataByAuraInstanceID -> ok=%s %s", tostring(ok2), ok2 and desc(b) or tostring(b):sub(1, 160))
        end
        if inst and C_UnitAuras.GetAuraDuration then
            local ok3, d = pcall(C_UnitAuras.GetAuraDuration, "player", inst)
            local extra = ""
            if ok3 and type(d) == "userdata" then
                local okH, h = pcall(function() return d:HasSecretValues() end)
                local okA, act = pcall(function() return d:IsActive() end)
                extra = string.format(" HasSecretValues=%s IsActive=%s", tostring(okH and h), tostring(okA and act))
            end
            say("  GetAuraDuration -> ok=%s type=%s%s", tostring(ok3), ok3 and type(d) or tostring(d):sub(1, 120), extra)
        end
        -- Slot walk, the way Blizzard's own buff frame finds auras.
        if AuraUtil and AuraUtil.ForEachAura then
            local n, hit = 0, nil
            local okW, errW = pcall(AuraUtil.ForEachAura, "player", "HELPFUL", nil, function(data)
                n = n + 1
                if type(data) == "table" and not secret(data.spellId) and data.spellId == id then hit = data end
            end, true)
            say("  ForEachAura HELPFUL -> ok=%s walked=%d match=%s", tostring(okW), n, hit and desc(hit) or tostring(okW and "none" or errW):sub(1, 120))
        end

    elseif cmd == "auradebug" then
        ForeverCDM_AuraDebug(tonumber(rest) or 6)
        say("printing the next %d UNIT_AURA payload summaries.", tonumber(rest) or 6)

    elseif cmd == "reset" then
        ForeverCDMDB = nil
        ensureDB()
        refreshAll()
        say("reset to defaults.")

    else
        say("commands:")
        for _, line in ipairs(HELP) do print("   " .. line) end
    end
end
