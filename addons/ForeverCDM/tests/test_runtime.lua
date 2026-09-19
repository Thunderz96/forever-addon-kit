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
function methods:GetCenter() return 0, 0 end
function methods:GetEffectiveScale() return 1 end
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
