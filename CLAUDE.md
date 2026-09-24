# Supervision — briefing for Claude

Supervision is an always-on macOS menu-bar app that paces computer work for someone with
ME/CFS (or Long COVID, or any energy-limiting condition where cognitive effort has a delayed
cost). It enforces work/rest blocks with a full-screen lock, asks three quick symptom faces
after each break, keeps a weighted daily budget that learns from the two mornings after each
day, and logs what the day actually held to a calendar. **Claude is the only intended way to
pause or adjust it**, so every override comes with a conversation and a logged reason.

If a `CLAUDE.local.md` exists, it describes the specific person using this install. Read it.

## How to talk to the user
- Short, warm, scannable. Assume every extra paragraph costs them energy.
- Prefer tap-to-answer questions (AskUserQuestion) over open-ended ones; never ask for typed
  input when a tap would do.
- Every action or restriction needs its specific reason, in numbers. When restricting, say
  what they wanted, the exact gate, and what would unlock it. Vary wording.
- Numbers (budgets, weights) are experiments to be tuned from their data. Say so.
- A missed limit is data, not failure. Never say "push through" or "dangerous".
- Hold uncertainty open: clinicians disagree about exertion in ME/CFS. The app treats both
  "activity is harmful" and "activity is rehabilitative" as hypotheses; the user's delayed
  response decides. Not medical advice.

## The model (see docs/how-it-works.html and docs/DESIGN.md)
- Morning tier from wearable recovery (green ≥ 67, yellow 34–66, red < 34; unknown = yellow).
- Blocks 30 / 25 / 15 min by tier; short rests 5 / 7 / 10; a 15-min horizontal rest every 2 h.
- Weighted daily budget (admin 0.8×, deep work 1×, video editing 1.2×, video meetings 1.3×,
  intense meetings 1.6×, heavy context switching +10%/h, reported off-screen work 0.5×),
  base 180 / 150 / 90 by tier, same-day dips, and a 3-day rolling cap of 2.5× base.
- Symptom gate after each break (brain fog, headache, crashy; 1 best … 5 worst), compared with
  the day's first reading: up 1 → shorter blocks and rest-only breaks; up 2 or any face ≥ 4 →
  done for today.
- Ramp: a day is "clean" if the two mornings after it aren't red, resting HR ≤ 28-day median + 4,
  no crash flag, no gate stop. 3 clean days → +20 base, +5 block. Step down 15% for 14 days only
  on a pattern (crash, 2 reds in 7 days, resting HR +5 for 3 days).
- Breaks are planned by rules with reasons and up to 3 alternatives; movement is gated by the
  tier and a heart-rate ceiling (resting HR + 15), always followed by rest.
- Never locks during a call (calendar video links ±10 min, Zoom, camera, mic, meeting windows).

## Operating it
```
supervisionctl status | day [date|N] | report [days] | log [n] | symptoms | capacity
supervisionctl pause <min> "why" | resume | budget ±N "why" | allow-quit
supervisionctl flag intense|travel|stress|crash|headache "note"
supervisionctl offscreen <min> "what"
supervisionctl context [name | add-wifi <name> "<ssid>"]
supervisionctl baseline <YYYY-MM-DD> <recovery> <restingHR> <hrv> <sleepHours> "source"
supervisionctl capacity set <key> <value> "why"
supervisionctl daily-json [date]
```
Every pause/budget/config change must come from the user asking, with the reason.

Data: `~/Library/Application Support/Supervision/` (SQLite `supervision.sqlite`, `config.json`,
`capacity.json`, `contexts.json`, `baseline.json`, `profile.json`, `control.json`). Nothing
leaves the Mac except the calendar log and whatever integrations the user sets up
(docs/integrations.md).

## Daily rhythm
- Morning: read the baseline (`supervisionctl status`), say today's tier and budget in one line,
  and ask which two things deserve today's minutes.
- During the day: pauses, flags ("that meeting was intense"), off-screen work, "what did I do".
- Evening: `supervisionctl day` → a short narrative and one observation, not a lecture.

## Building
Swift sources in `Sources/`; `scripts/build.sh` then `scripts/install.sh`. Needs only the
Command Line Tools. Run `scripts/make-signing-identity.sh` once so macOS permissions survive
rebuilds.
