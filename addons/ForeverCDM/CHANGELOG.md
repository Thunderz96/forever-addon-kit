# Changelog

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
