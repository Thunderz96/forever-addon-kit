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
]


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
