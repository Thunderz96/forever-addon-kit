#!/usr/bin/env python3
"""apply_eui_fixes.py -- Forever-specific source patches for the BETA copies of
ported addons (EllesmereUI, BugSack).
Author: Thunderz

Idempotent: safe to re-run after port_to_beta.py re-copies an addon. Each patch
is a literal find/replace that is skipped when already applied, and reported
when its target text is no longer found (upstream changed).
Missing-API problems are handled by !!ForeverCompat instead; these are the
cases that needed a source change.
"""
import os
import re
import sys

ADDONS = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns"
TAG = "FOREVER-BETA"

TAB_OLD = '\t\t"{name}",\n\t\twindow,\n\t\tisRetail and "CharacterFrameTabTemplate" or "CharacterFrameTabButtonTemplate"\n'
TAB_NEW = '\t\t"{name}",\n\t\twindow,\n\t\tFOREVER_TAB_TEMPLATE -- ' + TAG + '\n'

PATCHES = [
    # 1. First-install picker. Harmless once settings load, but if a launch ever
    #    comes up without them it would force a ReloadUI that saves defaults.
    ("EllesmereUI\\EllesmereUI_FirstInstall.lua",
     "local function ComputeShowOnLogin()\n    if not EllesmereUIDB then",
     "local function ComputeShowOnLogin()\n    do return false end -- " + TAG
     + ": never auto-show the picker on this client\n    if not EllesmereUIDB then"),
    # 2. Minimap: Blizzard's RefreshButton indexes ExpansionLandingPage, which
    #    does not exist on Forever (no expansion landing page at all).
    ("EllesmereUIMinimap\\EllesmereUIMinimap.lua",
     "    if not btn:IsShown() and btn.RefreshButton then\n        btn:RefreshButton(true)",
     "    if not btn:IsShown() and btn.RefreshButton and ExpansionLandingPage then -- " + TAG
     + "\n        btn:RefreshButton(true)"),
    # 3. LibSpecialization raises an error for every spec ID it has never seen;
    #    Forever's are all new (e.g. 1486).
    ("EllesmereUI\\Libs\\LibSpecialization\\LibSpecialization.lua",
     '\t\t\t\t\tgeterrorhandler()(format("LibSpecialization: Unknown specId %q", specId))',
     "\t\t\t\t\t-- " + TAG + ": Forever spec IDs are unknown to this library; stay quiet\n\t\t\t\t\tlocal _ = specId"),
    # 4. BugSack: its Retail path asks for CharacterFrameTabTemplate, which the
    #    Forever client does not have, so the error window could never open
    #    ("Couldn't find inherited node"). Probe for a template that exists.
    ("BugSack\\sack.lua",
     "local isRetail = addon.isRetail\n",
     "local isRetail = addon.isRetail\n"
     "-- " + TAG + ": pick a tab template this client actually has\n"
     "local FOREVER_TAB_TEMPLATE\n"
     'for _, tpl in ipairs({ "CharacterFrameTabTemplate", "CharacterFrameTabButtonTemplate", '
     '"PanelTabButtonTemplate", "PanelTopTabButtonTemplate" }) do\n'
     '\tlocal ok, probe = pcall(CreateFrame, "Button", nil, UIParent, tpl)\n'
     "\tif ok and probe then probe:Hide() FOREVER_TAB_TEMPLATE = tpl break end\n"
     "end\n"),
    # 5. Cooldown Manager: its only secure-snippet use hides the bars in a
    #    vehicle or pet battle. Snippets cannot compile on build 1.60.1.69893
    #    (loadstring_untainted is nil), so skip it; the rest of the module is
    #    ordinary code and works.
    ("EllesmereUICooldownManager\\EllesmereUICooldownManager.lua",
     "    if not _cdmVehicleProxy then\n        _cdmVehicleProxy = CreateFrame(\"Frame\", nil, UIParent, \"SecureHandlerStateTemplate\")",
     "    if not _cdmVehicleProxy and loadstring_untainted then -- " + TAG
     + ": secure snippets cannot compile on this build\n"
     "        _cdmVehicleProxy = CreateFrame(\"Frame\", nil, UIParent, \"SecureHandlerStateTemplate\")"),
    # 6. BugGrabber pauses itself above 10 errors/sec. The action bars' ~60
    #    identical snippet errors at load trip that every session, so nothing
    #    after them is ever recorded. Raise the bar; it still dedupes.
    ("!BugGrabber\\BugGrabber.lua",
     "BUGGRABBER_ERRORS_PER_SEC_BEFORE_THROTTLE = 10",
     "BUGGRABBER_ERRORS_PER_SEC_BEFORE_THROTTLE = 300 -- " + TAG + ": was 10; snippet-error bursts paused it before real errors"),
    # 8. Character sheet: the stats pane EUI parks off-screen is named
    #    CharacterStatPane in its code, but this client's frame is
    #    CharacterStatsPane, so Blizzard's stats drew over EUI's own panel.
    ("EllesmereUIBlizzardSkin\\EllesmereUIBlizzardSkin_CharacterSheet.lua",
     "    if CharacterStatPane then\n",
     "    local CharacterStatPane = CharacterStatPane or _G.CharacterStatsPane -- " + TAG
     + ": Forever names the pane with an s\n    if CharacterStatPane then\n"),
    # 8b. Blizzard re-anchors the stats pane every time the sheet opens, so a
    #     one-time park is undone. Re-park the pane and its scroll boxes on
    #     each show (and after each stats refresh) and fade them out.
    ("EllesmereUIBlizzardSkin\\EllesmereUIBlizzardSkin_CharacterSheet.lua",
     '        CharacterStatPane:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -10000)\n    end\n',
     '        CharacterStatPane:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -10000)\n    end\n'
     "    -- " + TAG + ": Blizzard re-anchors the stats pane on show; re-park it every time\n"
     "    local function ForeverParkStats()\n"
     "        for _, f in ipairs({ _G.CharacterStatsPane, _G.CharacterStatsPaneScrollBox, _G.CharacterStatsPanePetScrollBox }) do\n"
     "            if f and not f:IsForbidden() then\n"
     "                f:ClearAllPoints()\n"
     '                f:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -10000)\n'
     "                f:SetAlpha(0)\n"
     "            end\n"
     "        end\n"
     "    end\n"
     "    local function ForeverParkStatsSoon()\n"
     "        if C_Timer then C_Timer.After(0, ForeverParkStats) else ForeverParkStats() end\n"
     "    end\n"
     "    ForeverParkStats()\n"
     '    frame:HookScript("OnShow", ForeverParkStatsSoon)\n'
     '    if PaperDollFrame and PaperDollFrame.HookScript then PaperDollFrame:HookScript("OnShow", ForeverParkStatsSoon) end\n'
     '    if PaperDollFrame_UpdateStats then hooksecurefunc("PaperDollFrame_UpdateStats", ForeverParkStats) end\n'),
    # 8c. Forever's sheet is 631 wide (Retail: 540) and parents the sidebar
    #     tabs to CharacterFrame instead of the right inset EUI parks. Park the
    #     tabs too, let EUI's side panel use the extra width, and centre the
    #     title over the equipment half instead of under the panel divider.
    ("EllesmereUIBlizzardSkin\\EllesmereUIBlizzardSkin_CharacterSheet.lua",
     "                f:SetAlpha(0)\n            end\n        end\n    end\n    local function ForeverParkStatsSoon()",
     "                f:SetAlpha(0)\n            end\n        end\n"
     "        local tabs = _G.PaperDollSidebarTabs\n"
     "        if tabs and not tabs:IsForbidden() then\n"
     "            tabs:ClearAllPoints()\n"
     '            tabs:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -10000)\n'
     "            tabs:SetAlpha(0)\n"
     "        end\n"
     "        local w = frame:GetWidth() or 0\n"
     "        for _, pn in ipairs({ \"EUI_CharSheet_StatsPanel\", \"EUI_CharSheet_TitlesPanel\", \"EUI_CharSheet_EquipPanel\" }) do\n"
     "            local panel = _G[pn]\n"
     "            if panel and w > 560 then panel:SetWidth(w - 345 - 12) end\n"
     "        end\n"
     "        if CharacterFrameTitleText and w > 560 then\n"
     "            CharacterFrameTitleText:ClearAllPoints()\n"
     '            CharacterFrameTitleText:SetPoint("TOP", frame, "TOPLEFT", 147, -6)\n'
     "        end\n"
     "    end\n    local function ForeverParkStatsSoon()"),
    # 8d. Forever adds a right-pane host (carries the gold vertical divider)
    #     and a collapse-arrow toggle for it. Neither exists on Retail; fade both.
    ("EllesmereUIBlizzardSkin\\EllesmereUIBlizzardSkin_CharacterSheet.lua",
     "        local tabs = _G.PaperDollSidebarTabs\n",
     "        local host = _G.CharacterFrameRightPaneHost\n"
     "        if host and not host:IsForbidden() then host:SetAlpha(0) end\n"
     "        local tog = _G.CharacterFrameRightPaneToggleButton\n"
     "        if tog and not tog:IsForbidden() then tog:SetAlpha(0) tog:EnableMouse(false) end\n"
     "        local tabs = _G.PaperDollSidebarTabs\n"),
    # 8e. Tertiary stats (leech/avoidance/speed) and crests do not exist on
    #     Forever. Force those sections off regardless of imported settings.
    ("EllesmereUIBlizzardSkin\\EllesmereUIBlizzardSkin_CharacterSheet.lua",
     "        for k, v in pairs(defaults) do\n            if EllesmereUIDB[k] == nil then\n                EllesmereUIDB[k] = v\n            end\n        end\n",
     "        for k, v in pairs(defaults) do\n            if EllesmereUIDB[k] == nil then\n                EllesmereUIDB[k] = v\n            end\n        end\n"
     "        EllesmereUIDB.showStatCategory_Tertiary = false -- " + TAG + ": stat does not exist on Forever\n"
     "        EllesmereUIDB.showStatCategory_Crests = false -- " + TAG + "\n"),
    # 8f. PvP section: honor levels and conquest are Retail systems. One line
    #     that finds the Honor currency by name (ID may differ from Retail's 1792).
    ("EllesmereUIBlizzardSkin\\EllesmereUIBlizzardSkin_CharacterSheet.lua",
     '                    {\n                        name = "Honor Level",\n                        format = "%s",\n                        func = function()\n                            return tostring(UnitHonorLevel and UnitHonorLevel("player") or 0)\n                        end,\n                    },\n                    {\n                        name = "Honor",\n                        format = "%s",\n                        func = function()\n                            local cur = (UnitHonor and UnitHonor("player")) or 0\n                            local max = (UnitHonorMax and UnitHonorMax("player")) or 0\n                            return BreakUpLargeNumbers(cur) .. "/" .. BreakUpLargeNumbers(max)\n                        end,\n                    },\n                    {\n                        name = "Conquest",\n                        format = "%d",\n                        currencyID = 1602,\n                        func = function()\n                            if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then\n                                local info = C_CurrencyInfo.GetCurrencyInfo(1602)\n                                return (info and info.quantity) or 0\n                            end\n                            return 0\n                        end,\n                    },\n',
     '                    { -- FOREVER-BETA: no honor levels or conquest here; show the Honor currency by name\n                        name = "Honor",\n                        format = "%s",\n                        func = function()\n                            local ok, txt = pcall(function()\n                                if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then\n                                    for i = 1, C_CurrencyInfo.GetCurrencyListSize() do\n                                        local info = C_CurrencyInfo.GetCurrencyListInfo(i)\n                                        if info and not info.isHeader and info.name == HONOR then\n                                            return BreakUpLargeNumbers(info.quantity or 0)\n                                        end\n                                    end\n                                end\n                                local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(1792)\n                                return BreakUpLargeNumbers(info and info.quantity or 0)\n                            end)\n                            return ok and txt or "0"\n                        end,\n                    },\n'),
    # 8g. The defaults stamp in 8e listens for EllesmereUI's ADDON_LOADED, which
    #     has already fired before this module loads, so gate the two sections
    #     where visibility is decided instead.
    ("EllesmereUIBlizzardSkin\\EllesmereUIBlizzardSkin_CharacterSheet.lua",
     "            local shouldShow = not (EllesmereUIDB and EllesmereUIDB[settingKey] == false)\n",
     "            local shouldShow = not (EllesmereUIDB and EllesmereUIDB[settingKey] == false)\n"
     '            if settingKey == "showStatCategory_Tertiary" or settingKey == "showStatCategory_Crests" then shouldShow = false end -- ' + TAG + "\n"),
    # 8h. Forever's side tabs open SkillsFrame, PVPRankFrame and StatisticsFrame,
    #     which EUI does not know, so its character-tab overlays (model bg,
    #     stats panel, slots) stayed up and covered those lists. Hook them like
    #     Reputation/Currency, and count them in the initial tab check.
    ("EllesmereUIBlizzardSkin\\EllesmereUIBlizzardSkin_CharacterSheet.lua",
     "    _hookPaneOnShow(_G.TokenFrame,      false)\n",
     "    _hookPaneOnShow(_G.TokenFrame,      false)\n"
     "    _hookPaneOnShow(_G.SkillsFrame,     false) -- " + TAG + "\n"
     "    _hookPaneOnShow(_G.PVPRankFrame,    false) -- " + TAG + "\n"
     "    _hookPaneOnShow(_G.StatisticsFrame, false) -- " + TAG + "\n"),
    ("EllesmereUIBlizzardSkin\\EllesmereUIBlizzardSkin_CharacterSheet.lua",
     "    local isCharTab = not (_G.ReputationFrame and _G.ReputationFrame:IsShown())\n"
     "        and not (_G.TokenFrame and _G.TokenFrame:IsShown())\n",
     "    local isCharTab = not (_G.ReputationFrame and _G.ReputationFrame:IsShown())\n"
     "        and not (_G.TokenFrame and _G.TokenFrame:IsShown())\n"
     "        and not (_G.SkillsFrame and _G.SkillsFrame:IsShown()) -- " + TAG + "\n"
     "        and not (_G.PVPRankFrame and _G.PVPRankFrame:IsShown()) -- " + TAG + "\n"
     "        and not (_G.StatisticsFrame and _G.StatisticsFrame:IsShown()) -- " + TAG + "\n"),
    # 8i. The side-tab panes sit at frame level 1-5 under an EUI child of
    #     CharacterFrame at level 7, so their rows are clickable but invisible.
    #     Lift each pane above it whenever it shows.
    ("EllesmereUIBlizzardSkin\\EllesmereUIBlizzardSkin_CharacterSheet.lua",
     "    _hookPaneOnShow(_G.StatisticsFrame, false) -- " + TAG + "\n",
     "    _hookPaneOnShow(_G.StatisticsFrame, false) -- " + TAG + "\n"
     "    for _, pn in ipairs({ \"SkillsFrame\", \"PVPRankFrame\", \"StatisticsFrame\", \"TokenFrame\", \"ReputationFrame\" }) do -- " + TAG + ": lift side panes above EUI's sheet art\n"
     "        local pane = _G[pn]\n"
     "        if pane and not pane:IsForbidden() then\n"
     "            -- the pane itself is useParentLevel (pinned to CharacterFrame), so lift its children\n"
     "            local function Lift()\n"
     "                for i = 1, select(\"#\", pane:GetChildren()) do\n"
     "                    local c = select(i, pane:GetChildren())\n"
     "                    if c and c.GetFrameLevel and not c:IsForbidden() and c:GetFrameLevel() < 20 then c:SetFrameLevel(20 + c:GetFrameLevel()) end\n"
     "                end\n"
     "            end\n"
     "            Lift()\n"
     "            pane:HookScript(\"OnShow\", Lift)\n"
     "        end\n"
     "    end\n"),
    # 9. Tab skinner blanks every texture on a tab. Forever's spellbook
    #    category tabs are icon-only (TabSystem AddIconTab: .Icon + .IconMask),
    #    so they came up as empty squares. Leave those two alone.
    ("EllesmereUIBlizzardSkin\\EllesmereUIBlizzardSkin_WindowEngine.lua",
     '        if r and r:IsObjectType("Texture") then\n            r:SetTexture("")',
     '        if r and r:IsObjectType("Texture") and r ~= tab.Icon and r ~= tab.IconMask then -- ' + TAG
     + ': keep icon tabs\n            r:SetTexture("")'),
    ("BugSack\\sack.lua", TAB_OLD.format(name="BugSackTabAll"), TAB_NEW.format(name="BugSackTabAll")),
    ("BugSack\\sack.lua", TAB_OLD.format(name="BugSackTabSession"), TAB_NEW.format(name="BugSackTabSession")),
    ("BugSack\\sack.lua", TAB_OLD.format(name="BugSackTabLast"), TAB_NEW.format(name="BugSackTabLast")),
]


# Regex patches: (file, pattern, replacement, flags). Applied with re.subn.
REGEX_PATCHES = [
    # 7. Character sheet: Forever's paper doll has no per-slot wrapper frames
    #    (CharacterHeadSlotFrame etc.), so hide them only where they exist.
    ("EllesmereUIBlizzardSkin\\EllesmereUIBlizzardSkin_CharacterSheet.lua",
     r"^(\s*)_G\.(Character\w+SlotFrame):Hide\(\)\s*$",
     r"\1if _G.\2 then _G.\2:Hide() end -- " + TAG,
     re.M),
    # 8. Character sheet: weapon slots on Forever have fewer texture regions
    #    than Retail's 17, so select(16/17, ...) comes back nil.
    ("EllesmereUIBlizzardSkin\\EllesmereUIBlizzardSkin_CharacterSheet.lua",
     r"^(\s*)select\((1[67]), (_G\.Character\w+Slot):GetRegions\(\)\):SetTexCoord(\(.*\))\s*$",
     r"\1do local r = select(\2, \3:GetRegions()) if r then r:SetTexCoord\4 end end -- " + TAG,
     re.M),
    # 10. Forever brings back the ranged slot. Append it to every slot list so
    #     it gets the same icon crop, item-level and enchant labels as the rest.
    ("EllesmereUIBlizzardSkin\\EllesmereUIBlizzardSkin_CharacterSheet.lua",
     r'("CharacterMainHandSlot",\s*"CharacterSecondaryHandSlot")(?!, "CharacterRangedSlot")',
     r'\1, "CharacterRangedSlot"',
     0),
]


# Patches for the OFFICIAL Forever-aware EllesmereUI (9.2+). Applied only to that build.
NATIVE_PATCHES = [
    # 9.2.1 deliberately sets every one of its SavedVariables to nil at logout on Forever
    # ("nothing of ours reaches disk while the beta loses settings"). Sensible for a stock
    # client, fatal with sv_bridge.py: the bridge needs the file the client writes. Skip
    # only that logout wipe; the rest of FOREVER_SV_BUG (pickers off, login notice) stays.
    ("EllesmereUI\\EllesmereUI_Lite.lua",
     "if EllesmereUI.FOREVER_SV_BUG then\n    local STORES = {",
     "if false and EllesmereUI.FOREVER_SV_BUG then -- " + TAG
     + ": sv_bridge.py restores settings, so let them be written\n    local STORES = {"),
    # Resource Bars picks the power bar's resource from a Retail class table (hunter = Focus).
    # Forever hunters use mana, so the bar tracked a resource with a maximum of 0 and never
    # showed. On Forever ask the client what the player actually uses: right for every class
    # and for druid forms, with no table to keep in step.
    ("EllesmereUIResourceBars\\EllesmereUIResourceBars.lua",
     "local function GetPrimaryPowerType()\n    local _, classFile = UnitClass(\"player\")\n",
     "local function GetPrimaryPowerType()\n"
     "    if EllesmereUI.IS_FOREVER then -- " + TAG + ": Retail's class table is wrong here (hunters use mana)\n"
     "        local live = UnitPowerType(\"player\")\n"
     "        if type(live) == \"number\" then return live end\n"
     "    end\n"
     "    local _, classFile = UnitClass(\"player\")\n"),
]


def eui_is_native():
    """EllesmereUI 9.2+ supports Forever itself (its TOC lists 16001 and it ships its own
    Forever character sheet). Patching that build would fight its code, so leave it alone."""
    toc = os.path.join(ADDONS, "EllesmereUI", "EllesmereUI.toc")
    try:
        head = open(toc, encoding="utf-8", errors="replace").read(2000)
    except OSError:
        return False
    return any("16001" in line for line in head.splitlines() if line.startswith("## Interface"))


def apply_regex_patches():
    ok = True
    for rel, pat, repl, flags in REGEX_PATCHES:
        path = os.path.join(ADDONS, rel)
        if not os.path.exists(path):
            print(f"MISSING  {rel}")
            ok = False
            continue
        raw = open(path, "rb").read()
        crlf = b"\r\n" in raw
        text = raw.decode("utf-8", errors="surrogateescape").replace("\r\n", "\n")
        new, n = re.subn(pat, repl, text, flags=flags)
        if n == 0:
            print(f"{'already' if TAG in text else 'NO MATCH'}  {rel} (regex)")
            continue
        if crlf:
            new = new.replace("\n", "\r\n")
        open(path, "wb").write(new.encode("utf-8", errors="surrogateescape"))
        print(f"patched  {rel} ({n} regex sites)")
    return ok


def main():
    global PATCHES, REGEX_PATCHES
    if eui_is_native():
        print("EllesmereUI here supports Forever natively: skipping every EllesmereUI patch.")
        PATCHES = [p for p in PATCHES if not p[0].startswith("EllesmereUI")] + NATIVE_PATCHES
        REGEX_PATCHES = [p for p in REGEX_PATCHES if not p[0].startswith("EllesmereUI")]
    ok = apply_regex_patches()
    for rel, old, new in PATCHES:
        path = os.path.join(ADDONS, rel)
        if not os.path.exists(path):
            print(f"MISSING  {rel}")
            ok = False
            continue
        raw = open(path, "rb").read()
        crlf = b"\r\n" in raw
        text = raw.decode("utf-8", errors="surrogateescape").replace("\r\n", "\n")
        if new in text:
            print(f"already  {rel}")
            continue
        if old not in text:
            if TAG in text and rel.startswith("EllesmereUI\\EllesmereUI_FirstInstall"):
                print(f"already* {rel} (tagged, different wording)")
                continue
            print(f"NO MATCH {rel}  -- upstream text changed, patch needs review")
            ok = False
            continue
        # LibSpecialization raises the same line in two places; replace every copy.
        text = text.replace(old, new, -1 if "LibSpecialization" in rel else 1)
        if crlf:
            text = text.replace("\n", "\r\n")
        open(path, "wb").write(text.encode("utf-8", errors="surrogateescape"))
        print(f"patched  {rel}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
