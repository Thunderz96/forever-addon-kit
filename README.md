# forever-addon-kit

Tools, findings, and three small addons for developing on the **World of Warcraft: Forever** beta
(build 1.60.1.69893, opened 2026-09-17). Everything here was measured against the live client,
not inferred from patch notes.

**Author:** Thunderz · **Status:** first-week snapshot, last updated 2026-09-18, expect Blizzard to fix several of the things below.

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
| **Secure snippets cannot compile** (Blizzard bug) | `Blizzard_RestrictedAddOnEnvironment/RestrictedExecution.lua:22` captures `loadstring_untainted`, which this client does not provide. Every `WrapScript`, `_onstate-*`, `initialConfigFunction`, `RunAttribute` throws "attempt to call a nil value". | All action-bar addons, click-casting, and state drivers break. `tools/guard_secure_snippets.py` makes those sites no-ops so the rest of an addon survives. Bar addons that re-anchor Blizzard's own buttons instead of creating secure ones keep drag-and-drop, because Blizzard's handlers are already compiled (approach used by classicuiforever; not tested here). |
| **Saved variables are never loaded** (Blizzard bug) | The client writes `SavedVariables` on exit and never reads them back. Proven with a pre-seeded file: the global was nil from main chunk to logout, in every candidate WTF folder. | Every addon starts from defaults each launch. `ForeverCompat` + `tools/sv_bridge.py` work around it by running the saved files as addon code. From inside the client, measured 2026-09-18: CVars registered with `C_CVar.RegisterCVar` survive `/reload` but never reach disk, even after a clean logout (`config-cache.wtf` holds only Blizzard's own CVars), so a CVar mirror restores nothing after a restart. A macro made with `CreateMacro` does survive a cold start. `ForeverCDM` keeps its settings in an opt-in general macro whose body is a slash command. Also: "Exit Now" skips writing the account-level `config-cache.wtf`; a normal logout writes it. |
| **`ReloadUI()` is protected** | Addon "Reload UI" buttons are blocked. | Type `/reload`. |
| **Client error cap** | After 100 Lua errors in a session the client stops delivering them to any handler ("Error reporting is now paused"). | Kill error floods first or you will never see the real error. |
| **In combat, secret auras are locked** | While `C_Secrets.ShouldAurasBeSecret()` is true, reading a secret aura from addon code throws, including your own buffs, and the `UNIT_AURA` payload's added/removed lists arrive as secret tables. Secrecy is per spell: `C_Secrets.GetSpellAuraSecrecy(id)` returns `Enum.SecrecyLevel` (NeverSecret / AlwaysSecret / ContextuallySecret) and `ShouldSpellAuraBeSecret(id)` answers for right now. | Ask per spell, not globally. For a secret buff, hand the widget a duration object before combat; it keeps ticking. For a buff you cast yourself, your own `UNIT_SPELLCAST_SUCCEEDED` stays readable: time it from that plus a duration learned out of combat. See `ForeverCDM`. |
| **Secret-value toolbox** | Beyond `issecretvalue` / `issecrettable` the client ships `canaccessvalue`, `canaccesssecrets`, `hasanysecretvalues`, `scrub`, `scrubsecretvalues`, `secretwrap`, `dropsecretaccess`. `C_Secrets` has 27 predicates (cooldowns, unit stats, threat, power, totems, spell casts). | Check before you branch. Other authors report `tostring()` of a secret returns a secret string, so test before and after converting. |
| **Built-in swing timer** | Events `PLAYER_SWING(swingDuration, swingType)` and `PLAYER_SWING_RANGE_UPDATE(swingType, isInRange, checksRange)` with `Enum.PlayerSwingType` (MainHand 0, OffHand 1, Ranged 2); `C_SwingTimer.IsTargetWithinSwingRange(type)`. | A swing timer needs no combat log. |
| **Secret timings and the Cooldown widget** | Tainted code may not pass secret numbers to `Cooldown:SetCooldown`. The sanctioned path is `C_Spell.GetSpellCooldownDuration(id)` / `C_UnitAuras.GetAuraDuration(unit, instanceID)` → `LuaDurationObject` → `Cooldown:SetCooldownFromDurationObject(obj)`. Never `or`/compare a possibly-secret value; even a boolean test throws. | See `ForeverCDM`. |
| **Blizzard's Cooldown Manager has no Forever data** | Every `C_CooldownViewer` category is empty for Forever specs, even with unlearned spells shown. | Anything that skins the CDM shows nothing. `ForeverCDM` reads the spellbook instead. |
| **Beta game rules** | `DisableCampsites=1`, `TransmogEnabled=0`, `EncounterJournalDisabled=1`. | Transmog cannot be researched yet. Camping can, despite the rule's name: players are placing campfires in the beta (Cooking's Camping recipe makes a Basic Campfire Kit; see smore-skills below). What that rule actually gates is unknown. |

### Corroboration (checked 2026-09-18)
- Retail API on interface 16001, Classic globals missing: matches what other day-one porting efforts found
  ([guildos #7](https://github.com/danielcosta42/guildos/issues/7), [#9](https://github.com/danielcosta42/guildos/issues/9)).
  Blizzard said as much in the WoW UI Discord before the beta
  ([Icy Veins, 09-15](https://www.icy-veins.com/wow-forever/news/addons-in-wow-forever-blizzard-devs-just-addressed-the-big-question/)).
- Missing `loadstring_untainted`: independently reported with the identical error and confirmed absent on Retail 12.1
  ([GSE #2110](https://github.com/TimothyLuke/GSE-Advanced-Macro-Compiler/issues/2110)).
- **Saved variables never loaded: now confirmed by others.** An EU forum thread from 09-18 reports the same cold-start
  behaviour and a second player confirms it
  ([thread](https://eu.forums.blizzard.com/en/wow/t/wow-forever-game-not-save-any-addons-settings/629470), no Blizzard reply yet).
  [forever-addon-dev](https://github.com/imperial64/forever-addon-dev) measured it independently
  ("writes SavedVariables and never reads them back") and landed on the same workaround: run the data as addon code.
- **Empty Cooldown Manager: acknowledged by Blizzard.** The
  [known-issues post](https://us.forums.blizzard.com/en/wow/t/wow-forever-beta-known-issues-september-17/2352687),
  updated 09-18, now says the Cooldown Manager is a work in progress and varies by class.
- The 100-error cap and the in-combat aura lockdown still have no other public report. Reproduction steps are in
  `docs/BUG_REPORTS.md`; the aura lockdown matches the Midnight 12.x restriction, so it is likely intended.
- No addon site (CurseForge, Wago, WoWInterface) has a Forever game flavour yet; "Forever" in listing names is author-chosen.
  The only reliable packaging signal other authors use is a separate `_Camelot.toc`.

### Related work by others
Day-two survey, 2026-09-18. Read for technique, not vendored; check each licence before reusing code.
- [BetterBlizzFrames](https://github.com/Bodify/BetterBlizzFrames): `forever/` module tree; where the per-spell aura secrecy check was seen.
- [SealTimersForever](https://github.com/Pirson-s-Addons/SealTimersForever) (MIT): follows a self-cast buff by cast event plus learned duration.
- [ForeverSwingTimer](https://github.com/RevoltLive85/ForeverSwingTimer): uses the `PLAYER_SWING` events.
- [classicuiforever](https://github.com/wowaddonmaker/classicuiforever): Classic-look bars built by re-anchoring Blizzard's buttons.
- [forever-addon-dev](https://github.com/imperial64/forever-addon-dev): in-game API dump with signatures plus a restrictions catalogue.
  [hated-wow-mcp](https://github.com/RdyGaming/hated-wow-mcp): MCP server over the `forever` UI source.
- [smore-skills](https://github.com/Henrik8210/smore-skills): campsite finder with live beta notes on camping items and rules.
- [forever-quest-markers](https://github.com/TylerAkins/forever-quest-markers) (GPL-3.0): quest DB built from
  [AllTheThings](https://github.com/ATTWoWAddon/AllTheThings)' Forever data, the best structured Forever dataset found so far.
- [guildos](https://github.com/danielcosta42/guildos) (client probe, tooltip shim), [WickCore](https://github.com/Wicksmods/WickCore)
  (platform library, `Enum.AddOnRestrictionType` wrapper), [BetterBags](https://github.com/Cidan/BetterBags) (notes that Forever
  enumerates bank tabs but has no Warbank).

`data/forever_api.json` is the captured API surface: 6,045 global functions, 11,417 named frames,
269 namespaces with their functions. `tools/api_scan.py` diffs any addon against it.

## Addons

### ForeverCDM
Canonical source and releases: [Thunderz96/ForeverCDM](https://github.com/Thunderz96/ForeverCDM) (the copy here is a snapshot).
A cooldown manager that needs no Blizzard CDM data. Three icon rows (cooldowns, utilities, buffs)
read straight from the spellbook and `C_UnitAuras`. `/fcdm` opens a config window with a spellbook
list, tick boxes per row, ordering, size and spacing. Display only. Tests in `tests/` run with Lua 5.2+ (tested on 5.4):

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
the diagnostic commands used for the findings above (`/fb bugs`, `/fb frame`, `/fb mouse`, `/fb target`, `/fb cdm`, `/fb help`). `/fb zonequests` and `/fb sweep` make the client ask the server about quests you have not played, which is the only way their records reach the WDB cache on this client.

### FBSVTest
The small test addon that proved the saved-variables bug: it logs a pre-seeded global at every lifecycle
point from main chunk to logout. Kept for reproduction.

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
| `questie_overlay.py` | Feed Questie the Forever quests it lacks, from ForeverBeacon's harvest plus a hand-edited CSV. Generates records in the shape Questie used for Season of Discovery, patches in the injection call, and hashes the overlay into Questie's version string so its database recompiles when your data changes. Needs Questie's `feature/forever` branch installed. |
| `wdb_zone_report.py` | List the quests that are new to Forever, grouped by zone, from archived `questcache.wdb` snapshots (fill the cache with ForeverBeacon's `/fb sweep`). Finds the level and zone fields by testing every offset against Questie's Classic database and refuses to run if they do not match. |

The tools find the kit's own files (`data/forever_api.json`, `addons/ForeverCompat`) relative to
themselves. What you must edit is the WoW install path at the top of each script, and the
`<RETAIL_ACCOUNT>` / `<BETA_ACCOUNT>` placeholders, which are your WTF account folder names.
`luac` is optional (used to validate saved files before copying); adjust its path in `sv_bridge.py`.

## What is deliberately not here
Patched copies of third-party addons (run the patchers on your own copy), personal settings seeds,
and harvested data.

## License
MIT. Author field is Thunderz.
