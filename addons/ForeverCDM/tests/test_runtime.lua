-- Loads the real addon with a small fake WoW UI. This checks Lua wiring, not rendering.
-- Run from ForeverCDM: lua tests/test_runtime.lua
unpack = table.unpack
tinsert = table.insert
strlower = string.lower
strtrim = function(s) return s:match('^%s*(.-)%s*$') end
wipe = function(t) for k in pairs(t) do t[k] = nil end end
issecretvalue = function() return false end
UISpecialFrames, SlashCmdList = {}, {}
local frames = {}
local methods = {}
local function noop() end
local function object(kind, name, parent)
    local f = { kind = kind, frameName = name, parent = parent, scripts = {}, events = {}, shown = true }
    setmetatable(f, { __index = methods })
    frames[#frames + 1] = f
    if name then _G[name] = f end
    return f
end
for _, name in ipairs({ 'SetTexCoord', 'SetMovable', 'SetClampedToScreen',
    'SetDrawEdge', 'SetHideCountdownNumbers', 'SetDesaturated',
    'SetCooldownFromDurationObject', 'SetAllPoints', 'SetColorTexture',
    'RegisterForDrag', 'StartMoving', 'StopMovingOrSizing', 'SetFrameStrata',
    'SetBackdrop', 'SetBackdropColor', 'SetJustifyH', 'SetAutoFocus', 'SetOwner',
    'SetSpellByID', 'SetVerticalScroll', 'SetScrollStep', 'SetEnabled',
    -- used by the flat widget kit and the minimap button
    'SetTextColor', 'SetFontString', 'SetCheckedTexture', 'SetFontObject', 'SetTextInsets', 'ClearFocus',
    'EnableMouseWheel', 'SetVertexColor', 'SetFrameLevel', 'RegisterForClicks', 'SetHighlightTexture',
    'SetToplevel', 'SetAtlas', 'AddLine', 'SetItemByID' }) do methods[name] = noop end
function methods:SetCooldown(start, dur) self.cdStart, self.cdDur = start, dur end
function methods:Clear() self.cdStart, self.cdDur = nil, nil end
function methods:GetVerticalScroll() return 0 end
function methods:GetVerticalScrollRange() return 0 end
function methods:GetCenter()
    if self.centerX ~= nil then return self.centerX, self.centerY end
    local p = self.point
    if p and p[1] == 'CENTER' and p[3] == 'CENTER' and p[2] then
        local x, y = p[2]:GetCenter()
        local scale = p[2]:GetEffectiveScale() / self:GetEffectiveScale()
        return x * scale + p[4], y * scale + p[5]
    end
    return 0, 0
end
function methods:GetEffectiveScale() return self.scale or 1 end
function methods:StartMoving() self.moving = true end
function methods:StopMovingOrSizing() self.moving = false end
function methods:SetSize(w, h) self.width, self.height = w, h end
function methods:SetHeight(h) self.height = h end
function methods:SetWidth(w) self.width = w end
function methods:GetWidth() return self.width or 100 end
function methods:GetHeight() return self.height or 100 end
-- like a real frame, point 1 is the first anchor set since the last ClearAllPoints
function methods:SetPoint(...) if not self.point then self.point = {...} end end
function methods:ClearAllPoints() self.point = nil end
function methods:GetPoint() return unpack(self.point) end
function methods:SetText(t) self.textValue = t end
function methods:GetText() return self.textValue or '' end
function methods:SetTexture(t) self.texture = t end
function methods:SetAlpha(a) self.alpha = a end
function methods:GetParent() return self.parent end
function methods:GetName() return self.frameName end
function methods:IsObjectType(kind) return self.kind == kind end
function methods:GetNumPoints() return self.point and 1 or 0 end
function methods:SetChecked(v) self.checked = v end
function methods:SetEnabled(v) self.enabled = v end
function methods:GetChecked() return self.checked end
function methods:EnableMouse(v) self.mouse = v end
function methods:SetScript(k, fn) self.scripts[k] = fn end
function methods:RegisterEvent(e) self.events[e] = true end
function methods:RegisterUnitEvent(e) self.events[e] = true end
function methods:CreateTexture() return object('Texture', nil, self) end
function methods:CreateFontString() return object('FontString', nil, self) end
function methods:SetScrollChild(c) self.child = c end
function methods:IsShown() return self.shown end
function methods:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
function methods:Hide() self.shown = false end
function methods:SetShown(v) if v then self:Show() else self:Hide() end end
CreateFrame = object
UIParent, GameTooltip = object('Frame'), object('Tooltip')
Minimap = object('Frame')
Minimap.width = 140
local cursorX, cursorY = 0, 0
GetCursorPosition = function() return cursorX, cursorY end
C_Timer = { NewTicker = noop, After = function(_, fn) fn() end }
local inCombat = false
InCombatLockdown = function() return inCombat end
local callbacks = {}
local editModeAtLogin = arg and arg[1] == 'edit-mode-open'
if not (arg and arg[1] == 'no-edit-mode') then
    EventRegistry = {
        RegisterCallback = function(_, event, callback, owner)
            assert(not callbacks[event], 'duplicate Edit Mode callback')
            callbacks[event] = function(...) callback(owner, ...) end
        end,
    }
    -- Leave the manager absent in the normal run to exercise lazy loading.
    if editModeAtLogin then
        EditModeManagerFrame = { IsEditModeActive = function() return true end }
    end
end
Enum = { SpellBookSpellBank = { Player = 0 } }
local spells = {101, 102, 104}
local names = { [101] = 'First Spell', [102] = 'Second Spell', [103] = 'Newly Learned', [104] = 'First Spell' }
local ranks = { [101] = 'Rank 1', [104] = 'Rank 2' }
C_Spell = {
    GetSpellName = function(id) return names[id] end,
    GetSpellTexture = function(id) return id end,
    GetSpellCooldown = function() return { startTime = 0, duration = 0, isEnabled = true } end,
    GetSpellCharges = function() return nil end,
}
C_UnitAuras = { GetPlayerAuraBySpellID = function() return nil end }
-- Items: a potion stack in the bags (usable), a trinket worn (usable), and cloth (not usable).
local POTION, TRINKET, CLOTH = 118, 11122, 2589
local itemNames = { [POTION] = 'Minor Healing Potion', [TRINKET] = 'Carrot on a Stick', [CLOTH] = 'Linen Cloth' }
local itemCount = { [POTION] = 5, [TRINKET] = 1, [CLOTH] = 20 }
local itemCD = {}
C_Item = {
    GetItemNameByID = function(id) return itemNames[id] end,
    GetItemIconByID = function(id) return id end,
    GetItemSpell = function(id) if id ~= CLOTH then return 'Use', 1 end end,
    GetItemCount = function(id) return itemCount[id] or 0 end,
    GetItemInfoInstant = function(name) for id, n in pairs(itemNames) do if n == name then return id end end end,
    RequestLoadItemDataByID = function() end,
}
C_Container = {
    GetItemCooldown = function(id) local c = itemCD[id] if c then return c[1], c[2], 1 end return 0, 0, 1 end,
    GetContainerNumSlots = function(bag) return bag == 0 and 2 or 0 end,
    GetContainerItemID = function(bag, slot) return ({ POTION, CLOTH })[slot] end,
}
GetInventoryItemID = function(_, slot) if slot == 13 then return TRINKET end end
C_SpellBook = {
    GetNumSpellBookSkillLines = function() return 1 end,
    GetSpellBookSkillLineInfo = function() return { itemIndexOffset = 0, numSpellBookItems = #spells, name = 'Paladin' } end,
    GetSpellBookItemInfo = function(i) return { spellID = spells[i], name = names[spells[i]], subName = ranks[spells[i]] } end,
}
local oldCDs, oldBuffs = {102, 101}, {101}
local oldPosition = {'CENTER', 7, -244}
ForeverCDMDB = { cds = oldCDs, buffs = oldBuffs, pos = { cds = oldPosition, buffs = {'CENTER', 6, -195} }, size = 42, locked = true }
assert(loadfile('ForeverCDM.lua'))('ForeverCDM')
assert(loadfile('ForeverCDM_UI.lua'))('ForeverCDM')
local function fire(event)
    local pending = {}
    for _, f in ipairs(frames) do if f.events[event] then pending[#pending + 1] = f end end
    for _, f in ipairs(pending) do f.scripts.OnEvent(f, event) end
end
fire('PLAYER_LOGIN')
if editModeAtLogin then
    assert(ForeverCDM_cds.mouse and ForeverCDMDB.locked, 'already-open Edit Mode was not detected')
    callbacks['EditMode.Exit']()
end
assert(ForeverCDMDB.cds == oldCDs and oldCDs[1] == 102, 'migration changed saved order')
assert(ForeverCDMDB.buffs == oldBuffs and ForeverCDMDB.pos.cds == oldPosition, 'migration changed existing settings')
assert(ForeverCDMDB.size == 42 and ForeverCDMDB.utilities and ForeverCDMDB.pos.utilities, 'utility defaults missing')
assert(ForeverCDM_utility, 'utility row was not created')
ForeverCDM_ToggleConfig()
assert(ForeverCDMConfig:IsShown(), 'config did not open')
spells[#spells + 1] = 103
fire('SPELLS_CHANGED')
local found = false
for _, f in ipairs(frames) do
    if f.kind == 'FontString' and type(f.textValue) == 'string' and f.textValue:find('Newly Learned', 1, true) then found = true end
end
assert(found, 'open UI did not pick up learned spell')
assert(#oldCDs == 2 and oldCDs[1] == 102, 'spellbook refresh changed chosen spells/order')
ForeverCDM_SetLocked(false)
assert(ForeverCDM_utility.mouse, 'utility row cannot be dragged when unlocked')
ForeverCDM_SetLocked(true)
assert(not ForeverCDM_utility.mouse, 'utility row intercepts mouse while locked')
-- Click actual pooled row controls, including both ends of the list.
local order = ForeverCDMConfig.orderPanel
local function orderRow(i)
    for _, f in ipairs(frames) do if f.parent == order and f.index == i and f.up then return f end end
    error('missing order row ' .. i)
end
local first = orderRow(1)
assert(first.up.enabled == false, 'first Up must be disabled')
first.down.scripts.OnClick(first.down)
assert(oldCDs[1] == 101 and oldCDs[2] == 102, 'Down did not swap once')
local last = orderRow(2)
assert(last.down.enabled == false, 'last Down must be disabled')
last.up.scripts.OnClick(last.up)
assert(oldCDs[1] == 102 and oldCDs[2] == 101, 'last Up did not swap once')
local learnedRow
for _, f in ipairs(frames) do if f.id == 103 and f.utility then learnedRow = f end end
assert(learnedRow, 'missing learned spell selection row')
learnedRow.utility:SetChecked(true)
learnedRow.utility.scripts.OnClick(learnedRow.utility)
assert(ForeverCDMDB.utilities[1] == 103, 'Utility checkbox did not assign spell')
ForeverCDMConfig.orderKey = 'utilities'
ForeverCDM_RefreshConfig()
assert(orderRow(1).name:GetText() == 'Newly Learned', 'Utility ordering list did not refresh')
ForeverCDMConfig.orderClear.scripts.OnClick(ForeverCDMConfig.orderClear)
assert(#ForeverCDMDB.utilities == 0 and #oldCDs == 2, 'Clear bar affected wrong list')
-- Older profiles had one size for every bar; it seeds each bar once and the old field is left alone.
assert(ForeverCDMDB.rowSize.cds == 42 and ForeverCDMDB.rowSize.buffs == 42 and ForeverCDMDB.rowSpacing.utilities == 4,
    'per-bar size/spacing were not seeded from the old single values')
-- The steppers act on the bar chosen by the tabs, and only that bar.
ForeverCDMConfig.orderKey = 'buffs'
ForeverCDM_RefreshConfig()
ForeverCDMConfig.sizePlus.scripts.OnClick(ForeverCDMConfig.sizePlus)
ForeverCDMConfig.spacingMinus.scripts.OnClick(ForeverCDMConfig.spacingMinus)
assert(ForeverCDMDB.rowSize.buffs == 44 and ForeverCDMDB.rowSize.cds == 42, 'size stepper touched the wrong bar')
assert(ForeverCDMDB.rowSpacing.buffs == 2 and ForeverCDMDB.rowSpacing.cds == 4, 'spacing stepper touched the wrong bar')
assert(ForeverCDMConfig.sizeText:GetText() == '44', 'stepper readout did not follow the selected bar')
SlashCmdList['FOREVERCDM']('size utility 30')
assert(ForeverCDMDB.rowSize.utilities == 30 and ForeverCDMDB.rowSize.buffs == 44, '/fcdm size <bar> <px> touched other bars')
SlashCmdList['FOREVERCDM']('spacing 6')
assert(ForeverCDMDB.rowSpacing.cds == 6 and ForeverCDMDB.rowSpacing.buffs == 6, '/fcdm spacing <px> should set every bar')

-- Ranks: both ranks listed, labelled, Rank 1 above Rank 2.
local r1, r2
for _, f in ipairs(frames) do
    if f.kind == 'FontString' and type(f.textValue) == 'string' and f.parent and f.parent.cd then
        if f.textValue:find('First Spell', 1, true) and f.textValue:find('Rank 1', 1, true) then r1 = f.parent end
        if f.textValue:find('First Spell', 1, true) and f.textValue:find('Rank 2', 1, true) then r2 = f.parent end
    end
end
assert(r1 and r2, 'spell rows do not show their rank')
assert(r1.id == 101 and r2.id == 104, 'rank labels are on the wrong spells')
assert(r1.point[5] > r2.point[5], 'Rank 1 should be listed above Rank 2')
assert(ForeverCDM.SpellRank(102) == nil and ForeverCDM.RankNumber(104) == 2, 'rank lookup wrong')

-- Items: usable gear and bag items are offered, junk is not, and they cannot go on the Buffs bar.
local potionRow, trinketRow, clothRow
for _, f in ipairs(frames) do
    if f.cd and f.utility and f.id == -POTION then potionRow = f end
    if f.cd and f.utility and f.id == -TRINKET then trinketRow = f end
    if f.cd and f.utility and f.id == -CLOTH then clothRow = f end
end
assert(potionRow and trinketRow, 'usable items from bags and gear should be listed')
assert(not clothRow, 'an item with no Use effect should not be listed')
assert(potionRow.name:GetText() == 'Minor Healing Potion', 'item row shows the wrong name')
assert(not potionRow.buff:IsShown(), 'an item row should not offer the Buffs bar')
potionRow.cd:SetChecked(true)
potionRow.cd.scripts.OnClick(potionRow.cd)
assert(ForeverCDM.Contains(ForeverCDMDB.cds, -POTION), 'ticking an item did not add it')
local potionIcon
for _, f in ipairs(frames) do if f.spellID == -POTION and f.parent == ForeverCDM_cds then potionIcon = f end end
assert(potionIcon and potionIcon.icon.texture == POTION, 'item icon was not created on the bar')
assert(potionIcon.count.textValue == 5 and potionIcon.alpha == 1, 'stack count or ready state wrong')
itemCD[POTION] = { 100, 120 }
fire('BAG_UPDATE_COOLDOWN')
assert(potionIcon.cd.cdStart == 100 and potionIcon.cd.cdDur == 120, 'item cooldown was not drawn')
itemCount[POTION], itemCD[POTION] = 0, nil
fire('BAG_UPDATE_DELAYED')
assert(potionIcon.alpha == 0.35 and potionIcon.count.textValue == '', 'an item you have run out of should be dimmed')
itemCount[POTION] = 5
SlashCmdList['FOREVERCDM']('addbuff item:' .. TRINKET)
assert(not ForeverCDM.Contains(ForeverCDMDB.buffs, -TRINKET), 'an item was allowed onto the Buffs bar')
SlashCmdList['FOREVERCDM']('addutility Carrot on a Stick')
assert(ForeverCDM.Contains(ForeverCDMDB.utilities, -TRINKET), 'adding an item by name failed')
SlashCmdList['FOREVERCDM']('remove item:' .. TRINKET)
assert(not ForeverCDM.Contains(ForeverCDMDB.utilities, -TRINKET), 'removing an item failed')
SlashCmdList['FOREVERCDM']('remove item:' .. POTION)

-- Spell rows are grouped under one heading per spellbook tab.
local headings = 0
for _, f in ipairs(frames) do
    if f.kind == 'FontString' and f.textValue == 'PALADIN' then headings = headings + 1 end
end
assert(headings == 1, 'expected exactly one PALADIN heading, got ' .. headings)

-- Minimap button: built at login, opens settings, right-click locks, drag saves the angle.
local mm = ForeverCDMMinimapButton
assert(mm and mm:IsShown(), 'minimap button was not created at login')
assert(ForeverCDMDB.minimap.angle == 215 and ForeverCDMDB.minimap.hide == false, 'minimap defaults missing')
ForeverCDMConfig:Hide()
mm.scripts.OnClick(mm, 'LeftButton')
assert(ForeverCDMConfig:IsShown(), 'left-click did not open settings')
mm.scripts.OnClick(mm, 'LeftButton')
assert(not ForeverCDMConfig:IsShown(), 'second left-click did not close settings')
local wasLocked = ForeverCDMDB.locked
mm.scripts.OnClick(mm, 'RightButton')
assert(ForeverCDMDB.locked == (not wasLocked), 'right-click did not toggle the row lock')
mm.scripts.OnClick(mm, 'RightButton')
cursorX, cursorY = 0, 100                      -- straight up from the minimap centre
mm.scripts.OnDragStart(mm)
mm.scripts.OnUpdate(mm)
mm.scripts.OnDragStop(mm)
assert(math.abs(ForeverCDMDB.minimap.angle - 90) < 0.001, 'drag did not save the angle')
assert(mm.scripts.OnUpdate == nil, 'drag tracking was left running')
SlashCmdList['FOREVERCDM']('minimap')
assert(ForeverCDMDB.minimap.hide == true and not mm:IsShown(), '/fcdm minimap did not hide the button')
SlashCmdList['FOREVERCDM']('minimap')
assert(ForeverCDMDB.minimap.hide == false and mm:IsShown(), '/fcdm minimap did not show it again')

print('runtime migration, config, learned-spell refresh, utility, items, grouping and minimap checks passed')

-- Real row handlers: a frame can end a drag relative to a different anchor.
-- Verify that stored positions instead use UIParent coordinates and scale.
local row = ForeverCDM_cds
ForeverCDM_SetLocked(true)
row.scripts.OnDragStart(row)
assert(not row.moving, 'locked row started moving outside Edit Mode')
ForeverCDM_SetLocked(false)
row.scripts.OnDragStart(row)
assert(row.moving, 'manual unlock no longer allows dragging')
UIParent.centerX, UIParent.centerY, UIParent.scale = 500, 300, 0.8
row.centerX, row.centerY, row.scale = 450, 250, 1.6
row:ClearAllPoints()
row:SetPoint('TOPLEFT', Minimap, 'BOTTOMRIGHT', 3, 4)
row.scripts.OnDragStop(row)
assert(not row.moving and not row.dragging, 'drag did not stop')
local saved = ForeverCDMDB.pos.cds
assert(saved[1] == 'CENTER' and saved[2] == 400 and saved[3] == 200, 'drag saved wrong coordinates/scale')
ForeverCDM.Refresh()
local point, relativeTo, relativePoint, x, y = row:GetPoint()
assert(point == 'CENTER' and relativeTo == UIParent and relativePoint == 'CENTER'
    and x == 200 and y == 100, 'saved position did not restore against UIParent at the row scale')
UIParent.centerX, UIParent.centerY, UIParent.scale = nil, nil, nil
row.centerX, row.centerY, row.scale = nil, nil, nil
ForeverCDM_SetLocked(true)

if EventRegistry then
    assert(callbacks['EditMode.Enter'] and callbacks['EditMode.Exit'], 'Edit Mode callbacks missing')
    callbacks['EditMode.Enter']()
    for _, frame in ipairs({ForeverCDM_cds, ForeverCDM_utility, ForeverCDM_buffs}) do
        assert(frame.mouse and frame.bg:IsShown() and frame.label:IsShown(), 'Edit Mode handle missing')
        assert(frame:GetWidth() >= 40, 'empty row has no usable handle')
        assert(frame.label:GetText():find('right-click to anchor', 1, true), 'anchor menu is not discoverable')
    end
    assert(ForeverCDMDB.locked, 'entering Edit Mode overwrote lock preference')
    -- Refreshes must keep handles available without resetting an active drag.
    row.scripts.OnDragStart(row)
    local draggedPoint = {'TOPLEFT', UIParent, 'TOPLEFT', 11, 12}
    row.point = draggedPoint
    ForeverCDM.Refresh()
    assert(row.point == draggedPoint and row.moving and row.mouse, 'refresh interrupted a drag')
    row.centerX, row.centerY = 123, -45
    row.scripts.OnDragStop(row)
    assert(ForeverCDMDB.pos.cds[2] == 123 and ForeverCDMDB.pos.cds[3] == -45, 'Edit Mode drag not saved')
    -- Blizzard save/revert owns no addon data: immediate persistence is intentional.
    callbacks['EditMode.Exit']()
    for _, frame in ipairs({ForeverCDM_cds, ForeverCDM_utility, ForeverCDM_buffs}) do
        assert(not frame.mouse and not frame.bg:IsShown() and not frame.label:IsShown(), 'locked handle leaked after exit')
    end
    assert(ForeverCDMDB.pos.cds[2] == 123 and ForeverCDMDB.locked, 'exit lost position or lock')

    -- Exiting while the mouse is down must not leave a frame following it.
    callbacks['EditMode.Enter']()
    row.scripts.OnDragStart(row)
    callbacks['EditMode.Exit']()
    assert(not row.moving and not row.dragging and not row.mouse, 'exit left an active drag')

    -- The user's manual unlock preference survives a complete Edit Mode session.
    ForeverCDM_SetLocked(false)
    callbacks['EditMode.Enter']()
    callbacks['EditMode.Exit']()
    assert(row.mouse and not ForeverCDMDB.locked, 'exit discarded manual unlock preference')
    callbacks['EditMode.Enter']()
    ForeverCDM_SetLocked(true)
    assert(row.mouse, 'manual lock hid Edit Mode handles')

    -- Combat interrupts dragging and suppresses handles until it is safe again.
    row.scripts.OnDragStart(row)
    inCombat = true
    fire('PLAYER_REGEN_DISABLED')
    assert(not row.moving and not row.mouse and not row.bg:IsShown(), 'combat left a draggable row')
    row.scripts.OnDragStart(row)
    assert(not row.moving, 'drag could start during combat')
    inCombat = false
    fire('PLAYER_REGEN_ENABLED')
    assert(row.mouse, 'Edit Mode handle not restored after combat')
    inCombat = true
    fire('PLAYER_REGEN_DISABLED')
    callbacks['EditMode.Exit']()
    inCombat = false
    fire('PLAYER_REGEN_ENABLED')
    assert(not row.mouse and ForeverCDMDB.locked, 'combat exit resurrected a closed Edit Mode')
else
    assert(not row.mouse, 'missing Edit Mode API broke normal locking')
end
print('row positioning, Edit Mode lifecycle and combat checks passed')

-- Frame-relative anchors persist both the target and an offset, while the old
-- screen position remains available if the target is absent on a later login.
local target = object('Frame', 'TestPlayerFrame', UIParent)
target.GetSystemName = function() return 'Player Frame' end
target.centerX, target.centerY, target.scale = 100, 200, 0.5
row.centerX, row.centerY = 300, 400
SlashCmdList.FOREVERCDM('anchor cds TestPlayerFrame')
local anchor = ForeverCDMDB.anchors.cds
assert(anchor[1] == 'TestPlayerFrame' and anchor[2] == 250 and anchor[3] == 300, 'wrong target-relative offset')
assert(row.point[2] == target and row.point[4] == 250, 'row not attached to target')
row.centerX, row.centerY = nil, nil
target.centerX = 400
local attachedX, attachedY = row:GetCenter()
assert(attachedX == 450 and attachedY == 400, 'row did not follow a scaled target')
ForeverCDM_SetLocked(false)
row.scripts.OnDragStart(row)
row.centerX, row.centerY = 470, 430
row.scripts.OnDragStop(row)
assert(ForeverCDMDB.anchors.cds[2] == 270 and ForeverCDMDB.anchors.cds[3] == 330,
    'dragging detached row or lost its new offset')
row.centerX, row.centerY = nil, nil
SlashCmdList.FOREVERCDM('anchor cds none')
assert(not ForeverCDMDB.anchors.cds and row.point[2] == UIParent, 'detach kept the target')
local detachedX, detachedY = row:GetCenter()
assert(detachedX == 470 and detachedY == 430, 'detach moved the row')

-- Reject self, child, frame-point dependency, and saved row-chain cycles.
SlashCmdList.FOREVERCDM('anchor cds ForeverCDM_cds')
assert(not ForeverCDMDB.anchors.cds, 'self anchor accepted')
object('Frame', 'TestChildFrame', row)
SlashCmdList.FOREVERCDM('anchor cds TestChildFrame')
assert(not ForeverCDMDB.anchors.cds, 'child anchor accepted')
target:ClearAllPoints()
target:SetPoint('CENTER', row, 'CENTER', 0, 0)
SlashCmdList.FOREVERCDM('anchor cds TestPlayerFrame')
assert(not ForeverCDMDB.anchors.cds, 'dependent anchor accepted')
target:ClearAllPoints()
SlashCmdList.FOREVERCDM('anchor cds ForeverCDM_buffs')
SlashCmdList.FOREVERCDM('anchor buffs ForeverCDM_utility')
SlashCmdList.FOREVERCDM('anchor utilities ForeverCDM_cds')
assert(not ForeverCDMDB.anchors.utilities, 'row-chain cycle accepted')
SlashCmdList.FOREVERCDM('anchor cds none')
SlashCmdList.FOREVERCDM('anchor buffs none')

-- Loading late, including an addon that finishes loading during combat.
ForeverCDMDB.anchors.cds = {'TestLateFrame', 10, 20}
ForeverCDM.Refresh()
assert(row.pendingAnchor and row.point[2] == UIParent, 'missing target has no screen fallback')
local late = object('Frame', 'TestLateFrame', UIParent)
inCombat = true
fire('ADDON_LOADED')
assert(row.pendingAnchor, 'late-load handler reanchored during combat')
inCombat = false
fire('PLAYER_REGEN_ENABLED')
assert(not row.pendingAnchor and row.point[2] == late, 'late target not restored after combat')
SlashCmdList.FOREVERCDM('anchor cds none')
ForeverCDMDB.anchors.cds = {'TestAnotherLateFrame', 30, 40}
ForeverCDM.Refresh()
local anotherLate = object('Frame', 'TestAnotherLateFrame', UIParent)
fire('ADDON_LOADED')
assert(row.point[2] == anotherLate, 'addon load did not restore target')

-- Invalid requests and combat leave the existing selection unchanged.
anchor = ForeverCDMDB.anchors.cds
SlashCmdList.FOREVERCDM('anchor cds MissingFrame')
assert(ForeverCDMDB.anchors.cds == anchor, 'invalid target erased saved anchor')
inCombat = true
SlashCmdList.FOREVERCDM('anchor cds none')
assert(ForeverCDMDB.anchors.cds == anchor, 'combat changed the anchor')
inCombat = false

if EventRegistry then
    local menu
    MenuUtil = { CreateContextMenu = function(owner, generate)
        assert(owner == row)
        menu = {}
        generate(owner, {
            CreateTitle = function() end,
            CreateRadio = function(_, label, selected, choose)
                menu[label] = {selected = selected, choose = choose}
            end,
        })
    end }
    EditModeManagerFrame = { registeredSystemFrames = {target, row} }
    callbacks['EditMode.Enter']()
    row.scripts.OnMouseUp(row, 'RightButton')
    assert(menu['Player Frame'] and menu['Forever CDM: Buffs'], 'anchor menu missing native/addon frames')
    assert(not menu['Forever CDM: Cooldowns'], 'menu offered a self anchor')
    local originalPrint, messages = print, {}
    print = function(message) messages[#messages + 1] = message end
    menu['Player Frame'].choose()
    assert(menu['Player Frame'].selected() and row.point[2] == target, 'menu did not attach')
    assert(messages[#messages]:find('Cooldowns attached to Player Frame.', 1, true), 'missing attach confirmation')
    menu['Screen (detach)'].choose()
    assert(menu['Screen (detach)'].selected() and row.point[2] == UIParent, 'menu did not detach')
    assert(messages[#messages]:find('Cooldowns detached', 1, true), 'missing detach confirmation')
    print = originalPrint

    local hidden = object('Frame', 'TestHiddenTarget', UIParent)
    hidden:Hide()
    local blocked = object('Frame', 'TestBlockedTarget', UIParent)
    blocked.IsVisible = function() error('visibility blocked') end
    local secretTarget = object('Frame', 'TestSecretTarget', UIParent)
    local secretValue, oldSecret = {}, issecretvalue
    secretTarget.IsVisible = function() return secretValue end
    issecretvalue = function(value) return value == secretValue end
    local duplicate = object('Frame', 'TestDuplicateTarget', UIParent)
    duplicate.GetSystemName = function() return 'Player Frame' end
    EditModeManagerFrame.registeredSystemFrames = {target, hidden, blocked, secretTarget, duplicate}
    row.scripts.OnMouseUp(row, 'RightButton')
    assert(not menu.TestHiddenTarget and not menu.TestBlockedTarget and not menu.TestSecretTarget,
        'menu included hidden or unreadable targets')
    assert(menu['Player Frame (TestPlayerFrame)'] and menu['Player Frame (TestDuplicateTarget)'],
        'duplicate labels were not distinguished')
    SlashCmdList.FOREVERCDM('anchor cds TestHiddenTarget')
    assert(ForeverCDMDB.anchors.cds[1] == 'TestHiddenTarget', 'slash command rejected a hidden target')
    row.scripts.OnMouseUp(row, 'RightButton')
    assert(not menu.TestHiddenTarget and menu['Screen (detach)'], 'hidden saved target leaked into menu')
    menu['Screen (detach)'].choose()
    issecretvalue = oldSecret
    callbacks['EditMode.Exit']()
    menu = nil
    row.scripts.OnMouseUp(row, 'RightButton')
    assert(not menu, 'anchor menu opened outside Edit Mode')
end
print('frame anchoring, scaled offsets, detach, cycle rejection, late loading and menu checks passed')

if EventRegistry then
    local target = object('Frame', 'TestSnapFrame', UIParent)
    target.centerX, target.centerY, target.scale = 100, 100, 2
    target:SetSize(100, 30) -- 200 x 60 in UIParent coordinates, centred at 200,200
    local snapEnabled, shift = true, false
    IsShiftKeyDown = function() return shift end
    EditModeManagerFrame = {
        registeredSystemFrames = {target},
        IsSnapEnabled = function() return snapEnabled end,
    }
    ForeverCDM_buffs.centerX, ForeverCDM_buffs.centerY = -3000, -3000
    ForeverCDM_utility.centerX, ForeverCDM_utility.centerY = -3000, -3000
    row:SetSize(40, 20)
    local function dragAt(x, y)
        row.centerX, row.centerY = nil, nil
        row:ClearAllPoints()
        row:SetPoint('CENTER', UIParent, 'CENTER', x, y)
        row.scripts.OnDragStart(row)
        assert(row.scripts.OnUpdate, 'Edit Mode drag has no preview update')
        row.scripts.OnUpdate(row)
    end
    local function dropAt(x, y)
        row.scripts.OnDragStop(row)
        local actualX, actualY = row:GetCenter()
        assert(actualX == x and actualY == y,
            ('expected snap at %s,%s, got %s,%s'):format(x, y, actualX, actualY))
        assert(row.scripts.OnUpdate == nil and row.snapTargets == nil, 'drop left snap tracking active')
        if row.snapGuides then
            assert(not row.snapGuides[1]:IsShown() and not row.snapGuides[2]:IsShown(), 'drop left guides visible')
        end
    end
    callbacks['EditMode.Enter']()
    dragAt(205, 245)
    assert(row.snapGuides[1]:IsShown() and row.snapGuides[2]:IsShown(), 'alignment guides missing')
    dropAt(200, 240) -- centres align, row bottom touches target top
    assert(ForeverCDMDB.pos.cds[2] == 200 and ForeverCDMDB.pos.cds[3] == 240, 'snapped position not saved')
    assert(not ForeverCDMDB.anchors.cds, 'alignment unexpectedly attached the row')

    dragAt(126, 245)
    dropAt(120, 240) -- left edges align
    dragAt(275, 245)
    dropAt(280, 240) -- right edges align
    dragAt(205, 255)
    dropAt(200, 255) -- y is outside the 10-pixel tolerance
    dragAt(205, 500)
    dropAt(205, 500) -- distant matching centre must not attract the row

    dragAt(205, 245)
    shift = true
    row.scripts.OnUpdate(row)
    assert(not row.snapGuides[1]:IsShown(), 'Shift did not clear guides')
    dropAt(205, 245)
    shift = false
    dragAt(205, 245)
    snapEnabled = false -- changing the native checkbox during a drag takes effect
    row.scripts.OnUpdate(row)
    dropAt(205, 245)
    snapEnabled = true
    target:Hide()
    dragAt(205, 245)
    dropAt(205, 245)
    target:Show()

    target.IsVisible = function() error('visibility blocked') end
    dragAt(205, 245)
    dropAt(205, 245)
    local secretValue, oldSecret = {}, issecretvalue
    issecretvalue = function(value) return value == secretValue end
    target.IsVisible = function() return secretValue end
    dragAt(205, 245)
    dropAt(205, 245)
    issecretvalue = oldSecret
    target.IsVisible = function(self) return self:IsShown() end
    dragAt(205, 245)
    dropAt(200, 240) -- readable visibility restores snapping

    -- Snapping an attached row updates its offset without changing its target.
    SlashCmdList.FOREVERCDM('anchor cds TestSnapFrame')
    dragAt(205, 245)
    dropAt(200, 240)
    assert(ForeverCDMDB.anchors.cds[1] == 'TestSnapFrame'
        and ForeverCDMDB.anchors.cds[2] == 0 and ForeverCDMDB.anchors.cds[3] == 40,
        'snap lost the anchor or saved the wrong offset')
    dragAt(205, 245)
    callbacks['EditMode.Exit']()
    assert(not row.dragging and not row.snapGuides[1]:IsShown() and row.scripts.OnUpdate == nil,
        'leaving Edit Mode left the snap preview active')
    callbacks['EditMode.Enter']()
    dragAt(205, 245)
    inCombat = true
    fire('PLAYER_REGEN_DISABLED')
    assert(not row.dragging and not row.snapGuides[1]:IsShown() and row.scripts.OnUpdate == nil,
        'combat left the snap preview active')
    inCombat = false
    fire('PLAYER_REGEN_ENABLED')
    callbacks['EditMode.Exit']()
    print('snap tolerance, edges, centres, scaled targets, Shift, native toggle and cleanup checks passed')
end
