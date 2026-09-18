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
for _, name in ipairs({ 'SetTexCoord', 'ClearAllPoints', 'SetMovable', 'SetClampedToScreen',
    'SetDrawEdge', 'SetHideCountdownNumbers', 'SetDesaturated', 'SetCooldown',
    'SetCooldownFromDurationObject', 'Clear', 'SetAllPoints', 'SetColorTexture',
    'RegisterForDrag', 'StartMoving', 'StopMovingOrSizing', 'SetFrameStrata',
    'SetBackdrop', 'SetBackdropColor', 'SetJustifyH', 'SetAutoFocus', 'SetOwner',
    'SetSpellByID', 'SetVerticalScroll', 'SetScrollStep', 'SetEnabled' }) do methods[name] = noop end
function methods:SetSize(w, h) self.width, self.height = w, h end
function methods:SetHeight(h) self.height = h end
function methods:SetWidth(w) self.width = w end
function methods:GetWidth() return self.width or 100 end
function methods:GetHeight() return self.height or 100 end
function methods:SetPoint(...) self.point = {...} end
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
C_Timer = { NewTicker = noop, After = function(_, fn) fn() end }
Enum = { SpellBookSpellBank = { Player = 0 } }
local spells = {101, 102}
local names = { [101] = 'First Spell', [102] = 'Second Spell', [103] = 'Newly Learned' }
C_Spell = {
    GetSpellName = function(id) return names[id] end,
    GetSpellTexture = function(id) return id end,
    GetSpellCooldown = function() return { startTime = 0, duration = 0, isEnabled = true } end,
    GetSpellCharges = function() return nil end,
}
C_UnitAuras = { GetPlayerAuraBySpellID = function() return nil end }
C_SpellBook = {
    GetNumSpellBookSkillLines = function() return 1 end,
    GetSpellBookSkillLineInfo = function() return { itemIndexOffset = 0, numSpellBookItems = #spells, name = 'Paladin' } end,
    GetSpellBookItemInfo = function(i) return { spellID = spells[i], name = names[spells[i]] } end,
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
print('runtime migration, config, learned-spell refresh, and utility checks passed')
