# forever-addon-kit

Tools, findings, and three small addons for developing on the **World of Warcraft: Forever** beta
(build 1.60.1.69893, opened 2026-09-17). Everything here was measured against the live client,
not inferred from patch notes.

**Author:** Thunderz · **Status:** day-one snapshot, expect Blizzard to fix several of the things below.

## Findings in one page

| Finding | Detail | Consequence |
|---|---|---|
| **Interface number** | `16001` (build line 1.60.x). Product folder `_classic_beta_`, exe `WowB.exe`. | Put `16001` first in `## Interface`. |
| **It is the Retail client** | `WOW_PROJECT_ID == WOW_PROJECT_MAINLINE`. 269 `C_*` namespaces, Edit Mode, Cooldown Manager, the works. The old Classic globals are gone (`GetItemInfo`, `GetSpellInfo`, `UnitAura`, `GetTalentInfo`, `GetMerchantItemInfo`, `CombatLogGetCurrentEventInfo`…). | Port from your Retail code, not your Classic code. |
| **The version-check trap** | Almost every Retail addon tests `select(4, GetBuildInfo()) >= 100000` to mean "modern client". Forever answers `16001`, so they load Classic code paths or refuse to start. | `tools/port_to_beta.py` rewrites that idiom to `120100` in the copy. |
| **Talents and Legacy trees** | Both run on Retail's trait system (`C_Traits`). The Legacy panel is `ToggleLegacySystemUI`, unlocks at level 25, has a seasonal point cap. | Read trees with `C_Traits`; see `ForeverBeacon`'s trait walker. |
| **No Retail specializations** | `GetSpecialization` and friends are absent; spec IDs are new (paladin = 1486). | Spec-keyed addon logic misbehaves. `ForeverCompat` bridges the calls. |
| **Midnight restrictions carried over** | `C_Secrets`, `C_RestrictedActions`, restricted combat log, built-in `C_DamageMeter`. Creature health and damage numbers are secret. | Threat meters and combat-decision addons cannot work. Reference and tracker addons are fine. |
| **Registering an unknown event throws** | e.g. `LEARNED_SPELL_IN_TAB` does not exist; `RegisterEvent` errors and aborts the file. | Wrap registration in `pcall`. |
| **Secure snippets cannot compile** (Blizzard bug) | `Blizzard_RestrictedAddOnEnvironment/RestrictedExecution.lua:22` captures `loadstring_untainted`, which this client does not provide. Every `WrapScript`, `_onstate-*`, `initialConfigFunction`, `RunAttribute` throws "attempt to call a nil value". | All action-bar addons, click-casting, and state drivers break. `tools/guard_secure_snippets.py` makes those sites no-ops so the rest of an addon survives. |
| **Saved variables are never loaded** (Blizzard bug) | The client writes `SavedVariables` on exit and never reads them back. Proven with a pre-seeded file: the global was nil from main chunk to logout, in every candidate WTF folder. | Every addon starts from defaults each launch. `ForeverCompat` + `tools/sv_bridge.py` work around it by running the saved files as addon code. |
| **`ReloadUI()` is protected** | Addon "Reload UI" buttons are blocked. | Type `/reload`. |
| **Client error cap** | After 100 Lua errors in a session the client stops delivering them to any handler ("Error reporting is now paused"). | Kill error floods first or you will never see the real error. |
| **In combat, auras are fully locked** | While `C_Secrets.ShouldAurasBeSecret()` is true, every aura read from addon code throws, including your own buffs, and the `UNIT_AURA` payload's added/removed lists arrive as secret tables. | No addon can track buffs live in combat. Hand the widget a duration object before combat; it keeps ticking. |
| **Secret timings and the Cooldown widget** | Tainted code may not pass secret numbers to `Cooldown:SetCooldown`. The sanctioned path is `C_Spell.GetSpellCooldownDuration(id)` / `C_UnitAuras.GetAuraDuration(unit, instanceID)` → `LuaDurationObject` → `Cooldown:SetCooldownFromDurationObject(obj)`. Never `or`/compare a possibly-secret value; even a boolean test throws. | See `ForeverCDM`. |
| **Blizzard's Cooldown Manager has no Forever data** | Every `C_CooldownViewer` category is empty for Forever specs, even with unlearned spells shown. | Anything that skins the CDM shows nothing. `ForeverCDM` reads the spellbook instead. |
| **Beta game rules** | `DisableCampsites=1`, `TransmogEnabled=0`, `EncounterJournalDisabled=1`. | Camping and transmog cannot be researched yet. |

`data/forever_api.json` is the captured API surface: 6,046 global functions, 11,417 named frames,
269 namespaces with their functions. `tools/api_scan.py` diffs any addon against it.

## Addons

### ForeverCDM
A cooldown manager that needs no Blizzard CDM data. Three icon rows (cooldowns, utilities, buffs)
read straight from the spellbook and `C_UnitAuras`. `/fcdm` opens a config window with a spellbook
list, tick boxes per row, ordering, size and spacing. Display only. Tests in `tests/` run with plain Lua:

```
lua tests/test_secret_duration.lua ForeverCDM.lua
lua tests/test_runtime.lua
```

### ForeverCompat
Loads first (`!!` prefix) and does three jobs:
1. `Compat.lua` defines the deprecated Retail globals the client lacks, each forwarding to its `C_*`
   equivalent and only when nil. Most Retail addons stop crashing with this alone.
2. `ActionPlace.lua`: `/place <spell>` while hovering a bar button, `/unplace`, `/swapslot`, `/slot`.
   Placing an action needs no secure snippet, so it works while dragging does not.
3. `seeds/`: saved-variables files run as addon code before the real addon loads, so its settings
   exist. `tools/sv_bridge.py` and `sv_watch.py` copy the client's saves back into the seeds.

### ForeverBeacon
A Wowhead-Looter-style harvester: API probe, event firehose, NPCs, vendors, trainers, gossip,
taxi, item and spell tooltips, loot, objects, spellbook, talents and Legacy trees, auras, quests
with positions. `tools/fb_extract.py` turns the SavedVariables payload into CSV/JSONL. Also carries
the diagnostic commands used for the findings above (`/fb bugs`, `/fb frame`, `/fb cdm`, `/fb help`).

### FBSVTest
The four-line test addon that proved the saved-variables bug. Kept for reproduction.

## Tools

| Tool | Does |
|---|---|
| `port_to_beta.py` | Copy a Retail addon into the beta: keep the Mainline TOC, add 16001, rewrite the build-check idiom. |
| `api_scan.py` / `api_scan_all.py` | Unguarded calls to functions, namespaces, and frames the client lacks; batch mode ranks a whole AddOns folder. |
| `eui_audit.py` | Per-module audit for secure-snippet sites, missing frames, unknown events, Retail-only systems. |
| `guard_secure_snippets.py` | Wrap every snippet site in `if loadstring_untainted then … end` (behaviour returns when Blizzard fixes the build). |
| `apply_eui_fixes.py` | Idempotent source patches for EllesmereUI and BugSack on this client. |
| `sv_bridge.py` / `sv_watch.py` | The settings workaround: seeds from saved files, sub-second watcher for `/reload`. |
| `sv_diff.py` | Structural diff of two SavedVariables files. |
| `read_bugs.py` | Print BugGrabber's errors from disk. |
| `fb_extract.py`, `Sync-ForeverBeacon.ps1` | ForeverBeacon extraction and scheduled archive. |

Paths at the top of each tool point at one Windows install; `<RETAIL_ACCOUNT>` and `<BETA_ACCOUNT>`
are your WTF account folder names. Edit before use.

## What is deliberately not here
Patched copies of third-party addons (run the patchers on your own copy), personal settings seeds,
and harvested data.

## License
MIT. Author field is Thunderz.
