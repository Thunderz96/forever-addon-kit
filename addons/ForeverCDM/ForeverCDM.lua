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
--   /fcdm adddebuff <spell>   add one of your debuffs to watch on your target
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
    debuffs = {},   -- ordered list of spellIDs: your own debuffs on the target (Serpent Sting...)
    pos = { cds = { "CENTER", 0, -170 }, utilities = { "CENTER", 0, -220 }, buffs = { "CENTER", 0, -270 }, debuffs = { "CENTER", 0, -320 } },
    hideReady = false,  -- hide cooldown icons that are ready (off by default: it is a manager, not an alert)
    hideInactive = false, -- hide buff/debuff icons while the aura is not up (off: they stay dimmed)
    showNames = false,
}

local db
local rows = {}          -- key -> row frame
local icons = { cds = {}, utilities = {}, buffs = {}, debuffs = {} }
-- New bars go on the END: the settings macro stores sizes by position in this list.
local BAR_KEYS = { "cds", "utilities", "buffs", "debuffs" }
local BAR_LABEL = { cds = "Cooldowns", utilities = "Utility", buffs = "Buffs", debuffs = "Debuffs" }
local persistSoon        -- defined in the settings-mirror section; called wherever settings change
local lateMirror         -- defined just above the event frame
local editModeActive = false

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
    db.anchors = db.anchors or {} -- key -> { globally named frame, x, y }, offsets in UIParent units
    db.pos.utilities = db.pos.utilities or { "CENTER", 0, -220 }
    db.debuffs = db.debuffs or {}
    db.pos.debuffs = db.pos.debuffs or { "CENTER", 0, -320 }
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

-- Items share the bars with spells. An entry below zero is an item: -6948 is
-- item 6948. That keeps every list a plain list of numbers, so ordering, the
-- settings macro and the config window need no second code path.
local function resolveSpell(text)
    if not text or text == "" then return nil end
    local itemID = text:match("item:(%d+)")            -- "item:6948" or a pasted item link
    if itemID then return -tonumber(itemID) end
    local id = tonumber(text)
    if not id and C_Spell and C_Spell.GetSpellIDForSpellIdentifier then
        id = C_Spell.GetSpellIDForSpellIdentifier(text)
    end
    if not id and C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(text)
        id = info and info.spellID
    end
    if not id and C_Item and C_Item.GetItemInfoInstant then   -- an item name the client already knows
        local known = C_Item.GetItemInfoInstant(text)
        if known then id = -known end
    end
    return id
end

local itemNamesPending = false      -- an item name was not cached yet; GET_ITEM_INFO_RECEIVED will refresh

local function spellName(id)
    if id < 0 then
        local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(-id)
        if not name then
            itemNamesPending = true
            if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(-id) end
        end
        return name or ("item " .. -id)
    end
    return (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or ("spell " .. tostring(id))
end

local function spellIcon(id)
    if id < 0 then return (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(-id)) or 134400 end
    return (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(id)) or 134400
end

local function contains(list, id)
    for i, v in ipairs(list) do if v == id then return i end end
    return nil
end

-- Icon frames -------------------------------------------------------------------

local function canMoveRows()
    return (editModeActive or not db.locked) and not (InCombatLockdown and InCombatLockdown())
end

local function updateRowInteraction(key)
    local row = rows[key]
    local movable = canMoveRows()
    row:EnableMouse(movable)
    row.bg:SetShown(movable)
    row.label:SetShown(movable)
    row.label:SetText("Forever CDM: " .. row.title .. (editModeActive
        and "  (drag; right-click to anchor)" or "  (drag; /fcdm lock when done)"))
    -- Empty bars still need a handle in Edit Mode.
    if movable and row:GetWidth() < 40 then row:SetSize(40, db.rowSize[key]) end
end

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
        f.slot = shown
        f:Show()
        shown = shown + 1
    end
    for i = #list + 1, #icons[key] do icons[key][i]:Hide() end
    row:SetSize(math.max(shown, 1) * (size + gap) - gap, size)
    updateRowInteraction(key)
end

local function frameCenter(frame)
    if not frame or not frame.GetCenter or not frame.GetEffectiveScale then return end
    local ok, x, y = pcall(frame.GetCenter, frame)
    if not ok or secret(x) or secret(y) or type(x) ~= "number" or type(y) ~= "number" then return end
    local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return x * scale, y * scale
end

local function anchorTarget(key, name)
    if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then return end
    local target = _G[name]
    if (type(target) ~= "table" and type(target) ~= "userdata")
        or not target.IsObjectType or not target:IsObjectType("Frame") then return end
    -- Check both live anchor/parent dependencies and saved row targets. The
    -- latter matter while a frame is still loading or temporarily being dragged.
    local seen, count = {}, 0
    local function dependsOnRow(frame)
        if frame == rows[key] then return true end
        if not frame or frame == UIParent or seen[frame] then return false end
        seen[frame] = true
        count = count + 1
        if count > 100 then return true end -- refuse an unexpectedly deep graph
        for otherKey, otherRow in pairs(rows) do
            local a = db.anchors[otherKey]
            if frame == otherRow and a and dependsOnRow(_G[a[1]]) then return true end
        end
        if frame.GetParent and dependsOnRow(frame:GetParent()) then return true end
        for i = 1, (frame.GetNumPoints and frame:GetNumPoints() or 0) do
            local _, relativeTo = frame:GetPoint(i)
            if dependsOnRow(relativeTo) then return true end
        end
        return false
    end
    local ok, cyclic = pcall(dependsOnRow, target)
    if ok and not cyclic then return target end
end

local function applyPosition(key)
    local row = rows[key]
    if row.dragging then return end
    local a = db.anchors[key]
    local target = a and anchorTarget(key, a[1])
    local p = db.pos[key]
    row:ClearAllPoints()
    local scale = row:GetEffectiveScale() / UIParent:GetEffectiveScale()
    -- A missing or circular target uses the last screen position without losing
    -- the saved target. A later addon load can resolve it again.
    if target then
        row:SetPoint("CENTER", target, "CENTER", a[2] / scale, a[3] / scale)
    else
        row:SetPoint(p[1], UIParent, p[1], p[2] / scale, p[3] / scale)
    end
    row.pendingAnchor = a and not target or nil
end

local function saveRowPosition(key)
    local x, y = frameCenter(rows[key])
    local parentX, parentY = frameCenter(UIParent)
    if not x or not parentX then return false end
    db.pos[key] = { "CENTER", x - parentX, y - parentY }
    local a = db.anchors[key]
    local targetX, targetY = frameCenter(a and anchorTarget(key, a[1]))
    if targetX then a[2], a[3] = x - targetX, y - targetY end
    return true
end

-- Preview alignment while the game's normal drag moves the row. Apply the
-- correction only on drop, so snapping never fights StartMoving or traps the
-- cursor. All geometry and the 10-pixel tolerance use UIParent coordinates.
local function snapTargets(key)
    local targets, seen = {}, {}
    local function add(frame)
        local name = frame and frame.GetName and frame:GetName()
        if name and not seen[name] and frame ~= UIParent and anchorTarget(key, name) then
            seen[name] = true
            targets[#targets + 1] = frame
        end
    end
    local a = db.anchors[key]
    if a then add(_G[a[1]]) end -- prefer the existing anchor when distances tie
    for _, otherKey in ipairs(BAR_KEYS) do add(rows[otherKey]) end
    local manager = EditModeManagerFrame
    for _, frame in ipairs(manager and manager.registeredSystemFrames or {}) do add(frame) end
    return targets
end

local function frameVisible(frame)
    local check = frame and (frame.IsVisible or frame.IsShown)
    if not check then return false end
    local ok, visible = pcall(check, frame)
    -- A successful API call can still return a secret boolean. Do not test it.
    return ok and not secret(visible) and visible == true
end

local function snapRect(frame)
    if not frameVisible(frame) then return end
    local x, y = frameCenter(frame)
    if not x then return end
    local w, h = frame:GetWidth(), frame:GetHeight()
    if secret(w) or secret(h) or type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return end
    local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return { x = x, y = y, w = w * scale, h = h * scale }
end

local SNAP_POINTS = {{0, 0}, {-0.5, -0.5}, {0.5, 0.5}, {-0.5, 0.5}, {0.5, -0.5}}

local function snapPosition(key)
    local row, manager = rows[key], EditModeManagerFrame
    if not editModeActive or not canMoveRows() or (IsShiftKeyDown and IsShiftKeyDown())
        or not manager or not manager.IsSnapEnabled or not manager:IsSnapEnabled() then return end
    local rect = snapRect(row)
    if not rect then return end
    local dx, dy, guideX, guideY
    for _, target in ipairs(row.snapTargets or {}) do
        local other = snapRect(target)
        -- Only nearby frames should attract the row, not a matching edge across
        -- the screen. Allow adjacent edges as well as overlapping rectangles.
        if other and math.abs(rect.x - other.x) <= (rect.w + other.w) / 2 + 24
            and math.abs(rect.y - other.y) <= (rect.h + other.h) / 2 + 24 then
            for _, pair in ipairs(SNAP_POINTS) do
                local x = other.x + pair[2] * other.w
                local deltaX = x - (rect.x + pair[1] * rect.w)
                if math.abs(deltaX) <= 10 and (not dx or math.abs(deltaX) < math.abs(dx)) then
                    dx = deltaX
                    guideX = { x, math.min(rect.y - rect.h / 2, other.y - other.h / 2),
                        math.max(rect.y + rect.h / 2, other.y + other.h / 2) }
                end
                local y = other.y + pair[2] * other.h
                local deltaY = y - (rect.y + pair[1] * rect.h)
                if math.abs(deltaY) <= 10 and (not dy or math.abs(deltaY) < math.abs(dy)) then
                    dy = deltaY
                    guideY = { y, math.min(rect.x - rect.w / 2, other.x - other.w / 2),
                        math.max(rect.x + rect.w / 2, other.x + other.w / 2) }
                end
            end
        end
    end
    return rect.x + (dx or 0), rect.y + (dy or 0), guideX, guideY
end

local function hideSnapGuides(row)
    if row.snapGuides then for _, guide in ipairs(row.snapGuides) do guide:Hide() end end
end

local function previewSnap(key)
    local row = rows[key]
    hideSnapGuides(row)
    local _, _, gx, gy = snapPosition(key)
    if not gx and not gy then return end
    if not row.snapGuides then
        row.snapGuides = {}
        for i = 1, 2 do
            local guide = row:CreateTexture(nil, "OVERLAY")
            guide:SetColorTexture(0.2, 0.85, 1, 0.9)
            guide:Hide()
            row.snapGuides[i] = guide
        end
    end
    local px, py = frameCenter(UIParent)
    if not px then return end
    local scale = row:GetEffectiveScale() / UIParent:GetEffectiveScale()
    if gx then
        local guide = row.snapGuides[1]
        guide:ClearAllPoints()
        guide:SetPoint("BOTTOM", UIParent, "CENTER", (gx[1] - px) / scale, (gx[2] - py) / scale)
        guide:SetSize(2 / scale, math.max(2, gx[3] - gx[2]) / scale)
        guide:Show()
    end
    if gy then
        local guide = row.snapGuides[2]
        guide:ClearAllPoints()
        guide:SetPoint("LEFT", UIParent, "CENTER", (gy[2] - px) / scale, (gy[1] - py) / scale)
        guide:SetSize(math.max(2, gy[3] - gy[2]) / scale, 2 / scale)
        guide:Show()
    end
end

local function stopRowDrag(key)
    local row = rows[key]
    if not row.dragging then return end
    row:StopMovingOrSizing()
    local x, y, gx, gy = snapPosition(key)
    if gx or gy then
        local px, py = frameCenter(UIParent)
        local scale = row:GetEffectiveScale() / UIParent:GetEffectiveScale()
        if px then
            row:ClearAllPoints()
            row:SetPoint("CENTER", UIParent, "CENTER", (x - px) / scale, (y - py) / scale)
        end
    end
    row:SetScript("OnUpdate", nil)
    hideSnapGuides(row)
    row.snapTargets = nil
    row.dragging = nil
    -- StartMoving can change the relative frame/anchor. Store a UIParent-centred
    -- position in UIParent units so reloads and different UI scales agree.
    if saveRowPosition(key) then persistSoon() end
    applyPosition(key)
end

local function setRowAnchor(key, name, label)
    if not rows[key] or (InCombatLockdown and InCombatLockdown()) then return false end
    local target = name and anchorTarget(key, name)
    if name and not target then
        say("cannot anchor to that frame (missing, invalid, or circular anchor).")
        return false
    end
    stopRowDrag(key)
    local x, y = frameCenter(rows[key])
    local tx, ty = frameCenter(target or UIParent)
    if not x or not tx then
        say("that frame has no readable position yet.")
        return false
    end
    saveRowPosition(key)
    db.anchors[key] = name and { name, x - tx, y - ty } or nil
    applyPosition(key)
    persistSoon()
    if name then
        say("%s attached to %s.", rows[key].title, label or name)
    else
        say("%s detached from its anchor.", rows[key].title)
    end
    return true
end

local function showAnchorMenu(key)
    if not editModeActive or not canMoveRows() then return end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        say("use /fcdm anchor %s <FrameName> or /fcdm anchor %s none.", key, key)
        return
    end
    MenuUtil.CreateContextMenu(rows[key], function(_, root)
        root:CreateTitle("Forever CDM: " .. rows[key].title)
        root:CreateTitle("Positions save immediately")
        local function selected(name)
            local a = db.anchors[key]
            return (a and a[1] or nil) == name
        end
        root:CreateRadio("Screen (detach)", function() return selected(nil) end,
            function() setRowAnchor(key, nil) end)
        local candidates, added, labels = {}, {}, {}
        local function add(frame, label)
            local name = frame and frame.GetName and frame:GetName()
            if name and frame ~= UIParent and not added[name] and frameVisible(frame) and anchorTarget(key, name) then
                added[name] = true
                label = label or name
                labels[label] = (labels[label] or 0) + 1
                candidates[#candidates + 1] = { name = name, label = label }
            end
        end
        for _, otherKey in ipairs(BAR_KEYS) do add(rows[otherKey], "Forever CDM: " .. rows[otherKey].title) end
        local manager = EditModeManagerFrame
        for _, frame in pairs(manager and manager.registeredSystemFrames or {}) do
            add(frame, frame.GetSystemName and frame:GetSystemName())
        end
        local a = db.anchors[key]
        if a then add(_G[a[1]]) end
        for _, candidate in ipairs(candidates) do
            if labels[candidate.label] > 1 then
                candidate.label = candidate.label .. " (" .. candidate.name .. ")"
            end
        end
        table.sort(candidates, function(a, b) return a.label < b.label end)
        for _, candidate in ipairs(candidates) do
            local name, label = candidate.name, candidate.label
            root:CreateRadio(label, function() return selected(name) end,
                function() setRowAnchor(key, name, label) end)
        end
    end)
end

local function updateRowInteractions(stopDragging)
    for _, key in ipairs(BAR_KEYS) do
        if stopDragging then stopRowDrag(key) end
        updateRowInteraction(key)
    end
end

local function initEditMode()
    -- Subscribe without registering addon frames as Blizzard systems or writing
    -- into the manager's protected layout tables. This also works if Edit Mode
    -- loads after PLAYER_LOGIN. Older clients keep the manual unlock controls.
    if not (EventRegistry and EventRegistry.RegisterCallback) then return end
    EventRegistry:RegisterCallback("EditMode.Enter", function()
        editModeActive = true
        updateRowInteractions(true)
    end, rows)
    EventRegistry:RegisterCallback("EditMode.Exit", function()
        editModeActive = false
        updateRowInteractions(true)
    end, rows)
    if EditModeManagerFrame and EditModeManagerFrame.IsEditModeActive then
        editModeActive = EditModeManagerFrame:IsEditModeActive() and true or false
        updateRowInteractions(false)
    end
end

local function newRow(key, label)
    local rowName = key == "utilities" and "ForeverCDM_utility" or "ForeverCDM_" .. key
    local row = CreateFrame("Frame", rowName, UIParent)
    row.title = label
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
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", function(self)
        if canMoveRows() then
            self:StartMoving()
            self.dragging = true
            if editModeActive then
                self.snapTargets = snapTargets(key)
                self:SetScript("OnUpdate", function() previewSnap(key) end)
            end
        end
    end)
    row:SetScript("OnDragStop", function() stopRowDrag(key) end)
    row:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then showAnchorMenu(key) end
    end)
    rows[key] = row
    return row
end

function ForeverCDM_SetLocked(locked)
    db.locked = locked
    updateRowInteractions(true)
    persistSoon()
end

-- Updates -------------------------------------------------------------------------

-- Trinkets, potions, bandages, engineering gadgets. Item cooldowns have no
-- duration-object variant, so if one ever arrives secret the swipe is simply
-- left off rather than guessed.
local function updateItemIcon(f)
    local itemID = -f.spellID
    local start, duration, enable
    if C_Container and C_Container.GetItemCooldown then start, duration, enable = C_Container.GetItemCooldown(itemID) end
    local onCD, known = false, true
    if secret(start) or secret(duration) then
        known = false
        f.cd:Clear()
    else
        f.cd:SetCooldown(start or 0, duration or 0)
        onCD = (duration or 0) > 1.5 and (secret(enable) or (enable ~= 0 and enable ~= false))
    end
    local count = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(itemID, false, true)   -- bags + equipped, counting charges
    local have = secret(count) or (count or 0) > 0
    f.icon:SetDesaturated(onCD or not have)
    if not have then
        f:SetAlpha(db.hideReady and 0 or 0.35)          -- run out, or unequipped
    else
        f:SetAlpha((not db.hideReady or not known or onCD) and 1 or 0)
    end
    f.count:SetText((not secret(count) and (count or 0) > 1) and count or "")
end

local function updateCooldowns(key)
    for _, f in ipairs(icons[key or "cds"]) do
        if f:IsShown() and f.spellID and f.spellID < 0 then
            updateItemIcon(f)
        elseif f:IsShown() and f.spellID then
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

-- How long does this aura last? A length measured from a readable aura wins;
-- otherwise the tooltip usually says ("...over 15 sec"). English tooltips only,
-- so /fcdm duration <spell> <seconds> can set it by hand.
local function auraDuration(id)
    if db.buffDurations[id] then return db.buffDurations[id] end
    local d = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(id)
    if type(d) ~= "string" or secret(d) then return nil end
    return tonumber(d:match("over (%d+) sec") or d:match("for (%d+) sec") or d:match("[Ll]asts (%d+) sec"))
end

-- An aura that is up and readable: full brightness, real timer, stack count.
local function drawAura(f, unit, a)
    f.inactive = false
    f:SetAlpha(1)
    f.icon:SetDesaturated(false)
    local dur, exp = a.duration, a.expirationTime
    if secret(dur) or secret(exp) then
        local duration
        if C_UnitAuras.GetAuraDuration and not secret(a.auraInstanceID) and a.auraInstanceID ~= nil then
            duration = C_UnitAuras.GetAuraDuration(unit, a.auraInstanceID)
        end
        if duration and f.cd.SetCooldownFromDurationObject then
            f.cd:SetCooldownFromDurationObject(duration)
        else
            f.cd:Clear()
        end
    elseif dur and dur > 0 then
        f.cd:SetCooldown(exp - dur, dur)
        -- Remember how long this aura lasts. In combat the aura is
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
end

-- An aura that is not up. Dimmed by default; with "hide inactive" it vanishes,
-- so a proc only appears when it happens. While the rows are unlocked it stays
-- visible either way, so there is something to see while dragging.
local function drawInactive(f)
    f.inactive = true
    f:SetAlpha((db.hideInactive and db.locked) and 0 or 0.25)
    f.icon:SetDesaturated(true)
    f.cd:Clear()
    f.count:SetText("")
end

-- With "hide inactive" on, close the gaps: visible icons slide left so one
-- active proc does not float in the middle of an empty bar.
local function packRow(key)
    local size, gap = db.rowSize[key], db.rowSpacing[key]
    local collapse = db.hideInactive and db.locked
    local n = 0
    for _, f in ipairs(icons[key]) do
        if f:IsShown() and not (collapse and f.inactive) then
            if f.slot ~= n then
                f.slot = n
                f:ClearAllPoints()
                f:SetPoint("LEFT", rows[key], "LEFT", n * (size + gap), 0)
            end
            n = n + 1
        end
    end
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
                drawAura(f, "player", a)
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
                    drawInactive(f)
                elseif f.castAt then
                    -- We saw ourselves cast it this fight (onPlayerCast). Start
                    -- time is our own clock and the length is one we measured
                    -- out of combat, so neither number is secret.
                    f.inactive = false
                    f:SetAlpha(0.85)
                    f.icon:SetDesaturated(false)
                    if learned then f.cd:SetCooldown(f.castAt, learned) else f.cd:Clear() end
                    f.count:SetText("")
                elseif f.auraInstanceID then
                    f.inactive = false
                    f:SetAlpha(0.85)              -- known before combat, unverifiable now
                    f.icon:SetDesaturated(false)
                    f.count:SetText("")
                else
                    f.inactive = false
                    f:SetAlpha(0.6)
                    f.icon:SetDesaturated(false)
                    f.cd:Clear()
                    f.count:SetText("?")
                end
            else
                f.combatRemoved = nil
                f.auraInstanceID = nil
                f.castAt = nil
                drawInactive(f)
            end
        end
    end
    packRow("buffs")
end

-- Debuffs bar: YOUR debuffs on your current target (Serpent Sting, Hunter's
-- Mark...). Same honesty rules as the Buffs bar: read the aura when the client
-- allows it; when it does not, fall back to our own cast event plus a known
-- duration, remembered per target so swapping back to a mob restores its timer.
local function targetKey()
    if not (UnitExists and UnitExists("target")) then return nil end
    local guid = UnitGUID and UnitGUID("target")
    if guid == nil or secret(guid) then return "?" end   -- unreadable GUID: all targets share one slot
    return guid
end

-- Returns the aura (or nil), and whether the target's debuffs could be read at all.
local function findTargetDebuff(id)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return nil, false end
    local name = spellName(id)             -- by name too: each rank is its own spellID
    local readable = true
    for i = 1, 40 do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "target", i, "HARMFUL|PLAYER")
        if not ok then return nil, false end
        if a == nil then break end
        if secret(a) or (issecrettable and issecrettable(a)) or secret(a.spellId) then
            readable = false
        elseif a.spellId == id or (not secret(a.name) and a.name == name) then
            return a, true
        end
    end
    return nil, readable
end

local function updateDebuffs()
    local tkey = targetKey()
    for _, f in ipairs(icons.debuffs) do
        if f:IsShown() and f.spellID then
            f.casts = f.casts or {}
            local a, readable = nil, true
            if tkey then a, readable = findTargetDebuff(f.spellID) end
            if a then
                -- Keep a start time for this target. Hunter's Mark goes up BEFORE
                -- the pull: the aura is readable then and unreadable once combat
                -- starts, so a real start time is what carries the timer across.
                if not secret(a.duration) and not secret(a.expirationTime) and (a.duration or 0) > 0 then
                    f.casts[tkey] = a.expirationTime - a.duration
                end
                drawAura(f, "target", a)
            else
                -- Readable and absent: it really dropped, unless the cast was a moment
                -- ago and the aura has not landed yet (application lags the cast event).
                if readable and tkey and f.casts[tkey] and GetTime() - f.casts[tkey] > 1 then f.casts[tkey] = nil end
                local castAt = tkey and not readable and f.casts[tkey] or nil
                local learned = auraDuration(f.spellID)
                if castAt and learned and GetTime() > castAt + learned then
                    f.casts[tkey] = nil    -- our own timer says it ran out
                    castAt = nil
                end
                if castAt then
                    f.inactive = false
                    f:SetAlpha(0.85)       -- we cast it on this target; unverifiable right now
                    f.icon:SetDesaturated(false)
                    if learned then f.cd:SetCooldown(castAt, learned) else f.cd:Clear() end
                    f.count:SetText("")
                else
                    drawInactive(f)
                end
            end
        end
    end
    packRow("debuffs")
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
    local tkey = targetKey()
    if not tkey then return end
    for _, f in ipairs(icons.debuffs) do
        if f.spellID then
            local hit = f.spellID == spellID
            if not hit then
                castName = castName or spellName(spellID)
                hit = castName == spellName(f.spellID)
            end
            if hit then
                f.casts = f.casts or {}
                f.casts[tkey] = GetTime()
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
    updateDebuffs()
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
local mirrorDirty, hinted, loginHinted = false, false, false

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
    put("hi", db.hideInactive and "1" or "0")
    put("mm", string.format("%d,%s", math.floor((db.minimap.angle or 215) + 0.5), db.minimap.hide and "1" or "0"))
    local sz, gp = {}, {}
    for i, key in ipairs(BAR_KEYS) do sz[i], gp[i] = db.rowSize[key], db.rowSpacing[key] end
    put("sz", table.concat(sz, ","))
    put("gp", table.concat(gp, ","))
    for _, key in ipairs(BAR_KEYS) do
        local tag = key:sub(1, 1)                  -- c, u, b, d (so "id"/"pd"; a bare "d" is the durations)
        put("i" .. tag, table.concat(db[key], ","))
        local p = db.pos[key]
        put("p" .. tag, string.format("%s,%.1f,%.1f", tostring(p[1]), p[2] or 0, p[3] or 0))
        local a = db.anchors[key]
        if a then put("a" .. tag, string.format("%s,%.1f,%.1f", a[1], a[2], a[3])) end
    end
    if withDurations then
        local dur = {}
        for _, key in ipairs({ "buffs", "debuffs" }) do
            for _, id in ipairs(db[key]) do
                if db.buffDurations[id] then dur[#dur + 1] = id .. ":" .. string.format("%.1f", db.buffDurations[id]) end
            end
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
    db.hideInactive = t.hi == "1"
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
        local target, ax, ay = (t["a" .. tag] or ""):match("^([%a_][%w_]*),(-?[%d%.]+),(-?[%d%.]+)$")
        ax, ay = tonumber(ax), tonumber(ay)
        db.anchors[key] = target and ax and ay and { target, ax, ay } or nil
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
    if db and not db.macroMirror and not mirror.hadSV and not hinted and not loginHinted and mirror.ready then
        hinted = true
        say("heads up: the beta client forgets addon settings when the game restarts. Tick \"Keep settings in a macro\" in /fcdm to keep this setup.")
    end
    if mirrorDirty then return end
    mirrorDirty = true
    if C_Timer and C_Timer.After then C_Timer.After(1, writeMirror) else writeMirror() end
end

-- True when this character's setup will be gone after a restart: the client gave us no
-- saved settings, and the macro that stands in for them is off. The macro is opt-in per
-- character, so a new alt is in this state until its box is ticked. Forever only: on a
-- working client an empty load just means a first install.
local function isForeverClient()
    local iface = GetBuildInfo and select(4, GetBuildInfo())
    return type(iface) == "number" and iface >= 16000 and iface < 20000
end

local function settingsAtRisk()
    return db ~= nil and mirror.ready and not db.macroMirror and not mirror.hadSV and isForeverClient()
end

local function loginHint()
    if loginHinted or not settingsAtRisk() then return end
    loginHinted = true
    say("settings are NOT being kept on this character: the beta client forgets them when the game restarts. /fcdm mirror on (or the \"Keep settings in a macro\" box in /fcdm) saves them in a macro. It is set per character.")
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
function ForeverCDM.SettingsAtRisk() return settingsAtRisk() end
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
    loginHint()
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
        loginHint()
        buildRankIndex()
        newRow("cds", "Cooldowns")
        newRow("utilities", "Utilities")
        newRow("buffs", "Buffs")
        newRow("debuffs", "Debuffs")
        refreshAll()
        initEditMode()
        self:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        self:RegisterEvent("SPELL_UPDATE_CHARGES")
        self:RegisterUnitEvent("UNIT_AURA", "player", "target")
        self:RegisterEvent("PLAYER_TARGET_CHANGED")
        self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        self:RegisterEvent("SPELLS_CHANGED")
        self:RegisterEvent("PLAYER_LOGOUT")
        -- pcall: registering an event this client lacks throws and would abort the handler
        for _, e in ipairs({ "BAG_UPDATE_COOLDOWN", "BAG_UPDATE_DELAYED", "PLAYER_EQUIPMENT_CHANGED", "GET_ITEM_INFO_RECEIVED" }) do
            pcall(self.RegisterEvent, self, e)
        end
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        self:RegisterEvent("PLAYER_REGEN_DISABLED")
        self:RegisterEvent("ADDON_LOADED")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        -- Still waiting for the macro list: UPDATE_MACROS will say when it has
        -- arrived. The timer only covers a client where that event never fires.
        if not mirror.ready and C_Timer and C_Timer.After then C_Timer.After(15, function() lateMirror(true) end) end
        local ver = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"
        say("v%s loaded. /fcdm opens settings.", tostring(ver))
        if ForeverCDM_InitMinimap then ForeverCDM_InitMinimap() end
    elseif event == "UNIT_AURA" then
        onAuraEvent(...)
        updateBuffs()
        updateDebuffs()
    elseif event == "PLAYER_TARGET_CHANGED" then
        updateDebuffs()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        onPlayerCast(...)
        updateBuffs()
        updateDebuffs()
    elseif event == "PLAYER_LOGOUT" then
        writeMirror()        -- flush anything still waiting on the debounce
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if itemNamesPending then              -- only when a name was actually missing
            itemNamesPending = false
            for _, key in ipairs(BAR_KEYS) do
                for _, f in ipairs(icons[key]) do if f.spellID then f.name:SetText(spellName(f.spellID)) end end
            end
            if ForeverCDM_RefreshConfig then ForeverCDM_RefreshConfig() end
        end
    elseif event == "UPDATE_MACROS" then
        mirror.macrosSeen = true
        if db then lateMirror(true) end
    elseif event == "PLAYER_REGEN_DISABLED" then
        updateRowInteractions(true)
    elseif event == "PLAYER_REGEN_ENABLED" then
        for _, key in ipairs(BAR_KEYS) do if rows[key].pendingAnchor then applyPosition(key) end end
        updateRowInteractions(false)
        if mirror.deleteAfterCombat then mirror.deleteAfterCombat = nil deleteMirror() end
        if mirror.afterCombat then mirror.afterCombat = nil writeMirror() end
        for _, f in ipairs(icons.debuffs) do f.casts = nil end    -- auras are readable again; drop the estimates
        updateDebuffs()
    elseif event == "ADDON_LOADED" or event == "PLAYER_ENTERING_WORLD" then
        if not (InCombatLockdown and InCombatLockdown()) then
            for _, key in ipairs(BAR_KEYS) do if rows[key].pendingAnchor then applyPosition(key) end end
        end
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
C_Timer.NewTicker(0.5, function() if db then updateBuffs() updateDebuffs() end end)

-- Slash ------------------------------------------------------------------------------

local HELP = {
    "Game Menu > Edit Mode  drag row handles; positions save immediately on drop",
    "Right-click a row in Edit Mode to attach it to another frame",
    "/fcdm anchor <cds|utilities|buffs> <FrameName|none>  attach or detach a row",
    "/fcdm add <spell>       add a spell cooldown icon (name as in spellbook, or spellID)",
    "/fcdm add item:<id>     add an item: trinket, potion, bandage... (item name or a pasted link also work)",
    "/fcdm addbuff <spell>   watch a buff on yourself (shows bright while active)",
    "/fcdm adddebuff <spell> watch your own debuff on your target (Serpent Sting...)",
    "/fcdm addutility <spell> add a spell to the Utility row",
    "/fcdm remove <spell>    remove from all rows",
    "/fcdm auto              add every spellbook spell that has a cooldown",
    "/fcdm list              show what is tracked",
    "/fcdm unlock | lock     drag the rows, then lock",
    "/fcdm size [bar] <px>   icon size, all bars or one of cds|utility|buffs|debuffs. Same for /fcdm spacing",
    "/fcdm hideinactive on|off  hide buff and debuff icons until the aura is up (off: they stay dimmed)",
    "/fcdm duration <spell> <sec>  set how long a buff or debuff lasts, if the addon could not work it out",
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

    if cmd == "add" or cmd == "addbuff" or cmd == "addutility" or cmd == "adddebuff" then
        local id = resolveSpell(rest)
        if not id then say("no spell called \"%s\". Use the name from your spellbook, or a spellID.", rest) return end
        local key = cmd == "add" and "cds" or cmd == "addutility" and "utilities" or cmd == "adddebuff" and "debuffs" or "buffs"
        if id < 0 and (key == "buffs" or key == "debuffs") then say("items go on the Cooldowns or Utility bar; the Buffs and Debuffs bars watch auras.") return end
        if contains(db[key], id) then say("%s is already tracked.", spellName(id)) return end
        db[key][#db[key] + 1] = id
        refreshAll()
        say("added %s to %s.", spellName(id), BAR_LABEL[key])

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
            say("%s: %s", BAR_LABEL[key], #names > 0 and table.concat(names, ", ") or "none")
        end

    elseif cmd == "anchor" then
        local key, name = rest:match("^(%a+)%s+(%S+)$")
        if key == "utility" then key = "utilities" end
        if not key or not rows[key] or not name then
            say("usage: /fcdm anchor <cds|utilities|buffs> <FrameName|none>")
        else
            setRowAnchor(key, name ~= "none" and name or nil)
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
                        util = "utilities", buffs = "buffs", buff = "buffs", debuffs = "debuffs", debuff = "debuffs" }
        local key = which and alias[strlower(which)]
        if not n or (which and not key) then
            say("usage: /fcdm %s [cds|utility|buffs|debuffs] <pixels>", cmd)
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

    elseif cmd == "hideready" or cmd == "names" or cmd == "hideinactive" then
        local on = rest == "on" or rest == "1" or rest == "true"
        if cmd == "hideready" then db.hideReady = on elseif cmd == "names" then db.showNames = on else db.hideInactive = on end
        for _, f in ipairs(icons.cds) do f:SetAlpha(1) end
        refreshAll()
        if ForeverCDM_RefreshConfig then ForeverCDM_RefreshConfig() end
        say("%s %s.", cmd, on and "on" or "off")

    elseif cmd == "duration" then
        local which, sec = rest:match("^(.-)%s+(%d+%.?%d*)$")
        local id = which and resolveSpell(which)
        if not id or id < 0 then say("usage: /fcdm duration <spell> <seconds>") return end
        db.buffDurations[id] = tonumber(sec)
        refreshAll()
        say("%s lasts %s seconds.", spellName(id), sec)

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
        -- The target's side, for the Debuffs bar.
        if UnitExists and UnitExists("target") and C_UnitAuras.GetAuraDataByIndex then
            local walked, hit, firstErr = 0, nil, nil
            for i = 1, 40 do
                local okD, d = pcall(C_UnitAuras.GetAuraDataByIndex, "target", i, "HARMFUL|PLAYER")
                if not okD then firstErr = tostring(d):sub(1, 100) break end
                if d == nil then break end
                walked = walked + 1
                if type(d) == "table" and not (issecrettable and issecrettable(d)) and not secret(d.spellId)
                    and (d.spellId == id or d.name == spellName(id)) then hit = d end
            end
            local okT, tSecret = pcall(function() return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret("target") end)
            say("  target HARMFUL|PLAYER -> walked=%d match=%s err=%s targetSecret=%s", walked, hit and desc(hit) or "none", tostring(firstErr), tostring(okT and tSecret))
            local f
            for _, icon in ipairs(icons.debuffs) do if icon.spellID == id then f = icon end end
            local tk = targetKey()
            say("  debuff icon: %s | estimate for this target=%s | duration=%s", f and "tracked" or "not on the Debuffs bar",
                tostring(f and f.casts and tk and f.casts[tk]), tostring(auraDuration(id)))
        else
            say("  no target, so nothing to say about the Debuffs bar.")
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
