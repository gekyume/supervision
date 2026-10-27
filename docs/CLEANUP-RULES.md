# Cleanup rules (Oct 6, 2026)

This app locks a screen. A cleanup bug costs the user more than messy code does.
So the cleanup is conservative by design.

## Non-negotiables
1. **Behaviour stays identical.** Every rule, number, message and log event means the same thing
   after as before. If a change would alter what the user sees or when a lock happens, it is a
   feature change, not cleanup, and it needs the user's yes.
2. **Tests before refactors.** The decision logic gets unit tests first (`scripts/test.sh`).
   A refactor lands only once the tests pass before and after it.
3. **One concern per commit.** Small commits that can each be reverted alone.
4. **No new abstractions for their own sake.** Only extract when two places already do the same
   thing, or when a piece of logic can be tested in isolation only after extraction.
5. **The user's own data is sacred.** Never touch `~/Library/Application Support/Supervision/`
   from a cleanup. Config/capacity files stay loadable by the old keys (lenientLoad).
6. **Install on a calm moment.** Build and preview-render after every step; install once at the
   end, between breaks, never during a lock.

## What counts as a bug here
- Two code paths that decide the same thing differently (e.g. "in a call" computed three ways).
- State that can get stuck (a flag set and never cleared, like `awaitingCompletion` was).
- A promise shown to the user that the code can fail to keep (the eye heads-up).
- A once-a-day thing that isn't restored from the event log after a restart.
- A rename that silently drops a stored field.

## What counts as redundancy
- The same string literal (event kinds, file names, statements) in app and CLI.
- The same SQLite plumbing written out twice.
- Helpers that exist in `Shared` but are reimplemented in `Supervision` or `cli`.

## Order of work
1. Read everything. Write down findings before changing anything.
2. Add `Tests/` covering: block length, the symptom gate, eye-break timing, meeting suspension,
   phone unlock parsing, clean-slate triggers, night rule. Pure functions only; no AppKit.
3. Fix real bugs found in step 1, one commit each, with a test that would have caught it.
4. Remove redundancy, one commit each, tests green throughout.
5. Update CLAUDE.md where the structure changed. Nothing else in the docs changes.

## Findings (Oct 6, before any change)

### Bugs (stuck states, broken promises)
B1. Phone unlock during a lock sets `awaitingCompletion = true` while the typed question is up.
    If the user never types, the break can expire and the tick returns forever: the same
    class as the frozen-break bug of Sep 30. Needs its own flag that expires with the break.
B2. After a restart `eyeActiveSeconds` starts at 0, so the 20-20-20 clock is wrong for up to
    20 min (and a heads-up that was due can vanish). Restore it from samples like the block.
B3. `maybeReactToWorkout` forces the next break to be the long rest by setting
    `activeSinceLongRest`; a restart recomputes it from samples and loses that.
B4. Clean slate "morning" rule fires on *any* wake/unlock after 4 am if nothing ran yet today,
    e.g. a screen unlock at 11 am after a mid-morning rebuild: apps quit mid-day. The rule
    should mean "first time the computer is opened", i.e. no activity since 4 am.
B5. Three different definitions of "in a call": `meetingBlocker` (calendar ±10 min, Zoom,
    camera/windows with a deferral cap), the eye break's `inCall` (calendar now, Zoom,
    camera/windows) and CleanSlate (camera/windows, calendar ±5, **no Zoom check**).
B6. `supervisionctl adapt log` interpolates the day argument into SQL unescaped.

### Redundancy
R1. `statusText` (menu bar) and `pillText` compute the same state twice.
R2. `Calendar.current.startOfDay(for: Date())` written out 9× in Engine; `Day.today` exists.
R3. `h:mm a` clock formatter defined in Engine and in Card.
R4. The `adapt` table DDL appears 3× (Store ×2, CLI ×1); Store re-creates it on every read.
R5. `todayLoad()` (≈27 SQLite queries) runs 3–5× per 5-s tick and every 10 s for the menu.
R6. CLI `logEvent`/`query` duplicate Store's SQLite plumbing (accepted: different process,
    different process lifespan; only the DDL and event-kind strings are shared).

### Not changed on purpose
- CLI `status` counts "on the computer" from samples only; the app adds calendar meetings.
  Different process, hourly `day_load` would be stale. Documented instead.
- Tracker and Engine both use `idle > 60`: same meaning, both intentional.

## Done (Oct 6)
- Rules extracted to `Sources/Shared/Rules.swift`, 66 checks in `Tests/main.swift`, `scripts/test.sh`.
- B1–B6 fixed, one commit each (B2+B3 together: same function). R1–R5 done. R6 left as is.
- One behaviour change beyond bug fixes, on purpose: the clean slate now also treats a Zoom call
  as "not away" (B5 gave it the shared definition). Everything else decides exactly as before.
