# ForeverCDM

A cooldown manager for **World of Warcraft: Forever** that needs no Blizzard Cooldown Manager data.

Blizzard's Cooldown Manager has no authored data for Forever classes yet, so every addon that skins
it shows nothing. ForeverCDM reads your spellbook and your auras directly and draws its own icon rows.

**Author:** Thunderz · **Interface:** 16001 (Forever beta)

## What it does
- Three icon rows: **Cooldowns**, **Utilities**, **Buffs**. Cooldown rows show Blizzard's swipe and
  charge counts; the Buffs row shows chosen auras while they are on you, with a remaining-time swipe.
- Display only. It never casts and never makes decisions, so it stays inside the current addon rules.
- Reads nothing it is not allowed to: secret timings are handed to the cooldown widget as duration
  objects, and in combat, where the client hides aura data from addons entirely, a buff that was up
  keeps its ticking timer, slightly dimmed, instead of vanishing.

## Use
Type `/fcdm` to open the settings window: your spellbook with a tick box per row for each spell,
Up/Down ordering per row, icon size and spacing, lock/unlock for dragging, and a box to add a spell
by name or ID. `/fcdm help` lists the slash commands for people who prefer them.

## Install
Drop the `ForeverCDM` folder into `World of Warcraft\_classic_beta_\Interface\AddOns\`.

## Development
Tests run under Lua 5.2+ with no game client:
```
lua tests/test_secret_duration.lua ForeverCDM.lua
lua tests/test_runtime.lua
lua tests/test_cast_tracking.lua
```
Releases are built by the GitHub Actions workflow on any `v*` tag. Findings about the Forever client
that shaped this addon live in [forever-addon-kit](https://github.com/Thunderz96/forever-addon-kit).

MIT.
