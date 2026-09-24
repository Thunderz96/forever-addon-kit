# Changelog

## 0.7.1 (2026-09-21)
- **Debuffs applied before the pull now keep their timer in combat.** Hunter's Mark (and anything
  else you put on a mob before engaging) was readable out of combat, so the addon dropped its own
  estimate, then had nothing left once combat hid the aura. The real start time is kept per target
  instead.
- **Openers are tracked.** A debuff cast while the target's auras were still readable (the first
  Serpent Sting of a fight) was cleared before the aura had landed. A fresh cast now gets a second
  to land.
- `/fcdm probe <spell>` also reports what the addon can see on your target.

## 0.7.0 (2026-09-21)
- **Edit Mode support** (contributed by shuyu42, PR #1):
- Confirm row attachment/detachment in chat, list only visible anchor targets, and
  distinguish duplicate menu labels. Skip hidden or unreadable visibility results
  safely in both the anchor menu and snapping.
- Respect Edit Mode's Enable Snap setting: show alignment guides while dragging,
  snap nearby centres/edges on drop, and hold Shift to bypass. Existing frame
  anchors retain the corrected offset.
- Right-click a row handle in Edit Mode to anchor it to a Blizzard frame or another
  addon row. Preserve offsets while dragging, allow detaching, reject circular
  anchors, and restore frame targets through saved settings and the settings macro.
- Show draggable handles for all four rows in the game's Edit Mode, including empty
  and locked rows. Keep the normal lock preference and disable dragging in combat.
- Save dropped positions in UIParent coordinates and retain the existing settings
  macro support. Row positions remain shared across Blizzard layouts and save on drop.

## 0.6.0 (2026-09-20)
- **Debuffs bar.** A fourth row for your own debuffs on your current target: Serpent Sting,
  Hunter's Mark, Rend, Corruption... Tick the new DEBUFF box in the Spellbook card, or
  `/fcdm adddebuff Serpent Sting`. Any rank of the spell lights the icon.
- In combat, where the client hides auras from addons, the timer runs from your own cast and is
  remembered per target, so swapping back to a mob brings its timer back. A cast that misses or is
  resisted still starts the timer; the real aura replaces it whenever it can be read.
- If the addon cannot work out how long a debuff lasts, `/fcdm duration <spell> <seconds>` sets it.
- **Hide inactive auras** (Settings card, or `/fcdm hideinactive on`). Off, as before, a buff that is
  not up stays on its bar dimmed. On, buffs and debuffs only appear while they are up, so a proc
  shows when it happens, and the visible icons close the gaps. Unlocking the rows shows everything
  again so there is something to drag.
- Each icon in the Bars card has an **x** to remove it, so a spell added by a mistyped ID is easy to
  get rid of.

## 0.5.0 (2026-09-18)
- **Items on your bars.** Trinkets, potions, bandages, engineering gadgets: anything with a Use
  effect. The Spellbook card has a new Items group listing every usable item you are wearing or
  carrying, so there is nothing to look up. Items show their cooldown, their stack count, and dim
  when you have run out or unequipped them.
- You can also add one with `/fcdm add item:6948`, an item name, or a pasted item link.
- Items go on the Cooldowns or Utility bar. The Buffs bar watches auras, so item rows do not offer it.

## 0.4.0 (2026-09-18)
- **Your setup can now survive a game restart on the beta.** The Forever beta client saves addon
  settings and never loads them back, so every addon starts from defaults. Tick "Keep settings in
  a macro" (or `/fcdm mirror on`) and the addon keeps your setup in one general macro per
  character, which the client does bring back, and restores it when the saved settings come back
  empty. It is opt-in, so nobody gets a macro they did not ask for; if your settings were forgotten
  and the option is off, the addon tells you once. Clicking the macro is harmless. Once Blizzard
  fixes the client it simply stops being needed. `/fcdm mirror` shows its state.
  Measured first: CVars registered by an addon do not reach disk on this build, even after a clean
  logout, so that route was dropped.
- **Each bar has its own icon size and spacing.** Pick a bar in the Bars card and adjust it there.
  `/fcdm size buffs 30` sets one bar, `/fcdm size 40` sets them all.
- **Spell ranks are shown.** Forever lists every rank as its own spell, so the spellbook and bar
  lists now say "Rank 1", "Rank 2", in rank order.
- A buff ticked as one rank lights up when you cast another rank of the same spell.
- Auto-fill adds only the highest rank of each spell.

## 0.3.6 (2026-09-18)
- Settings window redrawn: solid background, three titled cards (Spellbook, Bar order, Settings),
  spells grouped under their spellbook tab, hover highlight, a scroll position thumb, and flat
  buttons and tick boxes drawn by the addon itself. No Blizzard templates are used any more, so UI
  suites that reskin those templates can no longer distort the window.
- Bar order shows each spell's icon, uses arrow buttons, and says how many icons the bar holds.
- Minimap button: left-click opens settings, right-click locks or unlocks the rows, drag to move it
  round the minimap. Hide it with the Settings tick box or `/fcdm minimap`.
- The addon has its own icon in the addon list, the window header and the minimap button.

## 0.3.5 (2026-09-18)
- Buffs you cast yourself are now followed through combat by your own cast event, which stays
  readable when auras do not. The timer uses a duration the addon measured out of combat, so a
  buff first applied mid-fight shows a real countdown instead of a "?". Other ranks of the same
  spell are matched by name. (Approach seen in Pirson's SealTimersForever.)
- Secrecy is checked per spell (`C_Secrets.ShouldSpellAuraBeSecret`) instead of globally. A buff
  the client never hides stays exact in combat. (API usage seen in Bodify's BetterBlizzFrames.)
- `/fcdm probe <spell>` prints the spell's base secrecy level and the learned duration.
- New regression test file for the above.

## 0.3.4 (2026-09-17)
- Aura lookup is protected: in combat the client throws on every aura read, which previously burned
  the client's 100-error cap.
- Secret tables are checked as well as secret values in the UNIT_AURA path.
- Version string comes from the TOC; utilities row default position and spacing limits unified.
- Spellbook tab names default to "?" when the client gives none.

## 0.3.3 (2026-09-17)
- A buff known before combat keeps its ticking timer through combat, slightly dimmed, instead of
  clearing. A "?" only appears for a buff first seen during combat.
- `/fcdm probe <spell>` and `/fcdm auradebug` diagnostics.

## 0.3.0 (2026-09-17)
- Utilities row, per-row Up/Down ordering, Clear bar, migration that keeps existing settings.
- Cooldowns with secret timings are drawn via duration objects (the sanctioned path on this client).
- Regression tests.

## 0.2.0 (2026-09-17)
- Settings window (`/fcdm`). Rows can be dragged while unlocked.

## 0.1.0 (2026-09-17)
- First version: cooldown and buff icon rows read from the spellbook and auras, slash commands.
