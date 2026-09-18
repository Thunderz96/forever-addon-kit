-- ForeverCDM_UI.lua -- settings window and minimap button.
-- Author: Thunderz
--
-- Opened with /fcdm or the minimap button. Every widget here is drawn from
-- plain frames and solid-colour textures, with no Blizzard templates. Two
-- reasons: the window looks the same whatever UI suite is installed (suites
-- reskin Blizzard's templates, often badly), and nothing depends on a template
-- that a given client build might not ship.

local CDM = ForeverCDM
local win

local ICON_PATH = "Interface\\AddOns\\ForeverCDM\\media\\icon.tga"

-- Palette. ACCENT is the addon's orange, d2621f.
local BG      = { 0.055, 0.055, 0.065 }
local CARD    = { 0.090, 0.090, 0.105 }
local LINE    = { 0.200, 0.200, 0.230 }
local BTN     = { 0.150, 0.150, 0.175 }
local BTN_HI  = { 0.220, 0.220, 0.255 }
local ACCENT  = { 0.824, 0.384, 0.122 }
local DIM     = { 0.600, 0.600, 0.640 }

local function db() return CDM.GetDB() end

-- Widget kit ----------------------------------------------------------------------

local function fill(frame, layer, c, a)
    local t = frame:CreateTexture(nil, layer or "BACKGROUND")
    t:SetAllPoints()
    t:SetColorTexture(c[1], c[2], c[3], a or 1)
    return t
end

-- One-pixel outline made of four strips (a backdrop would need a template).
local function outline(frame, c, a)
    local function strip(p1, p2, horizontal)
        local t = frame:CreateTexture(nil, "BORDER")
        t:SetColorTexture(c[1], c[2], c[3], a or 1)
        t:SetPoint(p1) t:SetPoint(p2)
        if horizontal then t:SetHeight(1) else t:SetWidth(1) end
    end
    strip("TOPLEFT", "TOPRIGHT", true)
    strip("BOTTOMLEFT", "BOTTOMRIGHT", true)
    strip("TOPLEFT", "BOTTOMLEFT", false)
    strip("TOPRIGHT", "BOTTOMRIGHT", false)
end

local function text(parent, font, str, c)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    if str then fs:SetText(str) end
    if c then fs:SetTextColor(c[1], c[2], c[3]) end
    return fs
end

local function paint(b)
    local c = b.active and ACCENT or (b.hover and BTN_HI or BTN)
    b.bg:SetColorTexture(c[1], c[2], c[3], 1)
end

local function flatButton(parent, label, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h or 22)
    b.bg = fill(b, "BACKGROUND", BTN)
    outline(b, LINE)
    b.label = text(b, "GameFontHighlightSmall", label)
    b.label:SetPoint("CENTER")
    b:SetFontString(b.label)          -- so b:SetText() keeps working
    b:SetScript("OnEnter", function(self) self.hover = true paint(self) end)
    b:SetScript("OnLeave", function(self) self.hover = false paint(self) end)
    b:SetScript("OnDisable", function(self) self.label:SetTextColor(0.35, 0.35, 0.38) end)
    b:SetScript("OnEnable", function(self) self.label:SetTextColor(1, 1, 1) end)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

local function setActive(b, on)
    b.active = on and true or false
    paint(b)
end

-- Small square button carrying an arrow. Uses the atlas from Blizzard's modern
-- scrollbar; if a client ever lacks it, a plain character stands in.
local function arrowButton(parent, atlas, fallback)
    if not (C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)) then
        return flatButton(parent, fallback, 20, 20)
    end
    local b = flatButton(parent, "", 20, 20)
    b.arrow = b:CreateTexture(nil, "ARTWORK")
    b.arrow:SetAtlas(atlas)
    b.arrow:SetSize(12, 8)
    b.arrow:SetPoint("CENTER")
    b:SetScript("OnDisable", function(self) self.arrow:SetVertexColor(0.3, 0.3, 0.33) end)
    b:SetScript("OnEnable", function(self) self.arrow:SetVertexColor(1, 1, 1) end)
    return b
end

local function checkbox(parent)
    local c = CreateFrame("CheckButton", nil, parent)
    c:SetSize(16, 16)
    fill(c, "BACKGROUND", BG)
    outline(c, LINE)
    local mark = c:CreateTexture(nil, "ARTWORK")
    mark:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    mark:SetPoint("TOPLEFT", 3, -3)
    mark:SetPoint("BOTTOMRIGHT", -3, 3)
    c:SetCheckedTexture(mark)
    return c
end

local function card(parent, title, x, w, top, bottom)
    local f = CreateFrame("Frame", nil, parent)
    f:SetPoint("TOPLEFT", x, top)
    f:SetPoint("BOTTOMLEFT", x, bottom)
    f:SetWidth(w)
    fill(f, "BACKGROUND", CARD)
    outline(f, LINE)
    f.title = text(f, "GameFontNormalSmall", title, ACCENT)
    f.title:SetPoint("TOPLEFT", 10, -9)
    return f
end

-- Mouse-wheel scroll area with a slim position thumb. Returns the scroll frame
-- and its content frame.
local function scrollArea(parent)
    local sf = CreateFrame("ScrollFrame", nil, parent)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(10, 1)
    sf:SetScrollChild(content)
    local thumb = sf:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.7)
    thumb:SetWidth(3)
    local function update()
        local range = sf:GetVerticalScrollRange() or 0
        local h = sf:GetHeight() or 1
        if range <= 0.5 then thumb:Hide() return end
        local th = math.max(24, h * h / (h + range))
        local pos = (sf:GetVerticalScroll() / range) * (h - th)
        thumb:SetHeight(th)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", sf, "TOPRIGHT", 0, -pos)
        thumb:Show()
    end
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local range = self:GetVerticalScrollRange() or 0
        self:SetVerticalScroll(math.max(0, math.min(range, self:GetVerticalScroll() - delta * 48)))
        update()
    end)
    sf:SetScript("OnScrollRangeChanged", function(self, _, yRange)
        if self:GetVerticalScroll() > (yRange or 0) then self:SetVerticalScroll(yRange or 0) end
        update()
    end)
    return sf, content
end

-- Data ----------------------------------------------------------------------------

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
    table.sort(out, function(a, b)
        if a.tab ~= b.tab then return a.tab < b.tab end
        if a.name ~= b.name then return a.name < b.name end
        local ra, rb = CDM.RankNumber(a.id), CDM.RankNumber(b.id)      -- Rank 2 before Rank 10
        if ra ~= rb then return ra < rb end
        return a.id < b.id
    end)
    return out
end

-- "Seal of Righteousness  Rank 2", the rank dimmed. Every rank is its own spell on Forever.
local function nameWithRank(id, name)
    local rank = CDM.SpellRank(id)
    return rank and (name .. "  |cff8c8c96" .. rank .. "|r") or name
end

local ROW_H, HEAD_H, ORDER_H = 24, 22, 26
local BAR_NAMES = { cds = "Cooldowns", utilities = "Utility", buffs = "Buffs" }
local rowsPool, headPool, orderPool = {}, {}, {}
local refreshList

-- Bar order (middle card) -----------------------------------------------------------

local function refreshOrderList()
    if not win or not win.orderPanel then return end
    local key = win.orderKey or "cds"
    local list = db()[key]
    for i = 1, #list do
        local row = orderPool[i]
        if not row then
            row = CreateFrame("Frame", nil, win.orderPanel)
            row:SetHeight(ORDER_H - 2)
            row.stripe = fill(row, "BACKGROUND", BG, 0.55)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(18, 18)
            row.icon:SetPoint("LEFT", 4, 0)
            row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.name = text(row, "GameFontHighlightSmall")
            row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
            row.name:SetPoint("RIGHT", row, "RIGHT", -50, 0)
            row.name:SetJustifyH("LEFT")
            row.down = arrowButton(row, "minimal-scrollbar-arrow-bottom", "v")
            row.down:SetPoint("RIGHT", -2, 0)
            row.up = arrowButton(row, "minimal-scrollbar-arrow-top", "^")
            row.up:SetPoint("RIGHT", row.down, "LEFT", -2, 0)
            orderPool[i] = row
        end
        row.index = i
        row.icon:SetTexture(CDM.SpellIcon(list[i]))
        row.name:SetText(nameWithRank(list[i], CDM.SpellName(list[i])))
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
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ORDER_H)
        row:SetPoint("RIGHT", win.orderPanel, "RIGHT", 0, 0)
        row:Show()
    end
    for i = #list + 1, #orderPool do orderPool[i]:Hide() end
    win.orderPanel:SetHeight(math.max(#list * ORDER_H, 1))
    for k, b in pairs(win.orderTabs) do setActive(b, k == key) end
    win.orderTitle:SetText(#list == 0 and "Empty. Tick spells on the left."
        or (#list .. (#list == 1 and " icon" or " icons") .. ", shown left to right"))
    win.orderClear:SetText("Clear " .. BAR_NAMES[key])
    win.sizeText:SetText(tostring(db().rowSize[key]))
    win.spacingText:SetText(tostring(db().rowSpacing[key]))
    win.orderClear:SetScript("OnClick", function() wipe(db()[key]); CDM.Refresh(); refreshList(); refreshOrderList() end)
end

-- Spellbook (left card) -------------------------------------------------------------

local function newSpellRow(content)
    local r = CreateFrame("Frame", nil, content)
    r:SetHeight(ROW_H)
    r.hover = fill(r, "BACKGROUND", BTN_HI, 0.35)
    r.hover:Hide()
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(20, 20)
    r.icon:SetPoint("LEFT", 6, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.name = text(r, "GameFontHighlight")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
    r.name:SetPoint("RIGHT", r, "RIGHT", -130, 0)
    r.name:SetJustifyH("LEFT")
    r.buff = checkbox(r)    r.buff:SetPoint("CENTER", r, "RIGHT", -22, 0)
    r.utility = checkbox(r) r.utility:SetPoint("CENTER", r, "RIGHT", -62, 0)
    r.cd = checkbox(r)      r.cd:SetPoint("CENTER", r, "RIGHT", -102, 0)
    local function toggle(key, id, on)
        local list = db()[key]
        local idx = CDM.Contains(list, id)
        if on and not idx then list[#list + 1] = id end
        if not on and idx then table.remove(list, idx) end
        CDM.Refresh()
        refreshOrderList()
    end
    r.cd:SetScript("OnClick", function(self) toggle("cds", self:GetParent().id, self:GetChecked()) end)
    r.utility:SetScript("OnClick", function(self) toggle("utilities", self:GetParent().id, self:GetChecked()) end)
    r.buff:SetScript("OnClick", function(self) toggle("buffs", self:GetParent().id, self:GetChecked()) end)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
        self.hover:Show()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(self.id)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function(self) self.hover:Hide() GameTooltip:Hide() end)
    return r
end

refreshList = function()
    local d = db()
    local spells = spellbookSpells()
    local content = win.content
    local y, heads, lastTab = 0, 0, nil
    for i, s in ipairs(spells) do
        if s.tab ~= lastTab then            -- one heading per spell school
            lastTab = s.tab
            heads = heads + 1
            local h = headPool[heads]
            if not h then
                h = CreateFrame("Frame", nil, content)
                h:SetHeight(HEAD_H)
                h.label = text(h, "GameFontNormalSmall", nil, DIM)
                h.label:SetPoint("BOTTOMLEFT", 6, 4)
                h.rule = h:CreateTexture(nil, "ARTWORK")
                h.rule:SetColorTexture(LINE[1], LINE[2], LINE[3], 1)
                h.rule:SetHeight(1)
                h.rule:SetPoint("BOTTOMLEFT", 4, 0)
                h.rule:SetPoint("BOTTOMRIGHT", -4, 0)
                headPool[heads] = h
            end
            h.label:SetText(string.upper(s.tab))
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            h:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            h:Show()
            y = y + HEAD_H
        end
        local r = rowsPool[i]
        if not r then
            r = newSpellRow(content)
            rowsPool[i] = r
        end
        r.id = s.id
        r.icon:SetTexture(CDM.SpellIcon(s.id))
        r.name:SetText(nameWithRank(s.id, s.name))
        r.cd:SetChecked(CDM.Contains(d.cds, s.id) ~= nil)
        r.utility:SetChecked(CDM.Contains(d.utilities, s.id) ~= nil)
        r.buff:SetChecked(CDM.Contains(d.buffs, s.id) ~= nil)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        r:SetPoint("RIGHT", content, "RIGHT", 0, 0)
        r:Show()
        y = y + ROW_H
    end
    for i = #spells + 1, #rowsPool do rowsPool[i]:Hide() end
    for i = heads + 1, #headPool do headPool[i]:Hide() end
    content:SetHeight(math.max(y, 1))

    win.lockBtn:SetText(d.locked and "Unlock rows to drag" or "Lock rows")
    setActive(win.lockBtn, not d.locked)
    win.hideReady:SetChecked(d.hideReady)
    win.names:SetChecked(d.showNames)
    win.minimap:SetChecked(not d.minimap.hide)
    win.macroMirror:SetChecked(d.macroMirror and true or false)
    refreshOrderList()
end

-- Window ---------------------------------------------------------------------------

local function build()
    win = CreateFrame("Frame", "ForeverCDMConfig", UIParent)
    win:SetSize(880, 580)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:SetToplevel(true)
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    fill(win, "BACKGROUND", BG, 0.985)
    outline(win, LINE)
    tinsert(UISpecialFrames, "ForeverCDMConfig")   -- Escape closes it

    -- header bar
    local head = CreateFrame("Frame", nil, win)
    head:SetPoint("TOPLEFT", 1, -1)
    head:SetPoint("TOPRIGHT", -1, -1)
    head:SetHeight(40)
    fill(head, "BACKGROUND", CARD)
    local rule = head:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    rule:SetHeight(2)
    rule:SetPoint("BOTTOMLEFT") rule:SetPoint("BOTTOMRIGHT")
    local logo = head:CreateTexture(nil, "ARTWORK")
    logo:SetTexture(ICON_PATH)
    logo:SetSize(26, 26)
    logo:SetPoint("LEFT", 10, 1)
    local title = text(head, "GameFontNormalLarge", "|cffd2621fForever|r Cooldown Manager", { 1, 1, 1 })
    title:SetPoint("LEFT", logo, "RIGHT", 10, 0)
    local close = flatButton(head, "x", 24, 24, function() win:Hide() end)
    close:SetPoint("RIGHT", -8, 1)

    local TOP, BOTTOM = -52, 34

    -- left: spellbook
    local book = card(win, "SPELLBOOK", 14, 420, TOP, BOTTOM)
    for label, offset in pairs({ CD = -116, UTIL = -76, BUFF = -36 }) do
        local h = text(book, "GameFontNormalSmall", label, DIM)
        h:SetPoint("CENTER", book, "TOPRIGHT", offset, -15)
    end
    local scroll, content = scrollArea(book)
    scroll:SetPoint("TOPLEFT", 8, -28)
    scroll:SetPoint("BOTTOMRIGHT", -8, 8)
    content:SetWidth(420 - 16 - 6)      -- card minus insets minus the thumb gutter
    win.content = content

    -- middle: one bar at a time. The tabs pick the bar; its icon order, size and
    -- spacing all live here, so each bar can be sized on its own.
    local order = card(win, "BARS", 444, 222, TOP, BOTTOM)
    win.orderTabs = {}
    local tabX = 8
    for _, key in ipairs({ "cds", "utilities", "buffs" }) do
        local b = flatButton(order, BAR_NAMES[key], 68, 22, function() win.orderKey = key; refreshOrderList() end)
        b:SetPoint("TOPLEFT", tabX, -28)
        win.orderTabs[key] = b
        tabX = tabX + 69
    end
    win.orderTitle = text(order, "GameFontHighlightSmall", nil, DIM)
    win.orderTitle:SetPoint("TOPLEFT", 10, -58)
    local oscroll, ocontent = scrollArea(order)
    oscroll:SetPoint("TOPLEFT", 8, -76)
    oscroll:SetPoint("BOTTOMRIGHT", -8, 108)
    ocontent:SetWidth(222 - 16 - 6)
    win.orderPanel = ocontent
    win.orderKey = "cds"

    -- size and spacing of the selected bar: label on the left, "- value +" on the right
    local rule = order:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(LINE[1], LINE[2], LINE[3], 1)
    rule:SetHeight(1)
    rule:SetPoint("BOTTOMLEFT", 8, 100)
    rule:SetPoint("BOTTOMRIGHT", -8, 100)
    local function barStepper(name, field, minV, maxV, fromBottom)
        local label = text(order, "GameFontHighlightSmall", name, DIM)
        label:SetPoint("LEFT", order, "BOTTOMLEFT", 10, fromBottom + 11)
        local function bump(delta)
            local values = db()[field]
            local key = win.orderKey or "cds"
            values[key] = math.max(minV, math.min(maxV, values[key] + delta))
            CDM.Refresh()
            refreshOrderList()
        end
        local plus = flatButton(order, "+", 24, 22, function() bump(2) end)
        plus:SetPoint("BOTTOMRIGHT", -8, fromBottom)
        local minus = flatButton(order, "-", 24, 22, function() bump(-2) end)
        minus:SetPoint("BOTTOMRIGHT", -92, fromBottom)
        local val = text(order, "GameFontHighlight")
        val:SetPoint("CENTER", order, "BOTTOMRIGHT", -62, fromBottom + 11)
        return val, minus, plus
    end
    win.sizeText, win.sizeMinus, win.sizePlus = barStepper("Icon size", "rowSize", 12, 96, 68)
    win.spacingText, win.spacingMinus, win.spacingPlus = barStepper("Spacing", "rowSpacing", 0, 30, 40)
    win.orderClear = flatButton(order, "Clear", 206, 22)
    win.orderClear:SetPoint("BOTTOMLEFT", 8, 9)

    -- right: settings
    local opts = card(win, "SETTINGS", 676, 190, TOP, BOTTOM)
    local y = -32
    local function caption(str)
        local fs = text(opts, "GameFontHighlightSmall", str, DIM)
        fs:SetPoint("TOPLEFT", 10, y)
        y = y - 16
    end
    local function check(str, onClick)
        local c = checkbox(opts)
        c:SetPoint("TOPLEFT", 10, y)
        c.text = text(opts, "GameFontHighlightSmall", str)
        c.text:SetPoint("LEFT", c, "RIGHT", 8, 0)
        c:SetScript("OnClick", onClick)
        y = y - 24
        return c
    end
    local function wide(str, onClick)
        local b = flatButton(opts, str, 170, 24, onClick)
        b:SetPoint("TOPLEFT", 10, y)
        y = y - 28
        return b
    end

    win.hideReady = check("Hide ready cooldowns", function(self) db().hideReady = self:GetChecked() and true or false CDM.Refresh() end)
    win.names = check("Show spell names", function(self) db().showNames = self:GetChecked() and true or false CDM.Refresh() end)
    win.minimap = check("Minimap button", function(self) ForeverCDM_SetMinimapShown(self:GetChecked() and true or false) end)
    win.macroMirror = check("Keep settings in a macro", function(self) ForeverCDM_SetMacroMirror(self:GetChecked() and true or false) end)
    local why = text(opts, "GameFontDisableSmall", "The beta client forgets addon settings when the game restarts. This saves your setup in one general macro and reads it back at login.")
    why:SetPoint("TOPLEFT", 34, y + 4)
    why:SetWidth(148)
    why:SetJustifyH("LEFT")
    y = y - 50

    y = y - 8
    win.lockBtn = wide("Unlock rows to drag", function() ForeverCDM_SetLocked(not db().locked) refreshList() end)
    wide("Auto-fill from spellbook", function()
        local n = CDM.Auto()
        CDM.Refresh()
        refreshList()
        print("|cffd2621fForever CDM|r: added " .. n .. " spells.")
    end)
    wide("Clear everything", function()
        local d = db()
        wipe(d.cds) wipe(d.utilities) wipe(d.buffs)
        CDM.Refresh()
        refreshList()
    end)

    y = y - 8
    caption("Add by name or spell ID")
    local addBox = CreateFrame("EditBox", "ForeverCDMConfigAdd", opts)
    addBox:SetSize(170, 22)
    addBox:SetPoint("TOPLEFT", 10, y)
    addBox:SetFontObject("ChatFontNormal")
    addBox:SetTextInsets(6, 6, 0, 0)
    addBox:SetAutoFocus(false)
    fill(addBox, "BACKGROUND", BG)
    outline(addBox, LINE)
    addBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    addBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    y = y - 28
    local addX = 10
    for _, key in ipairs({ "cds", "utilities", "buffs" }) do
        local b = flatButton(opts, "+ " .. (key == "cds" and "CD" or key == "utilities" and "Util" or "Buff"), 54, 22, function()
            local id = CDM.Resolve(addBox:GetText())
            if not id then return end
            local list = db()[key]
            if not CDM.Contains(list, id) then list[#list + 1] = id end
            addBox:SetText("")
            addBox:ClearFocus()
            CDM.Refresh()
            refreshList()
        end)
        b:SetPoint("TOPLEFT", addX, y)
        addX = addX + 58
    end

    -- footer
    local ver = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("ForeverCDM", "Version")
    local foot = text(win, "GameFontDisableSmall", "v" .. tostring(ver or "?") .. "   /fcdm help for commands")
    foot:SetPoint("BOTTOMLEFT", 16, 12)
    local hint = text(win, "GameFontDisableSmall", "A buff showing ? was applied in combat by someone else and cannot be confirmed until the fight ends.")
    hint:SetPoint("BOTTOMRIGHT", -16, 12)

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

-- Minimap button --------------------------------------------------------------------
-- Hand-rolled rather than LibDBIcon so the addon stays free of libraries. Drag it
-- round the minimap edge; the angle is saved. Left-click opens settings,
-- right-click locks or unlocks the rows.

local mm
local atan2 = math.atan2 or math.atan      -- Lua 5.1 in game, 5.4 under the tests

local function placeMinimap()
    local a = math.rad(db().minimap.angle or 215)
    local half = (Minimap:GetWidth() or 140) / 2
    local x, y = math.cos(a) * (half + 6), math.sin(a) * (half + 6)
    if GetMinimapShape and GetMinimapShape() == "SQUARE" then
        -- push the point out to the square's edge instead of cutting the corner
        x = math.max(-half, math.min(half, x * 1.42))
        y = math.max(-half, math.min(half, y * 1.42))
    end
    mm:ClearAllPoints()
    mm:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function buildMinimap()
    mm = CreateFrame("Button", "ForeverCDMMinimapButton", Minimap)
    mm:SetSize(31, 31)
    mm:SetFrameStrata("MEDIUM")
    mm:SetFrameLevel(8)
    mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    mm:RegisterForDrag("LeftButton")
    mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local back = mm:CreateTexture(nil, "BACKGROUND")
    back:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    back:SetSize(20, 20)
    back:SetPoint("TOPLEFT", 7, -5)
    local icon = mm:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON_PATH)
    icon:SetSize(18, 18)
    icon:SetPoint("TOPLEFT", 7, -6)
    local ring = mm:CreateTexture(nil, "OVERLAY")
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetSize(53, 53)
    ring:SetPoint("TOPLEFT")

    mm:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ForeverCDM_SetLocked(not db().locked)
            ForeverCDM_RefreshConfig()
            print("|cffd2621fForever CDM|r: rows " .. (db().locked and "locked." or "unlocked, drag them into place."))
        else
            ForeverCDM_ToggleConfig()
        end
    end)
    mm:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local cx, cy = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            db().minimap.angle = math.deg(atan2(py / scale - cy, px / scale - cx))
            placeMinimap()
        end)
    end)
    mm:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) CDM.Persist() end)
    mm:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cffd2621fForever|r Cooldown Manager")
        GameTooltip:AddLine("Left-click: settings", 1, 1, 1)
        GameTooltip:AddLine("Right-click: lock or unlock the rows", 1, 1, 1)
        GameTooltip:AddLine("Drag: move this button", 0.6, 0.6, 0.64)
        GameTooltip:Show()
    end)
    mm:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function ForeverCDM_SetMinimapShown(shown)
    db().minimap.hide = not shown
    CDM.Persist()
    if not Minimap then return end
    if shown and not mm then buildMinimap() end
    if mm then
        mm:SetShown(shown)
        if shown then placeMinimap() end
    end
end

-- Called by ForeverCDM.lua at PLAYER_LOGIN, once the settings table exists.
function ForeverCDM_InitMinimap()
    ForeverCDM_SetMinimapShown(not db().minimap.hide)
end
