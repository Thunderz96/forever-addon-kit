-- ForeverCDM_UI.lua -- config window: tick spells from your spellbook, tune size, lock.
-- Author: Thunderz
--
-- Opened with /fcdm (no arguments). Plain Blizzard templates only.

local CDM = ForeverCDM
local win

local function db() return CDM.GetDB() end

local function spellbookSpells()
    local out, seen = {}, {}
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
        local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if info then
                for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                    local item = C_SpellBook.GetSpellBookItemInfo(i, bank)
                    if item and item.spellID and not item.isPassive and not item.isOffSpec and not seen[item.spellID] then
                        seen[item.spellID] = true
                        out[#out + 1] = { id = item.spellID, name = item.name or CDM.SpellName(item.spellID), tab = info.name or "?" }
                    end
                end
            end
        end
    end
    -- anything tracked that is not in the book (added by ID) still needs a row
    local d = db()
    for _, key in ipairs({ "cds", "utilities", "buffs" }) do
        for _, id in ipairs(d[key]) do
            if not seen[id] then
                seen[id] = true
                out[#out + 1] = { id = id, name = CDM.SpellName(id), tab = "Other" }
            end
        end
    end
    table.sort(out, function(a, b) if a.tab ~= b.tab then return a.tab < b.tab end return a.name < b.name end)
    return out
end

local ROW_H = 24
local rowsPool = {}
local orderPool = {}
local refreshList

local function refreshOrderList()
    if not win or not win.orderPanel then return end
    local d, key = db(), win.orderKey or "cds"
    local list = d[key]
    for i = 1, #list do
        local row = orderPool[i]
        if not row then
            row = CreateFrame("Frame", nil, win.orderPanel)
            row:SetSize(200, 24)
            row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.name:SetPoint("LEFT", 2, 0)
            row.name:SetWidth(104)
            row.name:SetJustifyH("LEFT")
            row.up = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.up:SetSize(34, 20)
            row.up:SetPoint("LEFT", 108, 0)
            row.up:SetText("Up")
            row.down = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.down:SetSize(44, 20)
            row.down:SetPoint("LEFT", 144, 0)
            row.down:SetText("Down")
            orderPool[i] = row
        end
        row.index = i
        row.name:SetText(CDM.SpellName(list[i]))
        row.up:SetEnabled(i > 1)
        row.down:SetEnabled(i < #list)
        row.up:SetScript("OnClick", function(self)
            local current = db()[key]
            local index = self:GetParent().index
            if index > 1 then current[index], current[index - 1] = current[index - 1], current[index] end
            CDM.Refresh(); refreshOrderList()
        end)
        row.down:SetScript("OnClick", function(self)
            local current = db()[key]
            local index = self:GetParent().index
            if index < #current then current[index], current[index + 1] = current[index + 1], current[index] end
            CDM.Refresh(); refreshOrderList()
        end)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * 26)
        row:Show()
    end
    for i = #list + 1, #orderPool do orderPool[i]:Hide() end
    win.orderPanel:SetHeight(math.max(#list * 26, 1))
    win.orderTitle:SetText((key == "cds" and "Cooldowns" or key == "utilities" and "Utilities" or "Buffs") .. " order")
    win.orderClear:SetScript("OnClick", function() wipe(db()[key]); CDM.Refresh(); refreshList(); refreshOrderList() end)
end

refreshList = function()
    local d = db()
    local spells = spellbookSpells()
    local content = win.content
    for i, s in ipairs(spells) do
        local r = rowsPool[i]
        if not r then
            r = CreateFrame("Frame", nil, content)
            r:SetHeight(ROW_H)
            r.icon = r:CreateTexture(nil, "ARTWORK")
            r.icon:SetSize(20, 20)
            r.icon:SetPoint("LEFT", 4, 0)
            r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
            r.name:SetPoint("RIGHT", r, "RIGHT", -130, 0)
            r.name:SetJustifyH("LEFT")
            r.cd = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
            r.cd:SetSize(22, 22)
            r.cd:SetPoint("LEFT", r, "LEFT", 278, 0)
            r.utility = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
            r.utility:SetSize(22, 22)
            r.utility:SetPoint("LEFT", r, "LEFT", 310, 0)
            r.buff = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
            r.buff:SetSize(22, 22)
            r.buff:SetPoint("LEFT", r, "LEFT", 342, 0)
            local function toggle(key, id, on)
                local current = db()
                local list = current[key]
                local idx = CDM.Contains(list, id)
                if on and not idx then list[#list + 1] = id end
                if not on and idx then table.remove(list, idx) end
                CDM.Refresh()
                refreshOrderList()
            end
            r.cd:SetScript("OnClick", function(self) toggle("cds", self:GetParent().id, self:GetChecked()) end)
            r.utility:SetScript("OnClick", function(self) toggle("utilities", self:GetParent().id, self:GetChecked()) end)
            r.buff:SetScript("OnClick", function(self) toggle("buffs", self:GetParent().id, self:GetChecked()) end)
            r:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetSpellByID(self.id)
                GameTooltip:Show()
            end)
            r:SetScript("OnLeave", function() GameTooltip:Hide() end)
            r:EnableMouse(true)
            rowsPool[i] = r
        end
        r.id = s.id
        r.icon:SetTexture(CDM.SpellIcon(s.id))
        r.name:SetText(s.name .. "  |cff808080" .. s.tab .. "|r")
        r.cd:SetChecked(CDM.Contains(d.cds, s.id) ~= nil)
        r.utility:SetChecked(CDM.Contains(d.utilities, s.id) ~= nil)
        r.buff:SetChecked(CDM.Contains(d.buffs, s.id) ~= nil)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * ROW_H)
        r:SetPoint("RIGHT", content, "RIGHT", 0, 0)
        r:Show()
    end
    for i = #spells + 1, #rowsPool do rowsPool[i]:Hide() end
    content:SetHeight(math.max(#spells * ROW_H, 1))
    win.sizeText:SetText(tostring(d.size))
    win.spacingText:SetText(tostring(d.spacing))
    win.lockBtn:SetText(d.locked and "Unlock rows (drag)" or "Lock rows")
    win.hideReady:SetChecked(d.hideReady)
    win.names:SetChecked(d.showNames)

    refreshOrderList()
end

local function build()
    win = CreateFrame("Frame", "ForeverCDMConfig", UIParent, "BackdropTemplate")
    win:SetSize(850, 560)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
                      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 24,
                      insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    win:SetBackdropColor(0.05, 0.06, 0.07, 0.96)
    tinsert(UISpecialFrames, "ForeverCDMConfig")

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("|cffd2621fForever|r Cooldown Manager")
    local sub = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -2)
    sub:SetText("Choose bars on the left. Use Up / Down to set each bar's icon order.")

    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    -- column headers
    local hCD = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hCD:SetPoint("TOP", win, "TOPLEFT", 305, -56)
    hCD:SetText("CD")
    local hUtility = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hUtility:SetPoint("TOP", win, "TOPLEFT", 337, -56)
    hUtility:SetText("Util")
    local hBuff = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hBuff:SetPoint("TOP", win, "TOPLEFT", 369, -56)
    hBuff:SetText("Buff")

    -- spell list
    local scroll = CreateFrame("ScrollFrame", "ForeverCDMConfigScroll", win, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -70)
    scroll:SetPoint("BOTTOMRIGHT", win, "BOTTOMLEFT", 430, 16)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(400, 1)
    scroll:SetScrollChild(content)
    win.content = content

    -- right column
    local x, y = 690, -70
    local function label(text, dy)
        local fs = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", x, y + (dy or 0))
        fs:SetText(text)
        return fs
    end
    local function button(text, w, dy, onClick)
        local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        b:SetSize(w, 22)
        b:SetPoint("TOPLEFT", x, y + (dy or 0))
        b:SetText(text)
        b:SetScript("OnClick", onClick)
        return b
    end

    win.orderPanel = CreateFrame("ScrollFrame", "ForeverCDMOrderScroll", win, "UIPanelScrollFrameTemplate")
    win.orderPanel:SetPoint("TOPLEFT", 460, -92)
    win.orderPanel:SetSize(210, 220)
    local orderContent = CreateFrame("Frame", nil, win.orderPanel)
    orderContent:SetSize(200, 1)
    win.orderPanel:SetScrollChild(orderContent)
    win.orderPanel = orderContent
    win.orderTitle = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    win.orderTitle:SetPoint("TOPLEFT", 460, -70)
    local function orderTab(text, key, offset)
        local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        b:SetSize(66, 22)
        b:SetPoint("TOPLEFT", 460 + offset, -42)
        b:SetText(text)
        b:SetScript("OnClick", function() win.orderKey = key; refreshOrderList() end)
    end
    orderTab("CD", "cds", 0)
    orderTab("Utility", "utilities", 68)
    orderTab("Buff", "buffs", 138)
    win.orderClear = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.orderClear:SetSize(66, 22)
    win.orderClear:SetPoint("TOPLEFT", 460, -326)
    win.orderClear:SetText("Clear bar")
    win.orderKey = "cds"
    local function stepper(name, key, minV, maxV, dy)
        label(name, dy)
        local minus = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        minus:SetSize(22, 22) minus:SetText("-")
        minus:SetPoint("TOPLEFT", x, y + dy - 18)
        local val = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        val:SetPoint("LEFT", minus, "RIGHT", 8, 0)
        local plus = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        plus:SetSize(22, 22) plus:SetText("+")
        plus:SetPoint("LEFT", minus, "RIGHT", 40, 0)
        local function bump(delta)
            local d = db()
            d[key] = math.max(minV, math.min(maxV, d[key] + delta))
            CDM.Refresh()
            refreshList()
        end
        minus:SetScript("OnClick", function() bump(-2) end)
        plus:SetScript("OnClick", function() bump(2) end)
        return val
    end

    win.sizeText = stepper("Icon size", "size", 12, 96, 0)
    win.spacingText = stepper("Spacing", "spacing", 0, 30, -50)

    win.lockBtn = button("Unlock rows (drag)", 140, -100, function()
        ForeverCDM_SetLocked(not db().locked)
        refreshList()
    end)
    button("Auto-fill from spellbook", 140, -128, function()
        local n = CDM.Auto()
        CDM.Refresh()
        refreshList()
        print("|cffd2621fForever CDM|r: added " .. n .. " spells.")
    end)
    button("Clear all", 140, -156, function()
        local d = db()
        wipe(d.cds) wipe(d.utilities) wipe(d.buffs)
        CDM.Refresh()
        refreshList()
    end)

    local function check(text, key, dy)
        local c = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
        c:SetSize(24, 24)
        c:SetPoint("TOPLEFT", x - 4, y + dy)
        c.text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        c.text:SetPoint("LEFT", c, "RIGHT", 2, 0)
        c.text:SetText(text)
        c:SetScript("OnClick", function(self)
            db()[key] = self:GetChecked() and true or false
            CDM.Refresh()
        end)
        return c
    end
    win.hideReady = check("Hide ready cooldowns", "hideReady", -200)
    win.names = check("Show spell names", "showNames", -228)

    local addBox = CreateFrame("EditBox", "ForeverCDMConfigAdd", win, "InputBoxTemplate")
    addBox:SetSize(140, 22)
    addBox:SetPoint("TOPLEFT", x + 6, y - 280)
    addBox:SetAutoFocus(false)
    label("Add by name or ID", -262)
    button("+ CD", 66, -308, function()
        local id = CDM.Resolve(addBox:GetText())
        if id then local d = db() if not CDM.Contains(d.cds, id) then d.cds[#d.cds + 1] = id end addBox:SetText("") CDM.Refresh() refreshList() end
    end)
    local b2 = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    b2:SetSize(66, 22) b2:SetText("+ Buff")
    b2:SetPoint("TOPLEFT", x + 74, y - 308)
    b2:SetScript("OnClick", function()
        local id = CDM.Resolve(addBox:GetText())
        if id then local d = db() if not CDM.Contains(d.buffs, id) then d.buffs[#d.buffs + 1] = id end addBox:SetText("") CDM.Refresh() refreshList() end
    end)
    local b3 = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    b3:SetSize(66, 22) b3:SetText("+ Utility")
    b3:SetPoint("TOPLEFT", x, y - 336)
    b3:SetScript("OnClick", function()
        local id = CDM.Resolve(addBox:GetText())
        if id then local d = db() if not CDM.Contains(d.utilities, id) then d.utilities[#d.utilities + 1] = id end addBox:SetText("") CDM.Refresh() refreshList() refreshOrderList() end
    end)

    local hint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", x, 18)
    hint:SetWidth(140)
    hint:SetJustifyH("LEFT")
    hint:SetText("New spells appear as choices automatically. Buffs marked ? have unavailable tracking data.")

    win:SetScript("OnShow", refreshList)
    win:Hide()
end

function ForeverCDM_ToggleConfig()
    if not win then build() end
    if win:IsShown() then win:Hide() else win:Show() end
end

function ForeverCDM_RefreshConfig()
    if win and win:IsShown() then refreshList() end
end
