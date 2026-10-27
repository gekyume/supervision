# Supervision — briefing for Claude

Supervision is an always-on macOS menu-bar app that paces computer work for someone with
ME/CFS (or Long COVID, or any energy-limiting condition where cognitive effort has a delayed
cost). It enforces work/rest blocks with a full-screen lock, asks five optional 1–10 symptom numbers
after each break, sizes each work block by how you're doing, caps computer time at 8 h a day, and logs what the day actually held to a calendar. **Claude is the only intended way to
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
- Pacing over quotas. First block 30 / 25 / 15 min by tier (5 min shorter on short sleep, travel
  or stress); every how-are-you card moves the next block: steady + overall ≥ 7 → +5, clear/head/
  not-crashing down 1 → −5, within 15–45. Breaks 5 / 7 / 10 min (stand, stretch, 20-20-20, plan);
  a 15-min horizontal rest every 2 h.
- One daily cap: 8 h of active computer time (meetings included). Kinds of work are still
  weighted in the logs (admin 0.8×, deep 1×, video 1.2×, meetings 1.3×, intense 1.6×) to learn
  what costs most, but only the cap locks.
- Symptom gate: after each break a top-right card asks overall, how's my head, clear (no brain
  fog), energy, not crashing (1 = really bad … 10 = best, all optional, non-blocking) plus a
  one-line note ("drank water"); the same card opens from the
  top-right corner any time. Only clear, head and not-crashing are gated (energy and overall
  are logged, never gated), each vs its first answer today: down 2 → shorter blocks and
  rest-only breaks; down 3 or anything ≤ 3 → a card recommends an hour off (the second time: stopping
  for the day). Numbers never lock on their own: "Keep working" (or no answer in 10 min) means
  shortest blocks and plain rest, logged as `gate_declined`, so honest answers cost nothing.
- Ramp: a day is "clean" if the two mornings after it aren't red, resting HR ≤ 28-day median + 4,
  no crash flag, no gate stop. 3 clean days → starting blocks +5. Blocks 5 min shorter for 14 days
  only on a pattern (crash, 2 reds in 7 days, resting HR +5 for 3 days).
- Breaks are planned by rules with reasons and up to 3 alternatives; movement is gated by the
  tier and a heart-rate ceiling (resting HR + 15), always followed by rest.
- ADaPT exercise track (Utah ADaPT protocol, separate from work pacing): a stage by body position,
  a heart-rate zone, 20 min, ≥ 3 days/week, ≤ 2 days off. Sessions come from Whoop workouts
  (`supervisionctl adapt log`). Step-ups (+5 bpm, then next stage after 3) are proposed at review,
  and only if the two mornings after the week's sessions look fine. `supervisionctl adapt` shows it.
- Clean slate: at 4 am (or the first wake after), and after 60 min away (no input with no call, meeting
  or video; a sleep that long; or a Supervision lock that long), every regular app gets a normal Quit and browser tabs (Comet,
  Chrome) are saved to `tabs/<date>-<browser>.txt` and closed, so the day doesn't start inside last night's task
  (`cleanSlateHour`, `cleanSlateKeep` in config.json).
- Phone unlock: an iPhone Shortcut posts "<min>|<reason>" (1–120) or "end" to a private ntfy.sh topic
  (phone.json); the Mac polls every 10 s, pauses, and logs it as an override with the reason.
- Status pill: hover near the top-right corner to see where you are ("🧠 Break in 12 min", paused,
  break, done); hidden otherwise; click it for the quick check.
- 20-20-20: every 20 min of focused time, a full-screen "look 20 feet away" that ends after 20 blinks
  (counted on-device by the camera; 20-s timer if no face is visible; max 60 s),
  with a small card 30 s before; skipping means typing a statement. Not during calls, not within 3 min of a regular break, not at night.
- App picker: after each break the apps you use appear faded on the lock screen; tap this block's
  apps. Others get a normal Quit, and one opened mid-block closes with a card offering to add it by
  typing a statement. Always allowed: Finder, `appGateAlways`. Never blocks while paused or in a call/meeting.
- Switch meter: app switches in the last 10 min show in the corner pill (🔀); 25+ brings one gentle card (your top ~7%; typical is 11),
  at most every 30 min, never in a call, never a lock. `switch_burst` and per-block `block_switches` are logged for reviews.
- Noticing: once a day (after the morning Whoop reading) Claude reads `supervisionctl digest` and the card
  shows one observation with its numbers and 👍 / 👎 (feedback feeds the next digest). The app also fetches
  Whoop itself each morning (every 30 min, 6 am–1 pm, while it's missing). `insight-context.txt` (private) says who it's for.
- App picker: Slack always on plus 3 free picks; a 4th needs a typed statement.
- Calm break screen: every break shows the breathing circle (5.5 s in / out) around the time; rest breaks add only one line,
  active ones their one how-to line; 🔔 Bell (soft tones each 5.5 s, eyes closed) and More (options, earn-a-minute, the numbers).
  No corner cluster or tagline on breaks. Redraws never happen while a question is up.
- Movement: each regular break asks the camera to see you stand and reach overhead for 15 s (seated reach on red
  days). The countdown runs from the start; the break can't end until it's seen, seeing it takes a minute off, and it
  gives up 3 min past the end (or at once with no camera). A running break survives app restarts (break.json).
- Avoidance call-out: unread badges on texts/email/to-do climbing +10 while none opened for 90 min and you worked elsewhere → one card (max 2/day): lie down 15 min, just one reply, or fine.
- Sync from the app: with `sheetSyncId` set, the app syncs the day to the user's sheet from 9:30 pm (yesterday's
  in the morning if missed) and does a morning backup (Whoop workouts → ADaPT, the coach's plan), using the Claude
  command-line tool's own sign-in. `supervisionctl sync` runs it now (a manual run doesn't count as the night's).
- Micro stretch: every 30 focused min (a clock regular breaks don't reset), a 10-s full-screen stand + reach (seated on
  red days), camera-checked with live coaching ("back up a bit", "come closer"), a heads-up 20 s before; done when
  seen, lets go after 90 s, skip by typing a statement; not near a regular break, an eye break, a call or at night.
- Exercise snacks: up to 3 regular breaks a day (10 am–5 pm, never two in a row, not on red days) hold one small counted
  exercise, rotating by place: lying (bridges; clamshells both sides; each then a timed sit-and-pause, POTS) or standing
  (kickbacks; side raises), with the iPhone as a Continuity Camera when it's near (else the Mac's
  camera). The break can't end until it's done (−2 min) or 5 min past; stop by typed statement. `supervisionctl workout` tries it.
- Places: Wi-Fi tells the app where you are; a new network brings one "Where are you?" card (remembered). Each place
  sets its workout (`workout` in contexts.json: lying / standing / none). Workouts can also be done on the phone page
  (docs/workout.html: camera + pose in the browser, result sent to the Mac's relay) and closed with "🤞 I promise I did it"
  (logged as promised; `workoutPromiseOn` removes it).
- Night: from 10 pm, 2 min of work then a 10-min break (no nudges, no cards); midnight to 6 am
  the computer is off, whatever's left of the cap.
- Never keeps you from a meeting: calendar events with a video link or other attendees (not declined)
  count; travel (flights, trains, flight numbers) and anything over 4 h don't (MeetingKind). Regular breaks are trimmed to end 5 min before the next meeting; any longer lock (hour off,
  cap, night) steps aside 5 min before and comes back after the meeting if time is left. Also never
  locks during a live call (Zoom, camera, meeting windows).

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
supervisionctl digest [days] | mark "<name>" <date> | compare ["<name>"] | eye | break <min> "why"
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

## Design
Every surface uses the brand (Sources/Supervision/Brand.swift): paper + dot grid, the wordmark
(Resources/wordmark.png), viewfinder brackets around countdowns, mono tags, ink capsule buttons; type is Geist + Geist Mono (Resources/Fonts, SIL OFL); breaks show a breathing circle (dot rings, 5.5 s in / 5.5 s out) around the countdown;
inverted from 8 pm to 7 am. `Supervision.app/Contents/MacOS/Supervision --previews <dir>` renders
every screen to PNG without showing a lock.

## Building
Swift sources in `Sources/`; `scripts/build.sh` then `scripts/install.sh`. The decisions (gate, block
length, 20-20-20, meeting trim/resume, phone message, clean-slate triggers) are pure functions in
`Sources/Shared/Rules.swift`; `scripts/test.sh` runs `Tests/main.swift` against them: run it before
every install, and change a rule and its test together. Needs only the
Command Line Tools. Run `scripts/make-signing-identity.sh` once so macOS permissions survive
rebuilds.
