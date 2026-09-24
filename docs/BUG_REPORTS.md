# WoW: Forever Beta — Bug Reports

Four posts for the Forever beta bug report / general discussion forum. Each is copy-pasteable on its own.

---

## Post 1: Secure handler snippets cannot compile: loadstring_untainted is nil

> **Fixed in build 1.60.1.70009 (2026-09-24). Kept for the record; do not post.** The cause was load order
> ([forever-bugs #74](https://github.com/ClassicWoWCommunity/forever-bugs/issues/74)): `Blizzard_EnvironmentCleanup` deletes
> `loadstring_untainted` and ran before the restricted environment captured it, because its dependency on that addon applied
> only to the Classic and Standard game types. The global is nil after load on every client, so do not test for it.

**Build:** 1.60.1.69893, 2026-09-17

**Steps:**
1. Load any addon that calls `SecureHandlerWrapScript`, or that sets an `_onstate-*` attribute on a frame created with `SecureHandlerStateTemplate`.
2. Trigger the wrap/state setup (addon load is usually enough).

**Expected:** The secure snippet compiles and the handler behaves as on Retail.

**Actual:** `Blizzard_RestrictedAddOnEnvironment/RestrictedExecution.lua:22` captures a local reference to `loadstring_untainted`; this build does not provide that global, so the captured value is nil. Line 79 calls it, throwing "attempt to call a nil value" — once at setup and again on every subsequent state change.

**Impact:** Every addon that uses `SecureHandlerWrapScript`, `_onstate-*` attributes, `initialConfigFunction`, or `RunAttribute` breaks on load or on first state change. This includes every major action bar addon (Bartender4, ElvUI, EllesmereUI, Dominos) — action bars, click-casting, and state drivers are non-functional. A minimal repro is any addon that does nothing more than call `SecureHandlerWrapScript` or set an `_onstate-*` attribute on a `SecureHandlerStateTemplate` frame.

— Thunderz

---

## Post 2: Addon SavedVariables are written on logout but never loaded at launch

**Build:** 1.60.1.69893, 2026-09-17

**Steps:**
1. Pre-seed an addon's SavedVariables file on disk before first launch (tested in all three candidate WTF folders).
2. Log in and read the pre-seeded global from the addon's main chunk.
3. Continue through `ADDON_LOADED`, `PLAYER_LOGIN`, `PLAYER_ENTERING_WORLD`, and `PLAYER_LOGOUT`, logging the global's value at each point.

**Expected:** The pre-seeded value is present in the global by `ADDON_LOADED` (or at latest by `PLAYER_LOGIN`), as on Retail.

**Actual:** The global is nil from the main chunk all the way through to `PLAYER_LOGOUT`, in every candidate WTF folder tested. The client writes the SavedVariables file correctly on logout, but never reads a SavedVariables file back in at launch.

**Impact:** Every addon starts from its hardcoded defaults on every launch — nothing persists across sessions. First-install setup wizards and one-time prompts repeat every login. This affects any addon that stores configuration, not just this test addon.

— Thunderz

---

## Post 3: Client stops delivering Lua errors after 100 per session

**Build:** 1.60.1.69893, 2026-09-17

**Steps:**
1. Trigger repeated Lua errors in a session (e.g. from an addon calling a function the client lacks, or from any other error source).
2. Reach 100 errors in the session without reloading the UI.
3. Trigger an additional, unrelated Lua error.

**Expected:** The new error is delivered to error handlers (BugGrabber-style addons, the default UI error frame) same as the first 100.

**Actual:** After 100 Lua errors in a session, the client stops delivering further errors to any handler and shows "Error reporting is now paused and will resume after reloading the UI."

**Impact:** If one addon (or one broken interaction) floods errors early in a session, it silently exhausts the 100-error budget and every subsequent real error — including ones unrelated to the flood, from other addons entirely — goes unreported until `/reload`. This makes diagnosing a second, unrelated problem in the same session impossible without first identifying and suppressing whatever is flooding.

— Thunderz

---

## Post 4: Player's own auras are unreadable to addons in combat

**Build:** 1.60.1.69893, 2026-09-17

**Steps:**
1. Enter combat, so that `C_Secrets.ShouldAurasBeSecret()` returns true.
2. From addon code, attempt to read any aura on the player unit (including the player's own buffs), or read the added/removed lists from a `UNIT_AURA` event payload.

**Expected:** Reads of the player's own buffs succeed even in combat, since they are not enemy or hidden information — this is the player's own state.

**Actual:** Every aura read throws "Auras cannot be accessed when secret while tainted." The `UNIT_AURA` event's added/removed lists also arrive as secret tables, so even the event payload cannot be inspected.

**Impact:** No addon can track buffs live in combat, including the player's own buffs. This makes buff-tracking addons impossible in combat rather than merely limited. Is it intended for the player's own buffs to be secret during combat, or should the player's own aura data be exempted from this restriction?

— Thunderz
