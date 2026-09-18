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
local persistSoon        -- defined in the settings-mirror section; called wherever settings change
local lateMirror         -- defined just above the event frame

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
    db.buffDurations = db.buffDurations or {}   -- spellID -> seconds, learned out of combat
    db.minimap = db.minimap or { angle = 215, hide = false }
    -- Each bar has its own icon size and spacing. Older profiles had one pair
    -- for all bars (db.size / db.spacing), which seeds the per-bar values once.
    db.rowSize = db.rowSize or {}
    db.rowSpacing = db.rowSpacing or {}
    for _, key in ipairs(BAR_KEYS) do
        db.rowSize[key] = db.rowSize[key] or db.size
        db.rowSpacing[key] = db.rowSpacing[key] or db.spacing
    end
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
    local size, gap = db.rowSize[key], db.rowSpacing[key]
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
        persistSoon()
    end)
    rows[key] = row
    return row
end

function ForeverCDM_SetLocked(locked)
    db.locked = locked
    for key, row in pairs(rows) do
        row:EnableMouse(not locked)
        row.bg:SetShown(not locked)
        row.label:SetShown(not locked)
        -- an empty row still needs something to grab
        if not locked and row:GetWidth() < 40 then row:SetSize(40, db.rowSize[key]) end
    end
    persistSoon()
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

-- Spell ranks. Forever lists every rank of a spell as its own spellbook entry
-- with its own spellID, so "Seal of Righteousness" can be three IDs. rankText
-- holds the label ("Rank 2"); siblings maps an ID to every ID sharing its name,
-- so a buff ticked as Rank 1 still lights up when you cast Rank 2.
local rankText, siblings = {}, {}

local function buildRankIndex()
    rankText, siblings = {}, {}
    if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then return end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local byName = {}
    for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if info then
            for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                local item = C_SpellBook.GetSpellBookItemInfo(i, bank)
                if item and item.spellID and not item.isPassive then
                    local sub = item.subName
                    if (not sub or sub == "") and C_Spell and C_Spell.GetSpellSubtext then
                        sub = C_Spell.GetSpellSubtext(item.spellID)
                    end
                    if sub and sub ~= "" then rankText[item.spellID] = sub end
                    local name = item.name or item.spellID
                    byName[name] = byName[name] or {}
                    table.insert(byName[name], item.spellID)
                end
            end
        end
    end
    for _, ids in pairs(byName) do
        if #ids > 1 then
            for _, id in ipairs(ids) do siblings[id] = ids end
        end
    end
end

-- "Rank 12" -> 12; 0 when the spell has no numbered rank.
local function rankNumber(id)
    return tonumber((rankText[id] or ""):match("%d+")) or 0
end

-- Is THIS spell's aura secret right now? The client answers per spell
-- (C_Secrets.ShouldSpellAuraBeSecret), which is finer than the global
-- ShouldAurasBeSecret: a buff Blizzard marks NeverSecret stays readable in
-- combat, so a failed read there means "not up", not "unknowable".
-- Technique seen in Bodify/BetterBlizzFrames (forever/modules/auras.lua).
local function spellAuraSecret(id, globalRestricted)
    if not globalRestricted then return false end
    if C_Secrets and C_Secrets.ShouldSpellAuraBeSecret then
        local ok, s = pcall(C_Secrets.ShouldSpellAuraBeSecret, id)
        if ok and not secret(s) and s == false then return false end
    end
    return true
end

local function updateBuffs()
    local globalRestricted = C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()
    for _, f in ipairs(icons.buffs) do
        if f:IsShown() and f.spellID then
            local restricted = spellAuraSecret(f.spellID, globalRestricted)
            -- In combat this call THROWS rather than returning nil, so it must be
            -- protected or it burns the client's 100-error cap in under a minute.
            local okA, a = pcall(C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID or function() end, f.spellID)
            if not okA or secret(a) or (issecrettable and issecrettable(a)) then a = nil end
            -- Not up under this exact ID: it may be up as another rank of the same spell.
            if not a and siblings[f.spellID] then
                for _, sid in ipairs(siblings[f.spellID]) do
                    if sid ~= f.spellID then
                        local okS, s = pcall(C_UnitAuras.GetPlayerAuraBySpellID, sid)
                        if okS and s and not secret(s) and not (issecrettable and issecrettable(s)) then a = s break end
                    end
                end
            end
            -- A spell-ID lookup may stop identifying an aura during combat. Only
            -- reuse an instance we previously identified; never guess its spell.
            if not a and restricted and f.auraInstanceID and C_UnitAuras.GetAuraDataByAuraInstanceID then
                local ok, knownAura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", f.auraInstanceID)
                if ok and not secret(knownAura) then a = knownAura end
            end
            if a then
                f.castAt = nil   -- real aura data beats our cast-based estimate
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
                    -- Remember how long this buff lasts. In combat the aura is
                    -- unreadable, but our own cast event plus this number is
                    -- enough to draw an honest timer (see onPlayerCast).
                    if db.buffDurations[f.spellID] ~= dur then
                        db.buffDurations[f.spellID] = dur
                        persistSoon()
                    end
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
                local learned = db.buffDurations[f.spellID]
                if f.castAt and learned and GetTime() > f.castAt + learned then
                    f.castAt = nil
                    f.combatRemoved = true        -- our own timer says it ran out
                end
                if f.combatRemoved then
                    f:SetAlpha(0.25)
                    f.icon:SetDesaturated(true)
                    f.cd:Clear()
                    f.count:SetText("")
                elseif f.castAt then
                    -- We saw ourselves cast it this fight (onPlayerCast). Start
                    -- time is our own clock and the length is one we measured
                    -- out of combat, so neither number is secret.
                    f:SetAlpha(0.85)
                    f.icon:SetDesaturated(false)
                    if learned then f.cd:SetCooldown(f.castAt, learned) else f.cd:Clear() end
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
                f.castAt = nil
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

-- Our own casts stay readable in combat even though our auras do not, so a
-- tracked buff we cast ourselves can be followed by its cast event instead.
-- Matching by name as well as ID covers other ranks of the same spell.
-- Technique seen in Pirson-s-Addons/SealTimersForever (MIT).
local function onPlayerCast(unit, _, spellID)
    if unit ~= "player" or spellID == nil or secret(spellID) then return end
    local castName
    for _, f in ipairs(icons.buffs) do
        if f.spellID then
            local hit = f.spellID == spellID
            if not hit then
                castName = castName or spellName(spellID)
                hit = castName == spellName(f.spellID)
            end
            if hit then
                f.castAt = GetTime()
                f.combatRemoved = nil
            end
        end
    end
end

local function refreshAll()
    for _, key in ipairs(BAR_KEYS) do
        layoutRow(key)
        applyPosition(key)
    end
    updateCooldowns("cds")
    updateCooldowns("utilities")
    updateBuffs()
    persistSoon()      -- every settings change funnels through here
end

-- Auto-populate from the spellbook: active, non-passive spells that have a
-- cooldown longer than the global one. Only the highest rank of each spell.
local function autoPopulate()
    if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then say("spellbook API not available.") return 0 end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local added = 0
    for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if info then
            for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                local item = C_SpellBook.GetSpellBookItemInfo(i, bank)
                local topRank = true
                if item and item.spellID and siblings[item.spellID] then
                    for _, sid in ipairs(siblings[item.spellID]) do
                        if rankNumber(sid) > rankNumber(item.spellID) then topRank = false end
                    end
                end
                if item and item.spellID and not item.isPassive and not item.isOffSpec and topRank then
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

-- Settings mirror ---------------------------------------------------------------------
-- WHY: the Forever beta client writes addon SavedVariables on exit and never
-- loads them at the next launch, so every addon starts from defaults.
--
-- MEASURED 2026-09-18 on build 1.60.1.69893: CVars an addon registers itself do
-- NOT reach disk, even after a clean logout (config-cache.wtf only ever holds
-- Blizzard's own CVars). A macro created through the API DOES survive a cold
-- start. So the mirror lives in an account macro, one per character.
--
-- Rules:
--   * Opt-in (db.macroMirror): nobody gets a macro they did not ask for. The
--     macro existing is itself the "on" flag, so the choice survives too.
--   * A SavedVariables table that did load always wins; the macro is only
--     applied when it came back empty. Once Blizzard fixes the client this
--     never restores anything.
--   * Never write before reading. On a cold start the macro list can arrive
--     after PLAYER_LOGIN; saving first would replace the stored setup with
--     defaults. Writes wait for mirror.ready.
--   * The body is a real slash command, so clicking the macro explains itself
--     instead of sending the text to /say.
--   * Macro edits are blocked in combat; a pending write waits for it to end.
local MIRROR_DATA, MIRROR_MACROS = 235, 3      -- data characters per macro, macros per character
local MIRROR_ICON = "INV_Misc_Gear_01"
local mirror = { hadSV = false, found = 0, restored = false, ready = false, wrote = 0, note = "nothing written yet" }
local mirrorDirty, hinted = false, false

local function mirrorName(i)
    -- hashed so any character name, in any alphabet, gives a short plain macro name (16 character limit)
    local who = tostring(UnitName and UnitName("player") or "") .. "-" .. tostring(GetRealmName and GetRealmName() or "")
    local h = 5381
    for c = 1, #who do h = (h * 33 + who:byte(c)) % 2147483647 end
    return string.format("FCDM%08x%d", h, i)
end

local function macroAPI()
    return CreateMacro and EditMacro and DeleteMacro and GetMacroBody and GetMacroIndexByName and true or false
end

local function encodeSettings(withDurations)
    local parts = {}
    local function put(k, v) parts[#parts + 1] = k .. "=" .. v end
    put("v", "1")
    put("L", db.locked and "1" or "0")
    put("hr", db.hideReady and "1" or "0")
    put("sn", db.showNames and "1" or "0")
    put("mm", string.format("%d,%s", math.floor((db.minimap.angle or 215) + 0.5), db.minimap.hide and "1" or "0"))
    local sz, gp = {}, {}
    for i, key in ipairs(BAR_KEYS) do sz[i], gp[i] = db.rowSize[key], db.rowSpacing[key] end
    put("sz", table.concat(sz, ","))
    put("gp", table.concat(gp, ","))
    for _, key in ipairs(BAR_KEYS) do
        local tag = key:sub(1, 1)                  -- c, u, b
        put("i" .. tag, table.concat(db[key], ","))
        local p = db.pos[key]
        put("p" .. tag, string.format("%s,%.1f,%.1f", tostring(p[1]), p[2] or 0, p[3] or 0))
    end
    if withDurations then
        local dur = {}
        for _, id in ipairs(db.buffs) do
            if db.buffDurations[id] then dur[#dur + 1] = id .. ":" .. string.format("%.1f", db.buffDurations[id]) end
        end
        put("d", table.concat(dur, ","))
    end
    return table.concat(parts, ";")
end

local function applySettings(s)
    local t = {}
    for k, v in s:gmatch("([^;=]+)=([^;]*)") do t[k] = v end
    if t.v ~= "1" then return false end
    local function nums(str)
        local out = {}
        for n in (str or ""):gmatch("[^,]+") do out[#out + 1] = tonumber(n) end
        return out
    end
    db.locked = t.L ~= "0"
    db.hideReady = t.hr == "1"
    db.showNames = t.sn == "1"
    local angle, hide = (t.mm or ""):match("^(-?%d+),(%d)$")
    if angle then db.minimap.angle, db.minimap.hide = tonumber(angle), hide == "1" end
    local sz, gp = nums(t.sz), nums(t.gp)
    for i, key in ipairs(BAR_KEYS) do
        if sz[i] then db.rowSize[key] = sz[i] end
        if gp[i] then db.rowSpacing[key] = gp[i] end
        local tag = key:sub(1, 1)
        if t["i" .. tag] then db[key] = nums(t["i" .. tag]) end
        local point, x, y = (t["p" .. tag] or ""):match("^(%a+),(-?[%d%.]+),(-?[%d%.]+)$")
        if point then db.pos[key] = { point, tonumber(x), tonumber(y) } end
    end
    for id, dur in (t.d or ""):gmatch("(%d+):([%d%.]+)") do
        db.buffDurations[tonumber(id)] = tonumber(dur)
    end
    return true
end

-- The stored string, or nil. Each macro body is "/fcdm store <i>/<n> <data>".
local function readMirror()
    if not macroAPI() then return nil end
    local parts, total = {}, nil
    for i = 1, MIRROR_MACROS do
        local ok, index = pcall(GetMacroIndexByName, mirrorName(i))
        if not ok or not index or index == 0 then break end
        local okB, body = pcall(GetMacroBody, index)
        local n, of, data = (okB and body or ""):match("^/fcdm store (%d+)/(%d+) (.*)$")
        if tonumber(n) ~= i then break end
        total = total or tonumber(of)
        parts[i] = data
        if i == total then break end
    end
    if not total or #parts ~= total then return nil end
    return table.concat(parts)
end

local function deleteMirror()
    if not macroAPI() then return end
    for i = MIRROR_MACROS, 1, -1 do
        local ok, index = pcall(GetMacroIndexByName, mirrorName(i))
        if ok and index and index > 0 then pcall(DeleteMacro, index) end
    end
end

local function writeMirror()
    mirrorDirty = false
    if not (db and db.macroMirror and mirror.ready) then return end
    if not macroAPI() then mirror.note = "this client has no macro API" return end
    if InCombatLockdown and InCombatLockdown() then
        mirror.note = "waiting for combat to end"
        mirror.afterCombat = true          -- PLAYER_REGEN_ENABLED picks this up
        return
    end
    local s = encodeSettings(true)
    if #s > MIRROR_DATA * MIRROR_MACROS then s = encodeSettings(false) end      -- durations are re-learnable
    if #s > MIRROR_DATA * MIRROR_MACROS then                                    -- keep the last good copy
        mirror.note = "settings too large for the macro; the last saved copy was kept"
        return
    end
    local n = math.max(1, math.ceil(#s / MIRROR_DATA))
    for i = 1, MIRROR_MACROS do
        local name = mirrorName(i)
        local ok, index = pcall(GetMacroIndexByName, name)
        index = ok and index or 0
        if i <= n then
            local body = string.format("/fcdm store %d/%d %s", i, n, s:sub((i - 1) * MIRROR_DATA + 1, i * MIRROR_DATA))
            if index > 0 then
                pcall(EditMacro, index, nil, nil, body)
            else
                local okC, made = pcall(CreateMacro, name, MIRROR_ICON, body, nil)
                if not okC or not made then
                    mirror.note = "could not create the macro (are all 120 general macro slots full?)"
                    return
                end
            end
        elseif index > 0 then
            pcall(DeleteMacro, index)      -- a shorter save needs fewer macros
        end
    end
    mirror.wrote = #s
    mirror.note = #s .. " characters in " .. n .. (n == 1 and " macro" or " macros")
end

persistSoon = function()
    if db and not db.macroMirror and not mirror.hadSV and not hinted and mirror.ready then
        hinted = true
        say("heads up: the beta client forgets addon settings when the game restarts. Tick \"Keep settings in a macro\" in /fcdm to keep this setup.")
    end
    if mirrorDirty then return end
    mirrorDirty = true
    if C_Timer and C_Timer.After then C_Timer.After(1, writeMirror) else writeMirror() end
end

-- Called at login and again once the macro list has certainly loaded.
-- Returns true when settings were restored from the macro.
local function mirrorLogin(final)
    if mirror.ready then return false end
    local stored = readMirror()
    if stored then
        mirror.found = #stored
        db.macroMirror = true                       -- the macro existing is the opt-in
        if not mirror.hadSV then mirror.restored = applySettings(stored) end
    end
    if stored or final then mirror.ready = true end
    return stored ~= nil and mirror.restored
end

function ForeverCDM_SetMacroMirror(on)
    db.macroMirror = on and true or false
    if on then
        persistSoon()
    elseif InCombatLockdown and InCombatLockdown() then
        say("the settings macro will be removed when combat ends.")
        mirror.deleteAfterCombat = true
    else
        deleteMirror()
        mirror.note = "off; macro removed"
    end
end

-- Shared with the config window.
ForeverCDM = ForeverCDM or {}
function ForeverCDM.Persist() persistSoon() end
function ForeverCDM.SpellRank(id) return rankText[id] end
function ForeverCDM.RankNumber(id) return rankNumber(id) end
function ForeverCDM.GetDB() return db end
function ForeverCDM.Refresh() refreshAll() end
function ForeverCDM.SpellName(id) return spellName(id) end
function ForeverCDM.SpellIcon(id) return spellIcon(id) end
function ForeverCDM.Resolve(text) return resolveSpell(text) end
function ForeverCDM.Contains(list, id) return contains(list, id) end
function ForeverCDM.Auto() return autoPopulate() end

-- Events ---------------------------------------------------------------------------

local RESTORED_MSG = "the client did not load saved settings (beta bug), so they were restored from your settings macro."

-- The macro list can arrive after PLAYER_LOGIN on a cold start. Until the mirror
-- has been read (or is known to be absent) nothing is written to it.
function lateMirror(final)
    if mirror.ready then return end
    if mirrorLogin(final) then
        say(RESTORED_MSG)
        refreshAll()
        if ForeverCDM_InitMinimap then ForeverCDM_InitMinimap() end
        if ForeverCDM_RefreshConfig then ForeverCDM_RefreshConfig() end
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("UPDATE_MACROS")     -- from file load, so an early firing is not missed
ev:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        -- Did the client hand us saved settings? On the beta it never does.
        mirror.hadSV = type(ForeverCDMDB) == "table" and next(ForeverCDMDB) ~= nil
        ensureDB()
        -- If UPDATE_MACROS already fired, the macro list is loaded and this read is final.
        if mirrorLogin(mirror.macrosSeen) then say(RESTORED_MSG) end
        buildRankIndex()
        newRow("cds", "Cooldowns")
        newRow("utilities", "Utilities")
        newRow("buffs", "Buffs")
        refreshAll()
        self:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        self:RegisterEvent("SPELL_UPDATE_CHARGES")
        self:RegisterUnitEvent("UNIT_AURA", "player")
        self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        self:RegisterEvent("SPELLS_CHANGED")
        self:RegisterEvent("PLAYER_LOGOUT")
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        -- Still waiting for the macro list: UPDATE_MACROS will say when it has
        -- arrived. The timer only covers a client where that event never fires.
        if not mirror.ready and C_Timer and C_Timer.After then C_Timer.After(15, function() lateMirror(true) end) end
        local ver = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"
        say("v%s loaded. /fcdm opens settings.", tostring(ver))
        if ForeverCDM_InitMinimap then ForeverCDM_InitMinimap() end
    elseif event == "UNIT_AURA" then
        onAuraEvent(...)
        updateBuffs()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        onPlayerCast(...)
        updateBuffs()
    elseif event == "PLAYER_LOGOUT" then
        writeMirror()        -- flush anything still waiting on the debounce
    elseif event == "UPDATE_MACROS" then
        mirror.macrosSeen = true
        if db then lateMirror(true) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if mirror.deleteAfterCombat then mirror.deleteAfterCombat = nil deleteMirror() end
        if mirror.afterCombat then mirror.afterCombat = nil writeMirror() end
    elseif event == "SPELLS_CHANGED" then
        buildRankIndex()
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
    "/fcdm size [bar] <px>   icon size, all bars or one of cds|utility|buffs. Same for /fcdm spacing",
    "/fcdm mirror [on|off]   keep settings in a macro, because the beta client forgets them on restart",
    "/fcdm hideready on|off  hide cooldown icons while ready",
    "/fcdm names on|off      show spell names under icons",
    "/fcdm minimap           show or hide the minimap button",
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
        -- "/fcdm size 40" sets every bar; "/fcdm size buffs 30" sets one.
        local which, value = rest:match("^(%a+)%s+(%-?%d+)$")
        local n = tonumber(value or rest)
        local alias = { cds = "cds", cd = "cds", cooldowns = "cds", utility = "utilities", utilities = "utilities",
                        util = "utilities", buffs = "buffs", buff = "buffs" }
        local key = which and alias[strlower(which)]
        if not n or (which and not key) then
            say("usage: /fcdm %s [cds|utility|buffs] <pixels>", cmd)
            return
        end
        n = math.max(cmd == "size" and 12 or 0, math.min(cmd == "size" and 96 or 30, n))
        local field = cmd == "size" and "rowSize" or "rowSpacing"
        for _, k in ipairs(BAR_KEYS) do
            if not key or k == key then db[field][k] = n end
        end
        refreshAll()
        if ForeverCDM_RefreshConfig then ForeverCDM_RefreshConfig() end

    elseif cmd == "mirror" then
        -- State of the saved-settings workaround; see the settings-mirror section.
        if rest == "on" or rest == "off" then
            ForeverCDM_SetMacroMirror(rest == "on")
            if ForeverCDM_RefreshConfig then ForeverCDM_RefreshConfig() end
        end
        say("settings macro is %s. Saved settings at login %s; the macro held %d characters at login and %s. Last write: %s.",
            db.macroMirror and "ON" or "OFF (turn on with /fcdm mirror on)",
            mirror.hadSV and "LOADED, so the macro was not needed" or "were EMPTY (beta bug)",
            mirror.found, mirror.restored and "was restored" or "was not applied", mirror.note)

    elseif cmd == "store" then
        -- What the settings macro runs if someone clicks it.
        say("this macro holds your Forever Cooldown Manager setup, because the beta client forgets addon settings. It is read automatically at login; clicking it does nothing. Turn it off with /fcdm mirror off.")

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
        if C_Secrets and C_Secrets.GetSpellAuraSecrecy then
            -- Per-spell secrecy: a NeverSecret buff should stay readable in combat.
            local levels = { [0] = "NeverSecret", [1] = "AlwaysSecret", [2] = "ContextuallySecret" }
            local okS, lvl = pcall(C_Secrets.GetSpellAuraSecrecy, id)
            local okN, now = pcall(C_Secrets.ShouldSpellAuraBeSecret, id)
            say("  aura secrecy: base=%s secretNow=%s | learned duration=%s",
                (okS and not secret(lvl)) and (levels[lvl] or tostring(lvl)) or "?",
                (okN and not secret(now)) and tostring(now) or "?", tostring(db.buffDurations[id]))
        end
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

    elseif cmd == "minimap" then
        if ForeverCDM_SetMinimapShown then
            ForeverCDM_SetMinimapShown(db.minimap.hide)   -- hide=true means show it now
            say("minimap button %s.", db.minimap.hide and "hidden" or "shown")
            if ForeverCDM_RefreshConfig then ForeverCDM_RefreshConfig() end
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
