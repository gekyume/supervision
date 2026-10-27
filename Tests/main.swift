import Foundation

// Plain checks, no XCTest (the Command Line Tools don't ship it). `scripts/test.sh` runs this.
var passed = 0, failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("FAIL (line \(line)): \(what)") }
}
func section(_ name: String) { print("· \(name)") }

let cal = Calendar.current
func at(_ h: Int, _ m: Int = 0, day: Int = 15) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
}

// MARK: Tier
section("tier")
check(Tier.from(recovery: nil) == "unknown", "no reading → unknown")
check(Tier.from(recovery: 67) == "green" && Tier.from(recovery: 66) == "yellow", "green from 67")
check(Tier.from(recovery: 34) == "yellow" && Tier.from(recovery: 33) == "red", "red below 34")

// MARK: Day phases
section("day phases")
check(Rules.phase(hour: 3, nightStartHour: 22, morningHour: 6) == .off, "3 am is off")
check(Rules.phase(hour: 6, nightStartHour: 22, morningHour: 6) == .day, "6 am is a day")
check(Rules.phase(hour: 22, nightStartHour: 22, morningHour: 6) == .late, "10 pm is late")
check(Rules.nextMorning(after: at(23), morningHour: 6) == at(6, day: 16), "11 pm → tomorrow 6 am")
check(Rules.nextMorning(after: at(1), morningHour: 6) == at(6, day: 15), "1 am → today 6 am")

// MARK: Gate
section("symptom gate")
let keys = ["fog", "headache", "crashy"], labels = ["fog": "clear", "headache": "head", "crashy": "not crashing"]
func gate(_ now: [String: Int], first: [String: Int], softened: Bool = false, priorRests: Int = 0) -> GateOutcome {
    GateRule.evaluate(now: now, readings: [first, now], keys: keys, labels: labels, dropBy: 3, floor: 3, softenBy: 2,
                      softened: softened, priorRests: priorRests, stopsForDay: 2)
}
let morning = ["fog": 10, "headache": 10, "crashy": 10, "tired": 9, "overall": 10]
check(gate(["fog": 10, "headache": 9, "crashy": 10, "overall": 9], first: morning) == .adapt, "down 1 → just adapt the block")
check(gate(["tired": 3, "overall": 8], first: morning) == .adapt, "energy never gates (Sep 25 rule)")
check(gate(["fog": 8], first: morning) == .soften(drop: 2, moved: "clear 10→8"), "down 2 → soften")
check(gate(["fog": 8], first: morning, softened: true) == .adapt, "already softened: no second soften")
check(gate(["crashy": 7], first: morning) == .rest(trigger: "down 3 from this morning", moved: "not crashing 10→7"), "down 3 → an hour off (Oct 3 case)")
check(gate(["headache": 3], first: morning) == .rest(trigger: "head is at 3/10", moved: "head 10→3"), "at the floor → an hour off")
check(gate(["headache": 3], first: ["headache": 3]) == .rest(trigger: "head is at 3/10", moved: "no drop from this morning"), "floor counts even as the first answer")
if case .stop(_, _, let n) = gate(["crashy": 6], first: morning, priorRests: 1) { check(n == 2, "second trigger ends the day") } else { check(false, "second trigger should stop the day") }
check(gate([:], first: morning) == .adapt, "nothing answered → nothing gated")

// MARK: Block length
section("block length")
func adapt(_ before: Int, _ now: [String: Int], first: [String: Int] = morning, softened: Bool = false) -> Int? {
    BlockRule.adapt(before: before, now: now, readings: [first, now], keys: keys, step: 5, min: 15, max: 45, upOverall: 7, softened: softened)?.after
}
check(adapt(30, ["overall": 8]) == 35, "steady + overall 8 → +5")
check(adapt(30, ["overall": 6]) == nil, "overall 6 → no change")
check(adapt(30, ["fog": 9, "overall": 10]) == 25, "a gated dip wins over a good overall")
check(adapt(45, ["overall": 10]) == nil, "already at the max")
check(adapt(15, ["fog": 5]) == nil, "already at the min")
check(adapt(30, ["overall": 10], softened: true) == nil, "softened days don't grow")
check(adapt(30, ["tired": 2, "overall": 9]) == 35, "energy dip doesn't shorten")

// MARK: 20-20-20
section("eye breaks")
func eye(_ active: Double, nudged: Bool = false, remaining: Double = 900, nearNight: Bool = false, late: Bool = false, call: Bool = false) -> EyeAction {
    EyeRule.decide(active: active, due: 1200, notice: 30, nudged: nudged, blockRemaining: remaining, nearNight: nearNight, late: late, inCall: { call })
}
check(eye(600) == .nothing, "10 min in: nothing")
check(eye(1170) == .notice, "30 s before: heads-up")
check(eye(1170, nudged: true) == .nothing, "heads-up only once")
check(eye(1170, call: true) == .nothing, "no heads-up in a call (the Oct 6 bug)")
check(eye(1170, nearNight: true) == .nothing, "no heads-up just before 10 pm")
check(eye(1170, remaining: 200) == .nothing, "no heads-up when the break will cover it")
check(eye(1200, nudged: true) == .start, "at 20 min: start")
check(eye(1200, nudged: true, remaining: 100) == .coveredByBreak, "break < 3 min away covers it")
check(eye(1200, nudged: true, call: true) == .wait, "in a call: wait")
check(eye(1200, nudged: true, late: true) == .nothing, "not in the late-night cycle")
check(eye(1170, remaining: 209) == .nothing && eye(1200, nudged: true, remaining: 179) == .coveredByBreak, "a promised break is never covered: notice needs 210 s left, so 180 s remain at due")

// MARK: Meetings
section("meetings")
let now = at(14, 0)
check(MeetingRule.trimmedEnd(requested: at(14, 10), now: now, dayLocked: false, nextMeetingStart: at(14, 8)) == at(14, 3), "break ends 5 min before the meeting")
check(MeetingRule.trimmedEnd(requested: at(14, 10), now: now, dayLocked: false, nextMeetingStart: at(14, 6)) == nil, "under 2 min left: leave it")
check(MeetingRule.trimmedEnd(requested: at(14, 10), now: now, dayLocked: false, nextMeetingStart: nil) == nil, "no meeting: leave it")
check(MeetingRule.trimmedEnd(requested: at(15, 0), now: now, dayLocked: true, nextMeetingStart: at(14, 30)) == nil, "day locks aren't trimmed (they step aside instead)")
check(MeetingRule.trimmedEnd(requested: at(15, 0), now: now, dayLocked: false, nextMeetingStart: at(14, 30)) == nil, "an hour off isn't trimmed either")
let r1 = MeetingRule.resumesAfter(meetingEnd: at(14, 30), lockUntil: at(15, 0), dayLocked: false)
check(r1.resume == at(14, 35) && r1.comesBack, "an hour off comes back after the meeting")
let r2 = MeetingRule.resumesAfter(meetingEnd: at(14, 30), lockUntil: at(14, 35), dayLocked: false)
check(!r2.comesBack, "a short break is just taken")
check(MeetingRule.resumesAfter(meetingEnd: at(14, 30), lockUntil: at(14, 31), dayLocked: true).comesBack, "a day lock always comes back")

// MARK: Phone
section("phone unlock")
check(PhoneMessage.parse("30|meeting") == .pause(minutes: 30, reason: "meeting"), "minutes and reason")
check(PhoneMessage.parse("End pause|Just ending") == .end, "end wins")
check(PhoneMessage.parse("|") == .pause(minutes: 30, reason: nil), "an empty tap still unlocks (the Oct 3 Shortcut bug)")
check(PhoneMessage.parse("500") == .pause(minutes: 120, reason: nil), "capped at 2 h")
check(PhoneMessage.parse("0|x") == .pause(minutes: 1, reason: "x"), "floor of 1 min")
check(PhoneMessage.parse("workout|done|bridges 8, clamshells 10/10") == .workout(done: true, summary: "bridges 8, clamshells 10/10"), "phone workout result")
check(PhoneMessage.parse("workout|stopped|bridges 3") == .workout(done: false, summary: "bridges 3"), "a stopped phone workout isn't done")
check(PhoneMessage.parse("Workout|done|x") == .workout(done: true, summary: "x"), "case doesn't matter")
check(PhoneMessage.parse("rep|1|5") == .rep(step: 1, reps: 5), "a rep counted on the phone")
check(PhoneMessage.parse("rep|x") == .rep(step: 0, reps: 0), "a garbled rep never unlocks")
check(PhoneMessage.isFresh(sentAt: 1000, now: 1200) && !PhoneMessage.isFresh(sentAt: 1000, now: 1400), "5-minute freshness")

// MARK: Clean slate
section("clean slate")
func morning(_ hour: Int, woke: Bool = false, active: Double = 0, ran: Bool = false) -> Bool {
    CleanSlateRule.morningDue(hour: hour, cleanSlateHour: 4, morningHour: 6, woke: woke, activeSecondsSinceCleanSlateHour: active, ranToday: ran)
}
check(morning(4), "awake at 4 am: run")
check(!morning(3), "3 am: not yet")
check(morning(7, woke: true), "first open at 7: run")
check(!morning(7, woke: false), "a rebuild at 7 with no wake: don't")
check(!morning(11, woke: true, active: 3 * 3600), "an unlock at 11 after a morning of work: don't (B4)")
check(morning(11, woke: true, active: 20), "first open at 11 (a few seconds of mouse): run")
check(!morning(7, woke: true, ran: true), "once a day")
check(!CleanSlateRule.morningDue(hour: 7, cleanSlateHour: -1, morningHour: 6, woke: true, activeSecondsSinceCleanSlateHour: 0, ranToday: false), "-1 turns it off")
check(CleanSlateRule.awayDue(idleSeconds: 3600, awayMinutes: 60, clearedWithinStretch: false, explained: false), "an hour away")
check(!CleanSlateRule.awayDue(idleSeconds: 3600, awayMinutes: 60, clearedWithinStretch: false, explained: true), "a call explains the stillness")
check(!CleanSlateRule.awayDue(idleSeconds: 7200, awayMinutes: 60, clearedWithinStretch: true, explained: false), "once per stretch")
check(!CleanSlateRule.awayDue(idleSeconds: 7200, awayMinutes: 0, clearedWithinStretch: false, explained: false), "0 turns it off")

// MARK: App picker
section("app picker")
let always: Set<String> = ["com.electron.wispr-flow", "com.apple.finder"]
check(!AppGateRule.blocks(bundleID: "com.superhuman", picked: nil, always: always, paused: false, inCall: false), "no picker yet: nothing blocked")
check(AppGateRule.blocks(bundleID: "com.superhuman", picked: ["ai.perplexity.comet"], always: always, paused: false, inCall: false), "not picked: blocked")
check(!AppGateRule.blocks(bundleID: "ai.perplexity.comet", picked: ["ai.perplexity.comet"], always: always, paused: false, inCall: false), "picked: allowed")
check(!AppGateRule.blocks(bundleID: "com.electron.wispr-flow", picked: [], always: always, paused: false, inCall: false), "always-allowed even with an empty pick")
check(!AppGateRule.blocks(bundleID: "com.superhuman", picked: [], always: always, paused: true, inCall: false), "a pause frees everything")
check(!AppGateRule.blocks(bundleID: "us.zoom.xos", picked: [], always: always, paused: false, inCall: true), "never blocks during a call or meeting")

// MARK: Blinks
section("blinks")
check(BlinkRule.done(blinks: 20, target: 20, elapsed: 8, secondsSinceFace: 0, timerSeconds: 20, maxSeconds: 60), "20 blinks: done")
check(!BlinkRule.done(blinks: 12, target: 20, elapsed: 25, secondsSinceFace: 0, timerSeconds: 20, maxSeconds: 60), "face visible, 12 blinks: keep going past 20 s")
check(BlinkRule.done(blinks: 3, target: 20, elapsed: 20, secondsSinceFace: 5, timerSeconds: 20, maxSeconds: 60), "no face: falls back to the 20 s timer")
check(!BlinkRule.done(blinks: 3, target: 20, elapsed: 10, secondsSinceFace: 5, timerSeconds: 20, maxSeconds: 60), "no face but under 20 s: not yet")
check(BlinkRule.done(blinks: 5, target: 20, elapsed: 60, secondsSinceFace: 0, timerSeconds: 20, maxSeconds: 60), "never longer than 60 s")
var det = BlinkRule.Detector()
for r in [0.3, 0.3, 0.31, 0.1, 0.08, 0.29, 0.3, 0.12, 0.3, 0.3] { det.feed(r) }
check(det.blinks == 2, "two dips and recoveries = two blinks (got \(det.blinks))")
var steady = BlinkRule.Detector()
for r in [0.3, 0.28, 0.31, 0.27, 0.3] { steady.feed(r) }
check(steady.blinks == 0, "small wobbles aren't blinks")
var shallow = BlinkRule.Detector()
for r in [0.3, 0.3, 0.3, 0.21, 0.29, 0.3, 0.22, 0.3] { shallow.feed(r) }
check(shallow.blinks == 2, "a 30% dip counts: Vision's eye outline never fully closes (got \(shallow.blinks))")

var bug = Rep.Counter.legExtend()
for a in [95.0, 100, 160, 165, 120, 100, 155, 105] { bug.feed(a) }
check(bug.reps == 2, "dead bugs: two leg extensions (got \(bug.reps))")
var kick = Rep.Counter.kickback()
for a in [90.0, 130, 145, 120, 90] { kick.feed(a) }
check(kick.reps == 0, "kickbacks: a half lift isn't a rep")

// MARK: Switching
section("task switching")
func sw(_ n: Int, since: Double = 9999, paused: Bool = false, call: Bool = false, late: Bool = false) -> Bool {
    SwitchRule.shouldNudge(switches: n, threshold: 15, secondsSinceLastNudge: since, cooldown: 1800, paused: paused, inCall: call, late: late)
}
check(!sw(14), "14 switches: quiet")
check(sw(15), "15 switches in 10 min: one card")
check(!sw(30, since: 600), "at most once every 30 min")
check(!sw(30, call: true), "not during a call (switching windows in a meeting is normal)")
check(!sw(30, paused: true), "not while paused")
check(!sw(30, late: true), "not in the late-night cycle")

// MARK: Meeting or not
section("meeting or not")
check(!MeetingKind.counts(title: "Flight to Boston (DL 860)", minutes: 330, hasVideo: false, hasAttendees: true), "a flight is not a meeting (Oct 24)")
check(!MeetingKind.counts(title: "Flight to Boston (DL 860)", minutes: 90, hasVideo: false, hasAttendees: true), "even a short flight")
check(!MeetingKind.counts(title: "UA1234 SFO → JFK", minutes: 200, hasVideo: false, hasAttendees: true), "flight number + route")
check(!MeetingKind.counts(title: "Amtrak to NYC", minutes: 200, hasVideo: false, hasAttendees: true), "trains too")
check(!MeetingKind.counts(title: "Offsite workshop", minutes: 300, hasVideo: false, hasAttendees: true), "over 4 h isn't a meeting")
check(MeetingKind.counts(title: "Sam / Alex", minutes: 30, hasVideo: true, hasAttendees: true), "a normal call is")
check(MeetingKind.counts(title: "Board meeting Q4 to review", minutes: 120, hasVideo: false, hasAttendees: true), "'to' plus 'Q4' is not a flight number")
check(MeetingKind.counts(title: "Lunch with Sam", minutes: 60, hasVideo: false, hasAttendees: true), "in-person with attendees counts")
check(!MeetingKind.counts(title: "Focus time", minutes: 60, hasVideo: false, hasAttendees: false), "a personal block doesn't")

// MARK: Statements
section("statements")
let s1 = Statements.pick(Statements.addApp, last: nil, roll: 0, app: "Comet", time: "3:42 PM")
check(s1.text == "I need Comet for this block", "fills the app")
check(Statements.pick(Statements.addApp, last: s1.index, roll: 0, app: "Comet").index != s1.index, "never the same one twice in a row")
check(Statements.pick(Statements.unlock, last: nil, roll: 4, time: "9:05 PM").text.contains("9:05 PM"), "fills the time")
check(Statements.unlock.count >= 5 && Statements.addApp.count >= 5, "enough variety")

// MARK: Breathing
section("breathing")
check(abs(Breath.phase(seconds: 0)) < 0.001, "starts empty")
check(abs(Breath.phase(seconds: 5.5) - 1) < 0.001, "full at 5.5 s")
check(abs(Breath.phase(seconds: 11)) < 0.001, "empty again at 11 s")
check(Breath.inhaling(seconds: 3) && !Breath.inhaling(seconds: 8), "in, then out")

// MARK: Movement
section("movement")
check(MoveRule.posed(leftWristY: 0.9, rightWristY: 0.85, noseY: 0.7, hipsVisible: true, needStand: true), "standing, arms overhead")
check(!MoveRule.posed(leftWristY: 0.9, rightWristY: 0.85, noseY: 0.7, hipsVisible: false, needStand: true), "arms up but still sitting")
check(MoveRule.posed(leftWristY: 0.9, rightWristY: 0.85, noseY: 0.7, hipsVisible: false, needStand: false), "red day: the seated reach counts")
check(!MoveRule.posed(leftWristY: 0.9, rightWristY: 0.5, noseY: 0.7, hipsVisible: true, needStand: true), "one arm isn't a reach")
check(!MoveRule.posed(leftWristY: nil, rightWristY: 0.9, noseY: 0.7, hipsVisible: true, needStand: true), "a wrist out of view doesn't count")
check(MoveRule.release(held: 15, trying: 20, cameraOK: true).go, "15 s held: the break starts")
check(!MoveRule.release(held: 9, trying: 60, cameraOK: true).go, "9 s held: keep going")
check(MoveRule.release(held: 2, trying: 180, cameraOK: true).go, "never a trap: 3 min and it starts anyway")
check(MoveRule.release(held: 0, trying: 0, cameraOK: false).go, "no camera: starts right away")

// MARK: App picks
section("app picks")
check(!AppPickRule.needsPermission(alreadyPicked: 2, limit: 3), "third pick is free")
check(AppPickRule.needsPermission(alreadyPicked: 3, limit: 3), "a fourth asks for the statement")
check(!AppPickRule.needsPermission(alreadyPicked: 9, limit: 0), "0 = no limit")

// MARK: Avoidance
section("avoidance")
func av(now: Int = 34, then: Int = 12, quiet: Double = 120, active: Double = 100, calls: Int = 0, since: Double = 99, blocked: Bool = false) -> Bool {
    AvoidRule.shouldCallOut(unreadNow: now, unreadThen: then, minutesSinceOpened: quiet, activeMinutes: active, callsToday: calls, hoursSinceLast: since, blocked: blocked)
}
check(av(), "unread 12 → 34, untouched 2 h while busy elsewhere: call it out")
check(!av(now: 18), "only +6: quiet")
check(!av(quiet: 40), "opened 40 min ago: not avoiding")
check(!av(active: 20), "away from the computer, not avoiding")
check(!av(calls: 2), "twice a day at most")
check(!av(since: 1), "two hours apart")
check(!av(blocked: true), "never in a call, pause or the late cycle")

// MARK: Coaching + micro stretch
section("coaching and micro stretch")
func coach(_ seen: Bool = true, w: Double? = 0.25, x: Double? = 0.5, hips: Bool = true, stand: Bool = true, l: Bool = true, r: Bool = true) -> String {
    MoveRule.coach(bodySeen: seen, shoulderWidth: w, centerX: x, hipsVisible: hips, needStand: stand, leftWristUp: l, rightWristUp: r)
}
check(coach(false) == "Step in front of the camera", "nobody in view")
check(coach(w: 0.6) == "Back up a bit", "too close")
check(coach(hips: false) == "Back up so I can see your hips", "standing needs hips in view")
check(coach(hips: false, stand: false) == "✓ That's it, hold it", "red day: seated is fine")
check(coach(w: 0.05) == "Come a little closer", "too far")
check(coach(x: 0.9) == "Move toward the middle", "off to the side")
check(coach(l: false, r: false) == "Both arms up, over your head", "arms down")
check(coach(l: false) == "Other arm up too", "one arm")
check(MicroRule.due(active: 1800, every: 1800, blockRemaining: 600, eyeIn: 300, blocked: false), "30 min: stretch")
check(!MicroRule.due(active: 1800, every: 1800, blockRemaining: 100, eyeIn: 300, blocked: false), "a regular break is about to cover it")
check(!MicroRule.due(active: 1800, every: 1800, blockRemaining: 600, eyeIn: 20, blocked: false), "not on top of an eye break")
check(!MicroRule.due(active: 1800, every: 0, blockRemaining: 600, eyeIn: 300, blocked: false), "0 = off")

// MARK: Reps
section("reps")
check(abs(Rep.angle((0, 1), (0, 0), (1, 0)) - 90) < 0.01, "a right angle is 90°")
check(abs(Rep.angle((-1, 0), (0, 0), (1, 0)) - 180) < 0.01, "a straight arm is 180°")
var pu = Rep.Counter.pushUp()
for a in [170.0, 160, 120, 95, 80, 90, 130, 155, 170, 165, 140, 98, 85, 152, 170] { pu.feed(a) }
check(pu.reps == 2, "two full push-ups (got \(pu.reps))")
var half = Rep.Counter.pushUp()
for a in [170.0, 130, 110, 140, 165] { half.feed(a) }
check(half.reps == 0, "a half push-up doesn't count")
var cs = Rep.Counter.clamshell()
for a in [5.0, 10, 25, 40, 45, 20, 8, 6, 35, 50, 11, 9] { cs.feed(a) }
check(cs.reps == 2, "two clamshells (got \(cs.reps))")
var jitter = Rep.Counter.clamshell()
for a in [10.0, 14, 11, 16, 13, 9] { jitter.feed(a) }
check(jitter.reps == 0, "jitter near closed isn't a rep")
var br = Rep.Counter.bridge()
for a in [128.0, 135, 150, 162, 170, 165, 145, 135, 130, 160, 172, 138] { br.feed(a) }
check(br.reps == 2, "two glute bridges (got \(br.reps))")
var halfBridge = Rep.Counter.bridge()
for a in [130.0, 145, 152, 141, 132] { halfBridge.feed(a) }
check(halfBridge.reps == 0, "a half bridge doesn't count")
func snack(_ h: Int = 12, tier: String = "yellow", n: Int = 0, last: Bool = false, place: String? = "lying") -> Bool {
    WorkoutRule.due(hour: h, afterHour: 10, tier: tier, snacksToday: n, perDay: 3, lastBreakWasWorkout: last, place: place)
}
check(snack(), "a midday break: exercise snack")
check(!snack(tier: "red"), "never on red days")
check(!snack(17), "not from 5 pm")
check(!snack(9), "not before 10")
check(snack(n: 2) && !snack(n: 3), "up to 3 a day")
check(!snack(last: true), "never two breaks in a row")
check(!snack(place: nil), "no workout where the place allows none (Boston, unknown)")
check(snack(place: "standing"), "the office allows the standing set")
check(WorkoutRule.pick(["bridges", "clams"], snacksToday: 0) == "bridges" && WorkoutRule.pick(["bridges", "clams"], snacksToday: 3) == "clams", "exercises rotate")
var ls = Rep.Counter.legSpread()
for a in [4.0, 12, 28, 35, 20, 8, 5, 30, 9] { ls.feed(a) }
check(ls.reps == 2, "two kickbacks / side raises (got \(ls.reps))")

// MARK: ADaPT
section("adapt")
let plan = AdaptPlan()
check(plan.today(tier: "red", dipped: false, hour: 10, days: 0, daysOff: 1, doneToday: false).status == "Rest day", "red morning → rest")
check(plan.today(tier: "green", dipped: false, hour: 10, days: 0, daysOff: 2, doneToday: false).status == "Planned", "2 days off → planned")
check(plan.today(tier: "green", dipped: false, hour: 18, days: 0, daysOff: 1, doneToday: false).status == "Rest day", "after 5 pm → tomorrow")
check(plan.today(tier: "green", dipped: false, hour: 10, days: 3, daysOff: 1, doneToday: false).status == "Rest day", "week's 3 done → optional")
check(plan.today(tier: "green", dipped: false, hour: 10, days: 1, daysOff: 1, doneToday: true).status == "Done", "done today")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
