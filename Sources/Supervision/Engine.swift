import AppKit
import EventKit

/// The decision-maker. Ticks every 5 s. Every decision it makes is logged with its
/// reason, and the same reason is shown on screen: blocks whose length follows how you
/// are, one daily cap on computer time, the symptom gate after each card, and the ramp.
final class Engine {
    static let shared = Engine()
    var config = Config.load()
    var capacity = Capacity.load()
    private var timer: Timer?

    private var blockActiveSeconds = 0.0   // focused seconds in the current work block
    private var activeSinceLongRest = 0.0  // focused seconds since the last long horizontal rest
    private var eyeActiveSeconds = 0.0     // focused seconds since the last look-away (20-20-20)
    private var eyeNudged = false
    private var microActiveSeconds = 0.0, microNudged = false   // focused seconds since the last micro stretch (regular breaks don't reset it)
    private var eyeWaitLogged = false
    private var lastSwitchCheck = Date.distantPast
    private var lastWhoopTry = Date.distantPast, whoopFetching = false
    private var syncRunning = false, lastSyncTry = Date.distantPast
    private var movePending: (duration: Double, needStand: Bool, started: Date, held: Double, cameraOK: Bool)?
    private var movePosed = false, moveCoach = ""
    private var lastBreakHadWorkout = false   // movement, then rest: never two workout breaks in a row
    private var workoutPending = false   // this break holds a counted workout; it can't end until done (or 5 min past)
    private var insightRunning = false, pendingInsight: (text: String, evidence: String)?
    private var lastSwitchNudge = Date.distantPast
    private(set) var recentSwitches = 0   // app switches in the last `switchWindowMinutes`, refreshed each minute
    private var nudged = false
    private var breakUntil: Date?
    private var breakDeferredSince: Date?
    private var dayLocked = false
    private var softened = false           // a score dropped by `softenDropBy` → shortest blocks, rest-only breaks
    private var blockLen: Int?             // today's live block length once a card has adjusted it
    private var nightBreak = false         // current break is a late-night one: ends on its own, no card
    // A lock steps aside for a meeting and comes back after it (if its time isn't up).
    private var suspendedUntil: Date?
    private var pendingLock: (until: Date, title: String, reason: String)?
    private var lastLock: (title: String, reason: String) = ("", "")
    private var lastWorkoutCheck = Date.distantPast
    private var lastHourWritten = Calendar.current.component(.hour, from: Date())
    private var lastDay = Day.today
    private var lastLoggedPause = ""
    private var lastHorizontalPrompt = Date.distantPast
    private var dayCloseShown = false
    private var mealBreakSeen = false
    private var currentPlan: BreakPlan?
    private var awaitingCompletion = false
    private var lastUnlockStatement: Int?
    private var phoneAsking = false        // the typed phone-unlock question is up; expires with the break
    private var breakStartedAt = Date()
    private var contexts = Contexts.load()
    private var lastContextCheck = Date.distantPast
    private var lastCapacityReload = Date()

    // MARK: - Lifecycle

    func start() {
        restoreTodayState()
        lastSwitchNudge = Store.shared.lastEvent(kind: "switch_burst", since: Day.today)?.0 ?? .distantPast
        evaluateRamp()
        CleanSlate.shared.start()
        Rewards.prepareCamera()
        PhoneRelay.shared.start()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        Store.shared.event("start", "Supervision started. \(capacity.experimentLabel). Starting blocks \(capacity.blockGreen)/\(capacity.blockYellow)/\(capacity.blockRed), cap \(String(format: "%g", capacity.dailyCapMinutes / 60)) h.")
    }

    /// Once-a-day things must stay once-a-day across restarts (updates, crashes),
    /// so they're rebuilt from the event log rather than kept only in memory.
    private func restoreTodayState() {
        let start = Day.today
        dayCloseShown = Store.shared.lastEvent(kind: "day_close", since: start) != nil
        lastHorizontalPrompt = Store.shared.lastEvent(kind: "horizontal_prompt", since: start)?.0 ?? .distantPast
        mealBreakSeen = Store.shared.lastEvent(kind: "meal_break", since: start) != nil
        softened = Store.shared.lastEvent(kind: "gate_soften", since: start) != nil
        blockLen = Store.shared.lastEvent(kind: "block_len", since: start).flatMap { Int($0.1.split(separator: "|").first ?? "") }
        // The current work stretch survives a restart (an update must not hand out a free block).
        let lastBreak = [Store.shared.lastEvent(kind: "break_end", since: start)?.0, Store.shared.lastEvent(kind: "natural_break", since: start)?.0].compactMap { $0 }.max() ?? start
        blockActiveSeconds = Store.shared.currentStretchSeconds(gap: config.idleResetMinutes * 60, since: lastBreak)
        let lastLong = Store.shared.lastEvent(kind: "long_rest_done", since: start)?.0 ?? start
        activeSinceLongRest = Store.shared.currentStretchSeconds(gap: Double(capacity.longRestMinutes) * 60, since: lastLong)
        // A workout today makes the next break the long lie-down; that must survive a restart too (B3).
        if let w = Store.shared.lastEvent(kind: "workout_reacted", since: start)?.0, w > lastLong { activeSinceLongRest = Double(capacity.longRestEveryMinutes) * 60 }
        // The 20-20-20 clock: focused seconds since the last look-away or break, whichever is later (B2).
        let lastEye = [lastBreak, Store.shared.lastEvent(kind: "eye_break", since: start)?.0].compactMap { $0 }.max() ?? start
        eyeActiveSeconds = Store.shared.currentStretchSeconds(gap: config.idleResetMinutes * 60, since: lastEye)
        let lastMicro = [Store.shared.lastEvent(kind: "micro_move", since: start)?.0, Store.shared.lastEvent(kind: "natural_break", since: start)?.0].compactMap { $0 }.max() ?? start
        microActiveSeconds = Store.shared.currentStretchSeconds(gap: config.idleResetMinutes * 60, since: lastMicro)
        // After a restart, a lock that was in force comes back, unless something cleared it
        // since (a pause/override, or Claude marking a reading as a mistake: `gate_cleared`).
        let cleared = [Store.shared.lastEvent(kind: "gate_cleared", since: start)?.0, Store.shared.lastEvent(kind: "override", since: start)?.0].compactMap { $0 }.max() ?? .distantPast
        let stands: ((Date, String)?) -> (Date, String)? = { e in e.flatMap { $0.0 > cleared ? $0 : nil } }
        if Control.load().isPaused { clearBreakState(); return }
        if let b = lenientLoad(Self.breakFile, defaults: BreakState(until: .distantPast, title: "", reason: "")), b.until > Date(),
           b.until.timeIntervalSinceNow < 3600, Store.shared.lastEvent(kind: "day_lock", since: start) == nil || usedToday() < capToday().minutes {
            startBreak(until: b.until, title: b.title, reason: b.reason, resumed: true)
            return
        }
        clearBreakState()
        if let lock = Store.shared.lastEvent(kind: "day_lock", since: start), lock.0 > start,
           stands(Store.shared.lastEvent(kind: "gate_stop", since: start)) != nil || usedToday() >= capToday().minutes {
            dayLocked = true
            startBreak(until: tomorrowMorning(), title: "Still done for today 💛", reason: lock.1)
        } else if let rest = stands(Store.shared.lastEvent(kind: "gate_rest", since: start)),
                  rest.0.addingTimeInterval(Double(capacity.gateRestMinutes) * 60) > Date() {
            startBreak(until: rest.0.addingTimeInterval(Double(capacity.gateRestMinutes) * 60), title: "Still your hour off 💛", reason: rest.1)
        }
    }

    /// A regular break survives a restart (Oct 25: each update mid-break began a fresh, full one).
    private static let breakFile = Paths.dir.appendingPathComponent("break.json")
    private struct BreakState: Codable { var until: Date; var title: String; var reason: String }
    private func saveBreakState() {
        guard let u = breakUntil, !dayLocked, !nightBreak else { return }
        saveJSON(BreakState(until: u, title: lastLock.title, reason: lastLock.reason), to: Self.breakFile)
    }
    private func clearBreakState() { try? FileManager.default.removeItem(at: Self.breakFile) }

    /// The next `morningHour` (6 am): tomorrow's if it's already past, today's if it's the small hours.
    private func tomorrowMorning() -> Date { Rules.nextMorning(after: Date(), morningHour: capacity.morningHour) }

    private var hourNow: Int { Calendar.current.component(.hour, from: Date()) }
    /// 10 pm to midnight: 2-minute blocks, 10-minute breaks.
    var isLateEvening: Bool { hourNow >= capacity.nightStartHour }
    /// Midnight to 6 am: off.

    // MARK: - Today's numbers (all derived from the log, so they survive restarts)

    var tier: String { Baseline.load().tier }
    var experimentLabel: String { capacity.experimentLabel }

    private var loadCache: (at: Date, load: DayLoad)?
    /// Today's load (≈27 queries): computed at most once every 4 s, since samples arrive every 5 s (R5).
    func todayLoad() -> DayLoad {
        if let c = loadCache, -c.at.timeIntervalSinceNow < 4, Calendar.current.isDateInToday(c.at) { return c.load }
        let l = Store.shared.dayLoad(Date(), calendarMeetingMinutes: CalendarBridge.shared.meetingMinutesToday())
        loadCache = (Date(), l)
        return l
    }
    func focusedMinutesToday() -> Double { todayLoad().focused }
    func meetingMinutesToday() -> Double { todayLoad().meeting }
    func weightedToday() -> Double { todayLoad().weighted }

    /// Active minutes on the computer today (meetings included): what the cap counts.
    func usedToday() -> Double { todayLoad().screen }

    /// The one daily cap, plus any one-day adjustment Claude made.
    func capToday() -> (minutes: Double, reasons: [String]) {
        let extra = Control.load().extraBudgetMinutes
        return (capacity.dailyCapMinutes + extra, extra == 0 ? [] : ["Claude adjusted \(extra > 0 ? "+" : "")\(Int(extra)) today"])
    }

    func loadPercent() -> Double { min(100, usedToday() / max(1, capToday().minutes) * 100) }

    /// Where today's blocks start: the tier's block, a step shorter on a short-sleep,
    /// travel or stress day. The live length then follows the how-are-you cards.
    func startingBlock() -> (minutes: Int, reasons: [String]) {
        var b = capacity.block(for: tier), why: [String] = []
        if capacity.stepDownActive { why.append("step-down until \(Day.pretty(capacity.stepDownUntil))") }
        let bl = Baseline.load(), start = Day.today
        var shorter: [String] = []
        if bl.isToday, let sl = bl.sleepHours, sl > 0, sl < 6 { shorter.append("sleep \(String(format: "%.1f", sl)) h") }
        if Store.shared.lastEvent(kind: "flag_travel", since: start) != nil { shorter.append("travel day") }
        if Store.shared.lastEvent(kind: "flag_stress", since: start) != nil { shorter.append("stressful day") }
        if !shorter.isEmpty { b -= capacity.blockStep; why.append(shorter.joined(separator: ", ") + " → \(capacity.blockStep) min shorter") }
        return (max(capacity.blockMin, b), why)
    }

    var blockMinutes: Int { isLateEvening ? capacity.nightBlockMinutes : softened ? capacity.blockMin : (blockLen ?? startingBlock().minutes) }
    var restMinutes: Int { softened ? capacity.restRed : capacity.rest(for: tier) }

    /// After a card: nudge the next block. Only clear/head/not-crashing move it down;
    /// steady-or-better plus a good overall moves it up.
    private func adaptBlock(_ now: [String: Int], readings: [[String: Int]]) {
        let before = blockMinutes
        guard let (after, why) = BlockRule.adapt(before: before, now: now, readings: readings, keys: capacity.gateKeys, step: capacity.blockStep,
                                                 min: capacity.blockMin, max: capacity.blockMax, upOverall: capacity.adaptUpOverall, softened: softened) else { return }
        blockLen = after
        Store.shared.event("block_len", "\(after)|\(before) → \(after) min: \(why)")
    }

    /// Where things stand right now, computed once for the menu bar and the corner pill (R1).
    enum Standing { case inBreak(minutesLeft: Int), done, paused(minutesLeft: Int), meetingWait, late, working }
    var standing: Standing {
        if let b = breakUntil { return .inBreak(minutesLeft: Int(max(0, b.timeIntervalSinceNow) / 60) + 1) }
        if dayLocked { return .done }
        let c = Control.load()
        if c.isPaused, let u = c.pauseUntil { return .paused(minutesLeft: Int(u.timeIntervalSinceNow / 60) + 1) }
        if suspendedUntil != nil { return .meetingWait }
        if isLateEvening { return .late }
        return .working
    }

    /// The corner pill: where you are, in one glance.
    var pillText: String {
        switch standing {
        case .inBreak(let m): return "🌙 Break · \(m) min left"
        case .done: return "🔒 Done for today"
        case .paused(let m): return "⏸ Paused · \(m) min left"
        case .meetingWait: return "📅 Meeting · lock waits"
        case .late: return "🌙 Late: 2 on, 10 off"
        case .working:
            let u = Int(usedToday())
            return "🧠 Break in \(max(0, blockMinutes - Int(blockActiveSeconds / 60))) min · 🔀 \(recentSwitches) · ⏱ \(u / 60)h\(String(format: "%02d", u % 60)) today"
        }
    }

    var pillDetail: String {
        let used = usedToday(), cap = capToday().minutes
        let eye = config.eyeEveryMinutes > 0 ? "\nEyes: look away in \(max(0, Int(config.eyeEveryMinutes) - Int(eyeActiveSeconds / 60))) min." : ""
        return "Block: \(Int(blockActiveSeconds / 60)) of \(blockMinutes) focused min (only active time counts).\(eye)\nSwitches: \(recentSwitches) app changes in the last \(Int(config.switchWindowMinutes)) min (card at \(config.switchThreshold)).\nToday: \(Int(used / 60)) h \(Int(used) % 60) min of \(String(format: "%g", cap / 60)) h."
    }

    /// The menu-bar item, terse.
    var statusText: String {
        switch standing {
        case .inBreak(let m): return "🌙 \(m)m"
        case .done: return "🔒 done"
        case .paused: return "⏸ paused"
        case .meetingWait, .late, .working: return "🧠 \(Int(blockActiveSeconds / 60))/\(blockMinutes) · \(Int(loadPercent()))%"
        }
    }

    // MARK: - Main loop

    private func tick() {
        rolloverDayIfNeeded()
        writeHourIfNeeded()
        if -lastCapacityReload.timeIntervalSinceNow > 60 { capacity = Capacity.load(); lastCapacityReload = Date() }
        CleanSlate.shared.maybeRun(config: config, morningHour: capacity.morningHour)   // the rule handles -1 = off
        let control = Control.load()
        maybeSync(control)
        let idle = Tracker.idleSeconds

        // 1. In a break: count down, then "how did that go", then release (the 1–10 card follows).
        if let until = breakUntil {
            if control.isPaused { endBreak(reason: "paused by Claude: \(control.reason)", outcome: "paused"); return }
            // Never keep someone from a meeting: the lock steps aside 5 min before one.
            if let m = CalendarBridge.shared.meetingSoon(minutes: 5) { suspendLock(for: m, until: until); return }
            if awaitingCompletion { return }
            // The phone-unlock question stays up only while the break has time left; after that
            // the normal "How did that go?" takes over, so the screen can never get stuck on it.
            // Checked before the movement step, which would otherwise draw "0:00" over the question.
            if phoneAsking { if Date() < until { return }; phoneAsking = false }
            // Workout break (Oct 26): the break can't end until the reps are counted; 5 min past the end it lets go.
            if workoutPending && Date() >= until {
                if Date().timeIntervalSince(until) < 300 {
                    LockScreen.shared.setMove("Finish your workout to continue"); LockScreen.shared.update(countdownText: "0:00"); return
                }
                workoutPending = false; WorkoutSession.shared.dismiss(); LockScreen.shared.setMove(nil)
                Store.shared.event("workout", "gave up: 5 min past the break")
            }
            // Movement (user, Oct 25): the countdown runs from the start (no restart when the stretch
            // is seen); the break just can't END until the camera has seen it, and seeing it takes a
            // minute off. Gives up 3 min past the end, or right away without a camera (MoveRule).
            if let mp = movePending {
                let r = MoveRule.release(held: mp.held, trying: max(0, Date().timeIntervalSince(until)), cameraOK: mp.cameraOK)
                if r.go {
                    movePending = nil; MoveCounter.shared.stop()
                    Store.shared.event("move_check", "\(r.why) (\(Int(mp.held)) s held, \(Int(-mp.started.timeIntervalSinceNow)) s)\(mp.needStand ? "" : ", seated reach (red day)")")
                    if r.why == "seen" {
                        breakUntil = max(Date(), until.addingTimeInterval(-60)); saveBreakState()
                        let today = Store.shared.eventDetails(kind: "move_check", since: Day.today).filter { $0.hasPrefix("seen") }.count
                        let all = Store.shared.eventDetails(kind: "move_check", since: .distantPast).filter { $0.hasPrefix("seen") }.count
                        LockScreen.shared.showMoveDone(Voice.pick(["✓ Stretch done", "✓ Nice reach", "✓ Seen, and counted", "✓ That's the one"], today) + " · 1 min off · \(today) today · \(all) all-time")
                    } else { LockScreen.shared.setMove(nil) }
                    return
                }
                let left = Int(ceil(MoveRule.holdSeconds - mp.held))
                let due = Date() >= until
                // Coaching instead of the bare instruction once the camera has an opinion (Oct 26).
                let ask = mp.needStand ? "Stand, both arms overhead" : "Both arms overhead, from your chair"
                LockScreen.shared.showMoveProgress(cue: (due ? "One stretch to finish · " : "") + (moveCoach.isEmpty ? ask : moveCoach) + " · \(left) s",
                                                   held: mp.held, posed: movePosed)
                if due { LockScreen.shared.update(countdownText: "0:00"); return }
            }
            if Date() >= until {
                if dayLocked { endBreak(reason: "new day", outcome: "day"); return }
                if nightBreak { endBreak(reason: "late-night break over", outcome: "rested"); return }   // no card at night
                awaitingCompletion = true
                let a = currentPlan?.activity
                let opts: [(label: String, value: String)] = a == nil || a?.load == "none"
                    ? [("Rested 🌙", "rested"), ("Didn't really rest", "skipped")]
                    : [("Did it \(a!.emoji)", "did"), ("Rested instead 🌙", "rested"), ("Skipped", "skipped")]
                LockScreen.shared.askCompletion(question: "How did that go?", options: opts) { [weak self] v in
                    self?.askSymptomsThenEnd(outcome: v)
                }
            } else {
                LockScreen.shared.update(countdownText: countdown(until))
            }
            return
        }
        maybeSwitchContext()
        maybeReactToWorkout()

        // A lock that stepped aside for a meeting comes back afterwards, if its time isn't up.
        if let s = suspendedUntil {
            if Date() < s || CalendarBridge.shared.meetingSoon(minutes: 5) != nil { return }
            suspendedUntil = nil
            if let p = pendingLock, p.until > Date() {
                pendingLock = nil
                Store.shared.event("lock_resumed", "Meeting over; lock back until \(Day.clock(p.until))")
                startBreak(until: p.until, title: p.title, reason: p.reason + " (Back after your meeting.)")
                return
            }
            pendingLock = nil
        }

        // A workout asked for in chat (`supervisionctl workout`), to try it.
        if control.workoutNow {
            var c = control; c.workoutNow = false; let n = c.workoutTryReps; c.workoutTryReps = 0; saveJSON(c, to: Control.file)
            startWorkout(inBreak: false, tryReps: n); return
        }

        // A micro stretch asked for in chat (`supervisionctl stretch`), to try it.
        if control.microNow {
            var c = control; c.microNow = false; saveJSON(c, to: Control.file)
            microActiveSeconds = max(microActiveSeconds, config.microEveryMinutes * 60)
            let needStand = tier != "red"
            microActiveSeconds = 0
            if !MicroMove.shared.show(hold: config.microHoldSeconds, needStand: needStand, statement: config.microSkipStatement, done: { outcome, held in
                Store.shared.event("micro_move", "\(outcome) (\(Int(held)) s held, asked for in chat)")
            }) { Store.shared.event("micro_move", "no camera, skipped (asked for in chat)") }
            return
        }

        // An eye break asked for in chat (`supervisionctl eye`), to try it.
        if control.eyeNow {
            var c = control; c.eyeNow = false; saveJSON(c, to: Control.file)
            eyeActiveSeconds = config.eyeEveryMinutes * 60; eyeNudged = true
            _ = maybeEyeBreakNow()
            return
        }

        // A break asked for in chat (`supervisionctl break`), e.g. to test the phone unlock.
        if control.breakNowMinutes > 0 && !control.isPaused {
            var c = control; let mins = c.breakNowMinutes; c.breakNowMinutes = 0; saveJSON(c, to: Control.file)
            startBreak(until: Date().addingTimeInterval(mins * 60), title: "A break you asked for 💛", reason: c.reason.isEmpty ? "Asked for in chat." : c.reason)
            return
        }

        // 2. Pause from Claude: never lock, but keep tracking.
        if control.isPaused {
            if lastLoggedPause != control.reason { lastLoggedPause = control.reason; Store.shared.event("pause", control.reason) }
            return
        }

        // Midnight to morning: off, whatever's left of the cap. Checked before idle so it's
        // there the moment you come back.
        if hourNow < capacity.morningHour && !dayLocked {
            dayLocked = true
            let reason = "It's past midnight, so the computer is off until \(capacity.morningHour) am, however much of today's cap is left. Sleep is the best recovery there is."
            Store.shared.event("night_lock", reason)
            startBreak(until: tomorrowMorning(), title: "Midnight. The computer's done for tonight 🌙", reason: reason)
            return
        }

        // 3. Being away long enough counts as a break taken (AMMES: rest between activities).
        if idle > config.idleResetMinutes * 60 {
            if blockActiveSeconds > 0 { Store.shared.event("natural_break", "Away \(Int(idle / 60))m — block reset") }
            let hour = hourNow
            if idle > 20 * 60 && (11...14).contains(hour) && !mealBreakSeen {
                mealBreakSeen = true; Store.shared.event("meal_break", "Away \(Int(idle / 60))m at \(hour)h")
            }
            if idle > Double(capacity.longRestMinutes) * 60 { activeSinceLongRest = 0 }
            if eyeNudged && eyeActiveSeconds > 0 { Store.shared.event("eye_cancel", "Away \(Int(idle / 60))m after the heads-up; that counts as looking away") }
            blockActiveSeconds = 0; eyeActiveSeconds = 0; microActiveSeconds = 0; microNudged = false; nudged = false; breakDeferredSince = nil
            return
        }
        if idle > 60 { return } // short pause: don't count, don't reset

        if EyeBreak.shared.isShowing || MicroMove.shared.isShowing { return }
        blockActiveSeconds += 5; activeSinceLongRest += 5; eyeActiveSeconds += 5; microActiveSeconds += 5
        if maybeEyeBreak() { return }
        if maybeMicroMove() { return }
        maybeSwitchNudge()
        maybeFetchWhoop()
        Avoidance.shared.check(config: config, blocked: control.isPaused || isLateEvening || liveCall(calendarBuffer: 0) != nil) { [weak self] text, top in
            self?.avoidCard(text, top)
        }
        maybeInsight()
        maybeMorningBrief()

        // 4. The daily cap on computer time.
        let (budget, _) = capToday()
        let weighted = usedToday()
        if !dayLocked && weighted >= budget {
            dayLocked = true
            let reason = "That's \(Int(weighted / 60)) h \(Int(weighted) % 60) min on the computer today, your \(String(format: "%g", budget / 60))-hour cap. \(daySummary()) Whatever's left can happen off the screen, or tomorrow. \(capacity.experimentLabel)."
            Store.shared.event("day_lock", reason)
            startBreak(until: tomorrowMorning(), title: "That's today's experiment done 💛", reason: reason)
            return
        }

        // 5. Gentle nudge before the takeover — once per block, no stacking (not at night).
        let workSecs = Double(blockMinutes) * 60
        if !nudged && !isLateEvening && blockActiveSeconds >= workSecs - config.nudgeMinutesBefore * 60 {
            nudged = true
            Card.shared.showNudge("Break in \(Int(config.nudgeMinutesBefore)) min 🌱",
                                  reason: "\(Int(blockActiveSeconds / 60)) min of \(Tracker.shared.lastCategory) this block. Today: \(Int(weighted)) of \(Int(budget)) min on the computer. Find a stopping point.")
            Store.shared.event("nudge", "block \(Int(blockActiveSeconds / 60))m, day \(Int(weighted))/\(Int(budget))")
        }

        // 6. Block done → break, unless a meeting is on or about to start.
        if blockActiveSeconds >= workSecs {
            if let m = meetingBlocker() {
                if breakDeferredSince == nil {
                    breakDeferredSince = Date()
                    Store.shared.event("break_deferred", m)
                    Card.shared.showNudge("Break waiting ⏳", reason: "\(m). Your rest starts right after.", seconds: 15)
                }
                return
            }
            if isLateEvening {
                let reason = "After \(capacity.nightStartHour > 12 ? capacity.nightStartHour - 12 : capacity.nightStartHour) pm it's \(capacity.nightBlockMinutes) minutes on, \(capacity.nightBreakMinutes) off, and at midnight the computer stops. Enough to finish a sentence, not to start something."
                Store.shared.event("night_break", reason)
                nightBreak = true; currentPlan = nil
                startBreak(until: Date().addingTimeInterval(Double(capacity.nightBreakMinutes) * 60), title: "It's late 🌙", reason: reason)
                return
            }
            let deferred = breakDeferredSince.map { " (waited \(Int(-$0.timeIntervalSinceNow / 60)) min for your meeting)" } ?? ""
            let plan = makePlan()
            let reasonLine = "\(Int(blockActiveSeconds / 60)) min of focused \(Tracker.shared.lastCategory)\(deferred). " + plan.reason + " \(capacity.experimentLabel)."
            currentPlan = plan
            Store.shared.event("break_plan", "\(plan.activity.key)|\(plan.activity.load)|\(plan.acknowledgement ?? plan.reason)")
            startBreak(until: Date().addingTimeInterval(Double(plan.activity.minutes) * 60), title: plan.headline, reason: reasonLine, plan: plan)
            return
        }

        maybeHorizontalPrompt()
    }

    // MARK: - Planning

    /// Every ~2 h of focused work the break is the long horizontal one; otherwise
    /// the planner picks. Softened days (a score dropped by `softenDropBy`) are rest-only.
    private func makePlan() -> BreakPlan {
        let base = Baseline.load()
        if activeSinceLongRest >= Double(capacity.longRestEveryMinutes) * 60 {
            let rest = Activity.catalog["rest"]!
            let long = Activity(key: "rest", title: rest.title, emoji: "🛏️", minutes: capacity.longRestMinutes, load: "none",
                                instructions: "This is the long one. Fully flat, eyes closed, \(capacity.longRestMinutes) minutes. It's where the recovery actually happens.", minTier: "red")
            return BreakPlan(activity: long, headline: "The long rest 🛏️", reason: "\(Int(activeSinceLongRest / 60)) min of focused work since the last long rest; one every \(capacity.longRestEveryMinutes / 60) h is the rule.",
                             acknowledgement: nil, unlock: nil, alternatives: [Activity.catalog["music"]!], hrCeiling: base.hrCeiling)
        }
        var inputs = plannerInputs()
        if softened { inputs.lastOverall = min(inputs.lastOverall ?? 10, 4) } // forces the rest-only gate; wording replaced below
        var plan = Planner.plan(inputs)
        if softened, plan.acknowledgement != nil {
            plan = BreakPlan(activity: plan.activity, headline: plan.headline, reason: plan.reason,
                             acknowledgement: "Your numbers after the last break dropped a notch, so the rest of today is plain rest and shorter blocks. That's the gate working, not a verdict.",
                             unlock: "What brings the options back: tomorrow morning, and steady numbers.", alternatives: plan.alternatives, hrCeiling: plan.hrCeiling)
        }
        // Short rests by tier: the planner's rest activity gets today's rest length.
        if plan.activity.load == "none" {
            let r = plan.activity
            plan.activity = Activity(key: r.key, title: r.title, emoji: r.emoji, minutes: max(restMinutes, 5), load: r.load, instructions: r.instructions, minTier: r.minTier)
        }
        return plan
    }

    private func plannerInputs() -> Planner.Inputs {
        let start = Day.today
        let done = Store.shared.eventDetails(kind: "break_done", since: start).map { $0.split(separator: "|").map(String.init) }
        let keys = done.compactMap { $0.first }.filter { $0 != "skipped" }
        let active = done.filter { $0.count > 1 && $0[1] != "none" && $0[0] != "rest" && $0[0] != "skipped" }.count
        let lastLoad = done.last.map { $0[0] == "rest" || $0[0] == "skipped" ? "none" : ($0.count > 1 ? $0[1] : "none") } ?? "none"
        return Planner.Inputs(baseline: Baseline.load(), context: contexts.active, loadPercent: loadPercent(),
                              usedMinutes: usedToday(), capMinutes: capToday().minutes,
                              meetingMinutes: meetingMinutesToday(), lastOverall: Store.shared.latestOverallToday(),
                              hour: hourNow, breaksToday: keys,
                              activeBreaksToday: active, lastBreakLoad: lastLoad)
    }

    /// 20-20-20: every `eyeEveryMinutes` of focused time, 20 s looking far away. Skipped when a
    /// regular break is under 3 min off (that break covers it); waits out calls and meetings;
    /// not in the late-night 2-on/10-off. Returns true if it started one.
    private func maybeEyeBreak() -> Bool {
        let notice = config.eyeNoticeSeconds
        if eyeActiveSeconds < notice { eyeNudged = false }
        var callWhy: String?
        let nearNight = Date().addingTimeInterval(90) >= Calendar.current.date(bySettingHour: capacity.nightStartHour, minute: 0, second: 0, of: Date())!
        let action = EyeRule.decide(active: eyeActiveSeconds, due: config.eyeEveryMinutes * 60, notice: notice, nudged: eyeNudged,
                                    blockRemaining: Double(blockMinutes) * 60 - blockActiveSeconds, nearNight: nearNight, late: isLateEvening,
                                    inCall: { callWhy = self.liveCall(calendarBuffer: 0)?.why; return callWhy != nil })
        switch action {
        case .nothing:
            return false
        case .notice:
            eyeNudged = true
            Store.shared.event("eye_notice", "heads-up shown, \(Int(notice)) s before")
            Card.shared.showNudge("👀 Eye break in \(Int(notice)) sec", reason: "20 min on screen. 20 seconds looking far away, then right back.", seconds: 12)
            return false
        case .coveredByBreak:
            eyeActiveSeconds = 0
            return false
        case .wait:
            if !eyeWaitLogged { eyeWaitLogged = true; Store.shared.event("eye_wait", "\(callWhy ?? "a call"); the eye break waits until it's over") }
            return false
        case .start:
            eyeWaitLogged = false
            eyeActiveSeconds = 0
            EyeBreak.shared.blinkTarget = config.eyeBlinks; EyeBreak.shared.maxSeconds = config.eyeMaxSeconds
            EyeBreak.shared.show(seconds: config.eyeSeconds, statement: config.eyeSkipStatement) { skipped in
                let how = EyeBreak.shared.lastBlinks.map { "\($0) blinks counted" } ?? "\(self.config.eyeSeconds) s looking away (no blink count)"
                Store.shared.event("eye_break", skipped ? "skipped by typing the statement" : how)
            }
            return true
        }
    }

    /// The one definition of "in a call" (B5), shared by the break blocker, the 20-20-20 and the
    /// clean slate: a calendar meeting within `calendarBuffer` min, Zoom's own in-meeting process
    /// (both hard signals), or a camera / meeting window (`soft`: trusted for a limited time).
    func liveCall(calendarBuffer: Double) -> (why: String, soft: Bool)? {
        if let t = CalendarBridge.shared.meetingNearby(bufferMinutes: calendarBuffer) {
            return (calendarBuffer > 0 ? "'\(t)' is within \(Int(calendarBuffer)) min" : "'\(t)' on the calendar", false)
        }
        if ZoomGuard.inMeeting() { return ("You're in a Zoom call", false) }
        return MeetingDetector.activeCall().map { ($0, true) }
    }

    /// Why a due break must wait, or nil. Soft signals can defer it for `config.maxDeferralMinutes`, then rest wins.
    /// The switch meter: every minute, count app switches in the last window; a burst brings one
    /// gentle card (SwitchRule). Never locks; logged as switch_burst so reviews can test whether
    /// hopping predicts the next morning.
    private func maybeSwitchNudge() {
        guard -lastSwitchCheck.timeIntervalSinceNow >= 60 else { return }
        lastSwitchCheck = Date()
        let window = config.switchWindowMinutes * 60
        recentSwitches = Store.shared.appSwitches(from: Date().addingTimeInterval(-window), to: Date())
        guard recentSwitches >= config.switchThreshold, config.switchThreshold > 0 else { return }   // cheap path first
        guard SwitchRule.shouldNudge(switches: recentSwitches, threshold: config.switchThreshold, secondsSinceLastNudge: -lastSwitchNudge.timeIntervalSinceNow,
                                     cooldown: config.switchCooldownMinutes * 60, paused: Control.load().isPaused,
                                     inCall: liveCall(calendarBuffer: 0) != nil, late: isLateEvening) else { return }
        lastSwitchNudge = Date()
        Store.shared.event("switch_burst", "\(recentSwitches) app switches in \(Int(config.switchWindowMinutes)) min")
        let n = Store.shared.countEvents(kind: "switch_burst", since: Day.today)
        Card.shared.showNudge(Voice.pick(["🔀 \(recentSwitches) switches in \(Int(config.switchWindowMinutes)) min", "🔀 Lots of hopping: \(recentSwitches) in \(Int(config.switchWindowMinutes)) min", "🔀 \(recentSwitches) app changes just now"], n),
                              reason: Voice.pick(["That much hopping is its own load. Pick one thing for the next few minutes?",
                                                  "Each switch reloads your head. One thing until the next break?",
                                                  "If you're waiting on Claude, the wait can be eyes-closed instead of another app."], n), seconds: 20)
    }

    /// The morning Whoop reading, fetched by the app itself (Oct 25): the scheduled task only runs
    /// while the Claude app is open, and 16 of 33 mornings had no reading. From `morningHour` to 1 pm,
    /// while you're at the computer and today's reading is missing, try every 30 min.
    private func maybeFetchWhoop() {
        guard !whoopFetching, !Baseline.load().isToday, hourNow >= capacity.morningHour, hourNow < 13,
              -lastWhoopTry.timeIntervalSinceNow >= 30 * 60 else { return }
        lastWhoopTry = Date(); whoopFetching = true
        WhoopFetch.run { [weak self] r in
            self?.whoopFetching = false
            switch r {
            case .ok(let rec): Store.shared.event("whoop_fetch", "recovery \(rec), fetched by the app")
            case .notScoredYet: break
            case .failed(let why):
                Store.shared.event("whoop_fetch", "failed: \(why)")
                if why.contains("authenticate"), Store.shared.lastEvent(kind: "signin_card", since: Day.today) == nil {
                    Store.shared.event("signin_card", "Claude CLI signed out")
                    Card.shared.ask("I can't reach Whoop 🔑", body: "The Claude sign-in on this Mac expired, so the Whoop reading, the nightly sheet sync and the daily notice are all paused. In Terminal: claude, then /login with your personal account. Or ask Claude in chat.",
                                    buttons: [("Got it", {})], seconds: 600, tag: "Sign-in", onTimeout: {})
                }
            }
        }
    }

    /// One observation a day (Insight): after today's Whoop is in (or from 11 am without it), once,
    /// shown between breaks with 👍 / 👎. Up to 3 tries a day if Claude can't be reached.
    private func maybeInsight() {
        if let p = pendingInsight, breakUntil == nil, !LockScreen.shared.isShowing {
            pendingInsight = nil; showInsight(p.text, p.evidence); return
        }
        guard config.insightsOn, !insightRunning, hourNow >= capacity.morningHour, hourNow < 21,
              Baseline.load().isToday || hourNow >= 11,
              Store.shared.lastEvent(kind: "insight", since: Day.today) == nil,
              Store.shared.lastEvent(kind: "insight_none", since: Day.today) == nil,
              Store.shared.countEvents(kind: "insight_failed", since: Day.today) < 3,
              (Store.shared.lastEvent(kind: "insight_failed", since: Day.today)?.0.timeIntervalSinceNow ?? -9999) < -1800 else { return }
        insightRunning = true
        Insight.run { [weak self] r in
            guard let self = self else { return }
            self.insightRunning = false
            switch r {
            case .ok(let t, let e):
                Store.shared.event("insight", t + (e.isEmpty ? "" : " [evidence: \(e)]"))
                self.pendingInsight = (t, e)
            case .nothing: Store.shared.event("insight_none", "nothing worth saying today")
            case .failed(let why): Store.shared.event("insight_failed", why)
            }
        }
    }

    private func showInsight(_ text: String, _ evidence: String) {
        let n = Store.shared.countEvents(kind: "insight", since: Day.today.addingTimeInterval(-30 * 86400))
        let title = Voice.pick(["One thing I noticed 🔎", "Something in your numbers 🔎", "A pattern worth a look 🔎", "From the last few weeks 🔎"], n)
        let short = String(text.prefix(60))
        Card.shared.ask(title, body: text + (evidence.isEmpty ? "" : "\n\n" + evidence),
                        buttons: [("👍 Useful", { Store.shared.event("insight_feedback", "useful | \(short)") }),
                                  ("👎 Not useful", { Store.shared.event("insight_feedback", "not useful | \(short)") })],
                        seconds: 900, tag: "Noticed", onTimeout: {})
    }

    /// Rest first, then one small start (the user chose the lie-down as the first option).
    private func avoidCard(_ text: String, _ top: String?) {
        let n = Store.shared.countEvents(kind: "avoid_callout", since: Day.today.addingTimeInterval(-14 * 86400))
        Card.shared.ask(Voice.pick(["Avoiding something? 🫖", "Maybe tired? 🫖", "A pattern I've learned 🫖"], n), body: text,
                        buttons: [("🛏️ Lie down 15 min", { [weak self] in
                                      Store.shared.event("avoid_choice", "lie down")
                                      guard let self = self else { return }
                                      let rest = Activity.catalog["rest"]!
                                      let a = Activity(key: "rest", title: "Lie down", emoji: "🛏️", minutes: 15, load: "none", instructions: rest.instructions, minTier: "red")
                                      let plan = BreakPlan(activity: a, headline: "Rest first 🛏️", reason: text, acknowledgement: nil, unlock: nil, alternatives: [], hrCeiling: nil)
                                      self.currentPlan = plan
                                      self.startBreak(until: Date().addingTimeInterval(15 * 60), title: plan.headline, reason: "You chose to lie down: " + text, plan: plan)
                                  }),
                                  ("✉️ Just one reply", {
                                      Store.shared.event("avoid_choice", "one reply\(top.map { " (\($0))" } ?? "")")
                                      if let t = top, let app = NSWorkspace.shared.runningApplications.first(where: { ($0.localizedName ?? "").localizedCaseInsensitiveContains(t) || t.localizedCaseInsensitiveContains($0.localizedName ?? "~") }) {
                                          if let id = app.bundleIdentifier { AppGate.shared.allow(id) }
                                          app.activate()
                                      }
                                  }),
                                  ("I'm fine", { Store.shared.event("avoid_choice", "fine") })],
                        seconds: 900, tag: "Noticed", onTimeout: {})
    }

    /// Sheet sync from the app (see SheetSync): tonight's day from `sheetSyncHour`, yesterday's in the
    /// morning if it was missed; the morning backup once a day after the Whoop reading. One run at a
    /// time, 45 min between retries, 3 tries per day for each.
    private func maybeSync(_ control: Control) {
        let sheet = config.sheetSyncId
        guard !sheet.isEmpty, !syncRunning else { return }
        let now = Date(), hm = Double(hourNow) + Double(Calendar.current.component(.minute, from: now)) / 60
        let synced: (String) -> Bool = { day in Store.shared.eventDetails(kind: "sheet_sync", since: Day.today.addingTimeInterval(-86400)).contains { $0.hasPrefix(day) } }
        let today = Day.string(now), yesterday = Day.string(now.addingTimeInterval(-86400))
        var target: String?, manual = false
        if control.syncNow { var c = control; c.syncNow = false; saveJSON(c, to: Control.file); target = today; manual = true; lastSyncTry = .distantPast }
        else if hm >= config.sheetSyncHour, !synced(today) { target = today }
        else if hourNow >= capacity.morningHour, hourNow < 13, !synced(yesterday) { target = yesterday }
        if let day = target {
            guard -lastSyncTry.timeIntervalSinceNow > 45 * 60 || control.syncNow,
                  Store.shared.eventDetails(kind: "sheet_sync_failed", since: Day.today).filter({ $0.hasPrefix(day) }).count < 3 else { return }
            syncRunning = true; lastSyncTry = now
            SheetSync.nightly(day: day, sheet: sheet) { [weak self] r in
                self?.syncRunning = false
                switch r {
                // A manual run doesn't count as the night's: tonight's still runs with the full day.
                case .ok(let line): Store.shared.event("sheet_sync", (manual ? "manual " : "") + "\(day): \(line)")
                case .failed(let why): Store.shared.event("sheet_sync_failed", "\(day): \(why)")
                }
            }
            return
        }
        // Morning backup: once a day, after today's Whoop is in (or from 10 am).
        guard hourNow >= capacity.morningHour, hourNow < 15, Baseline.load().isToday || hourNow >= 10,
              Store.shared.lastEvent(kind: "morning_sync", since: Day.today) == nil,
              Store.shared.countEvents(kind: "morning_sync_failed", since: Day.today) < 3,
              -lastSyncTry.timeIntervalSinceNow > 45 * 60 else { return }
        syncRunning = true; lastSyncTry = now
        SheetSync.morning(sheet: sheet) { [weak self] r in
            self?.syncRunning = false
            switch r {
            case .ok(let s): Store.shared.event("morning_sync", s)
            case .failed(let why): Store.shared.event("morning_sync_failed", why)
            }
        }
    }

    /// Micro stretch (MicroRule): every `microEveryMinutes` of focused time, a 10-s camera-checked stand +
    /// reach (seated on red days), with a small heads-up 20 s before. Skipped quietly without a camera.
    private func maybeMicroMove() -> Bool {
        let every = config.microEveryMinutes * 60
        guard every > 0 else { return false }
        let blocked = isLateEvening || liveCall(calendarBuffer: 0) != nil
        let blockLeft = Double(blockMinutes) * 60 - blockActiveSeconds
        let eyeIn = config.eyeEveryMinutes > 0 ? config.eyeEveryMinutes * 60 - eyeActiveSeconds : 9999
        if !microNudged, microActiveSeconds >= every - 20, microActiveSeconds < every,
           MicroRule.due(active: every, every: every, blockRemaining: blockLeft - 20, eyeIn: eyeIn - 20, blocked: blocked) {
            microNudged = true
            Card.shared.showNudge("🧍 Micro stretch in 20 sec", reason: "10 seconds standing with your arms up, then straight back.", seconds: 12)
        }
        guard microActiveSeconds >= every else { return false }
        if blockLeft < 180 { microActiveSeconds = 0; microNudged = false; return false }   // the regular break covers it
        guard MicroRule.due(active: microActiveSeconds, every: every, blockRemaining: blockLeft, eyeIn: eyeIn, blocked: blocked) else { return false }
        let needStand = tier != "red"
        microActiveSeconds = 0; microNudged = false
        let shown = MicroMove.shared.show(hold: config.microHoldSeconds, needStand: needStand, statement: config.microSkipStatement) { outcome, held in
            Store.shared.event("micro_move", "\(outcome) (\(Int(held)) s held\(needStand ? "" : ", seated, red day"))")
        }
        if !shown { Store.shared.event("micro_move", "no camera, skipped") }
        return shown
    }

    /// A workout counted on the phone page (Oct 26: the iPhone as a Mac camera didn't connect). Same
    /// effect as the Mac's own count: logged, and on a workout break it completes it (-2 min).
    func phoneWorkout(done: Bool, summary: String) {
        // The Mac may have finished the same workout a moment ago (the phone follows it): log it once.
        let justLogged = (Store.shared.lastEvent(kind: "workout", since: Date().addingTimeInterval(-60))?.0) != nil
        if !justLogged || WorkoutSession.shared.isShowing { Store.shared.event("workout", (done ? "done: " : "stopped: ") + summary + " (counted on the phone)") }
        // The phone finishing closes the Mac's workout screen too (Oct 27: a lost rep left it waiting at 9/10).
        if done, !workoutPending, WorkoutSession.shared.isShowing { WorkoutSession.shared.dismiss() }
        guard workoutPending else { return }
        workoutPending = false; WorkoutSession.shared.dismiss(); LockScreen.shared.setMove(nil)
        if done, let u = breakUntil { breakUntil = max(Date(), u.addingTimeInterval(-120)); saveBreakState() }
        if done { LockScreen.shared.showMoveDone("✓ Workout counted on your phone · 2 min off") }
    }

    /// The counted workout. In a break it holds the break's end and takes 2 min off when done.
    @discardableResult private func startWorkout(inBreak: Bool, tryReps: Int = 0, snackIndex: Int? = nil) -> Bool {
        // The set follows the place (Oct 26): lying-down at home and at the parents', standing at the office.
        let standing = contexts.active.workout == "standing"
        let steps = snackIndex.map { WorkoutSession.snack(place: contexts.active.workout ?? "lying", index: $0, reps: standing ? config.workoutStandingReps : config.workoutBridges, clamReps: config.workoutClamshells) } ?? (standing ? WorkoutSession.standing(reps: tryReps > 0 ? tryReps : config.workoutStandingReps)
            : tryReps > 0 ? WorkoutSession.steps(bridges: tryReps, clamshells: tryReps, pauseSeconds: 10)
                          : WorkoutSession.steps(bridges: config.workoutBridges, clamshells: config.workoutClamshells))
        let ok = WorkoutSession.shared.show(steps: steps, statement: config.workoutStopStatement, promise: config.workoutPromiseOn) { [weak self] finished, summary in
            guard let self = self else { return }
            Store.shared.event("workout", (finished ? "done: " : "stopped: ") + summary + (inBreak ? "" : " (asked for in chat)"))
            if inBreak, self.workoutPending {
                self.workoutPending = false; LockScreen.shared.setMove(nil)
                if finished, let u = self.breakUntil { self.breakUntil = max(Date(), u.addingTimeInterval(-120)); self.saveBreakState() }
            }
        }
        if ok { Store.shared.event("workout_started", inBreak ? "exercise snack \((snackIndex ?? 0) + 1) of \(config.workoutSnacksPerDay): " + steps.filter { $0.kind != "pause" }.map(\.title).joined(separator: ", ") : "asked for in chat"); if inBreak { workoutPending = true } }
        else { Store.shared.event("workout_started", WorkoutSession.shared.isShowing ? "already open" : "no Mac camera: skipped (the phone page still works)") }
        return ok
    }

    /// Start the eye break right now (the same screen and logging as the regular one).
    private func maybeEyeBreakNow() -> Bool {
        eyeActiveSeconds = 0; eyeWaitLogged = false
        EyeBreak.shared.blinkTarget = config.eyeBlinks; EyeBreak.shared.maxSeconds = config.eyeMaxSeconds
        EyeBreak.shared.show(seconds: config.eyeSeconds, statement: config.eyeSkipStatement) { skipped in
            let how = EyeBreak.shared.lastBlinks.map { "\($0) blinks counted" } ?? "\(self.config.eyeSeconds) s looking away (no blink count)"
            Store.shared.event("eye_break", (skipped ? "skipped by typing the statement" : how) + " (asked for in chat)")
        }
        return true
    }

    private func meetingBlocker() -> String? {
        guard let call = liveCall(calendarBuffer: config.zoomBufferMinutes) else { return nil }
        if call.soft, let since = breakDeferredSince, -since.timeIntervalSinceNow > config.maxDeferralMinutes * 60 {
            Store.shared.event("deferral_cap", "\(call.why), but the break has waited \(Int(config.maxDeferralMinutes)) min with no calendar meeting — resting anyway")
            return nil
        }
        return call.why
    }

    // MARK: - Breaks

    /// Step the lock aside for a meeting: hide it now, bring it back after the meeting if
    /// there's time left on it. A short break just counts as taken.
    private func suspendLock(for m: EKEvent, until: Date) {
        let (resume, long) = MeetingRule.resumesAfter(meetingEnd: m.endDate, lockUntil: until, dayLocked: dayLocked)
        pendingLock = long ? (until, lastLock.title, lastLock.reason) : nil
        let wasDay = dayLocked
        LockScreen.shared.hide()
        if workoutPending { WorkoutSession.shared.dismiss() }; workoutPending = false
        movePending = nil; MoveCounter.shared.stop(); LockScreen.shared.setMove(nil)
        clearBreakState()
        breakUntil = nil; awaitingCompletion = false; phoneAsking = false; nightBreak = false; currentPlan = nil; blockActiveSeconds = 0; eyeActiveSeconds = 0; nudged = false
        dayLocked = wasDay
        suspendedUntil = resume
        Store.shared.event("lock_suspended", "'\(m.title ?? "Meeting")' at \(Day.clock(m.startDate)): lock off until \(Day.clock(resume))" + (long ? ", then back" : ""))
        Card.shared.showNudge("Go to your meeting 👋", reason: "'\(m.title ?? "Meeting")' starts at \(Day.clock(m.startDate)). The screen's yours until it ends" + (long ? "; the rest of the lock comes back after." : "."), seconds: 30)
    }

    private func startBreak(until requested: Date, title: String, reason requestedReason: String, plan: BreakPlan? = nil, resumed: Bool = false) {
        // Fit a regular break around the calendar: end it 5 min before the next meeting.
        // Longer locks (an hour off, the cap, night) aren't trimmed: they step aside for the
        // meeting and come back after it (suspendLock).
        var until = requested, reason = requestedReason
        if let m = CalendarBridge.shared.nextMeeting(startingBefore: requested.addingTimeInterval(5 * 60)),
           let cut = MeetingRule.trimmedEnd(requested: requested, now: Date(), dayLocked: dayLocked, nextMeetingStart: m.startDate) {
            until = cut
            reason += " (Shortened so you're free for '\(m.title ?? "your meeting")' at \(Day.clock(m.startDate)).)"
            Store.shared.event("break_fit", "Break ends \(Day.clock(cut)) for '\(m.title ?? "meeting")'")
        }
        lastLock = (title, reason)
        AppGate.shared.end()   // a new break ends the last block's app list
        breakUntil = until; breakDeferredSince = nil; breakStartedAt = Date(); awaitingCompletion = false
        Card.shared.hide()
        if resumed { Store.shared.event("break_resumed", "Back to the break that was running (until \(Day.clock(until))) after a restart") }
        else { Store.shared.event("break_start", reason) }
        if !resumed { Store.shared.event("block_switches", "\(Store.shared.appSwitches(from: Date().addingTimeInterval(-max(blockActiveSeconds, 60)), to: Date()))|\(Int(blockActiveSeconds / 60))") }   // switches|focused minutes, for reviews
        if !resumed { CleanSlate.shared.lockStarted(minutes: until.timeIntervalSinceNow / 60, config: config) }
        LockScreen.shared.onChoose = { [weak self] a in
            guard let self = self, var p = self.currentPlan else { return }
            p.activity = a; self.currentPlan = p
            let wanted = self.breakStartedAt.addingTimeInterval(Double(a.minutes) * 60)
            if wanted > (self.breakUntil ?? wanted) { self.breakUntil = wanted; self.saveBreakState() }
            // The tap redraws the lock screen, which clears any "How did that go?" buttons.
            // Re-arm so the next tick shows the countdown again, or asks again if time is up.
            self.awaitingCompletion = false
            Store.shared.event("break_choice", "\(a.key)|\(a.load)|chosen from the alternatives")
        }
        LockScreen.shared.rewardsOn = !nightBreak && !dayLocked && Rewards.eligible(breakMinutes: until.timeIntervalSinceNow / 60)
        LockScreen.shared.onReward = { [weak self] t in
            guard let self = self, let u = self.breakUntil else { return }
            // One minute off the wait, never past now; the countdown shows it on the next tick.
            self.breakUntil = max(Date(), u.addingTimeInterval(-60)); self.saveBreakState()
            Store.shared.event("reward", "\(t.key)|\(Rewards.dollars)|\(t.title): $\(Rewards.dollars), one minute off the break")
        }
        LockScreen.shared.show(title: title, reason: reason, plan: plan, extra: careLine())
        // Every regular break starts with a checked stretch (not night breaks, locks or hours off).
        let snacks = Store.shared.eventDetails(kind: "workout_started", since: Day.today).filter { $0.hasPrefix("exercise snack") }.count
        let wasWorkout = lastBreakHadWorkout; lastBreakHadWorkout = false
        if config.workoutOn, plan != nil, !nightBreak, !dayLocked, !resumed,
           WorkoutRule.due(hour: hourNow, afterHour: config.workoutAfterHour, tier: tier, snacksToday: snacks, perDay: config.workoutSnacksPerDay,
                           lastBreakWasWorkout: wasWorkout, place: contexts.active.workout),
           startWorkout(inBreak: true, snackIndex: snacks) {
            lastBreakHadWorkout = true
            // the workout is this break's movement
        } else if config.moveCheckOn, plan != nil, !nightBreak, !dayLocked, !resumed {
            let needStand = tier != "red"
            let ok = MoveCounter.shared.start(needStand: needStand)
            movePending = (until.timeIntervalSinceNow, needStand, Date(), 0, ok)
            MoveCounter.shared.onUpdate = { [weak self] held, posed, coach in self?.movePending?.held = held; self?.movePosed = posed; self?.moveCoach = coach }
            LockScreen.shared.moveFigure.needStand = needStand
            MoveCounter.shared.onJoints = { j in LockScreen.shared.moveFigure.joints = j }
        }
        if !resumed { saveBreakState() }
    }

    /// The phone asked to unlock while a lock is showing: type a reason and the statement
    /// (user, Oct 3), and it opens (a pause of `minutes`) only once a reason is tapped. Returns false if no lock is up.
    func askPhoneUnlockReason(minutes: Int) -> Bool {
        guard breakUntil != nil, !awaitingCompletion else { return false }
        phoneAsking = true          // keeps the countdown from overwriting the question (until the break's time is up)
        Store.shared.event("phone_unlock_asked", "Phone tap during a lock; asking for a reason")
        let st = Statements.pick(Statements.unlock, last: lastUnlockStatement, roll: Int.random(in: 0..<1000), time: Day.clock(Date()))
        lastUnlockStatement = st.index
        LockScreen.shared.askTyped(question: "Unlocking from your phone.", statement: st.text) { [weak self] reason in
            self?.phoneAsking = false
            var c = Control.load()
            c.pauseUntil = Date().addingTimeInterval(Double(minutes) * 60); c.reason = "iPhone unlock: \(reason)"
            saveJSON(c, to: Control.file)
            Store.shared.event("override", "iPhone unlock: \(reason) (\(minutes) min)")
        }
        return true
    }

    /// After "how did that go": the break screen releases right away, and the 1–10
    /// questions pop up as the top-right card. Nothing waits on them.
    private func askSymptomsThenEnd(outcome: String) {
        // The app picker comes between "How did that go?" and the release (user, Oct 24).
        let apps = config.appGateOn ? AppGate.catalog(config: config) : []
        if !apps.isEmpty {
            LockScreen.shared.askApps(apps) { [weak self] picked in
                guard let self = self else { return }
                self.endBreakAndAsk(outcome: outcome)
                AppGate.shared.begin(picked, config: self.config)
            }
            return
        }
        endBreakAndAsk(outcome: outcome)
    }

    private func endBreakAndAsk(outcome: String) {
        endBreak(reason: "break complete", outcome: outcome)
        let n = Store.shared.countEvents(kind: "break_done", since: Day.today)
        HotCorner.shared.presentAfterBreak(title: Voice.pick(["How was that break? 🙂", "Quick numbers, if you like 💛", "How's the head after that?", "A quick receipt for that block:"], n))
    }

    /// Short description of where the day stands, stored with after-break answers.
    func loadContext() -> String { "after break, \(Int(usedToday()))/\(Int(capToday().minutes)) min, block \(blockMinutes)" }

    /// The symptom gate, on 1–10 (10 = best). Runs after every after-break card and every
    /// corner check. Only `capacity.gateKeys` count (clear, head, not crashing; energy and
    /// overall are logged, never gated). Each is compared with its first answer today.
    ///   anything else                  → the next block gets a little longer or shorter (adaptBlock)
    ///   down `softenDropBy`            → shortest blocks and rest-only breaks for the day
    ///   down `gateDropBy`, or ≤ floor  → an hour off (`gateRestMinutes`), then back to work
    ///   the `gateStopsForDay`-th time  → done for the day
    func applyGate(_ now: [String: Int]) {
        guard !dayLocked, breakUntil == nil else { return }
        let readings = Store.shared.symptomReadings(day: Date()).map { $0.1 }
        let labels = Dictionary(uniqueKeysWithValues: Questions.all.map { ($0.0, $0.1.lowercased()) })
        let outcome = GateRule.evaluate(now: now, readings: readings, keys: capacity.gateKeys, labels: labels,
                                        dropBy: capacity.gateDropBy, floor: capacity.gateFloor, softenBy: capacity.softenDropBy, softened: softened,
                                        priorRests: Store.shared.countEvents(kind: "gate_asked", since: Day.today), stopsForDay: capacity.gateStopsForDay)
        // Numbers never lock on their own (user, Oct 10: "I sometimes lie on my check-in … I want to
        // be able to record a 5 and still be able to work"). A big drop asks, recommending rest; the
        // answer is logged so reviews can see what each choice cost the next day. Keep working =
        // shortest blocks and plain-rest breaks for the rest of today.
        switch outcome {
        case .stop(let trigger, let moved, let stops):
            let reason = "Your numbers: \(moved) (\(trigger)). That's the \(stops == 2 ? "second" : "\(stops)th") time today. My recommendation: stop here, the reading that matters is the morning after tomorrow. \(capacity.experimentLabel)."
            askGate(title: "Call it a day? 💛", reason: reason, restLabel: "Done for today", kind: "stop") { [weak self] in
                guard let self = self else { return }
                Store.shared.event("gate_stop", reason); Store.shared.event("day_lock", reason)
                self.dayLocked = true; self.currentPlan = nil
                self.startBreak(until: self.tomorrowMorning(), title: "That's today, by your own numbers 💛", reason: reason)
            }
        case .rest(let trigger, let moved):
            let reason = "Your numbers: \(moved) (\(trigger)). Energy doesn't count toward this; clear, head and crashing do. My recommendation: an hour off, then you're back. \(capacity.experimentLabel)."
            askGate(title: "Rest for an hour? 🛏️", reason: reason, restLabel: "Rest an hour", kind: "rest") { [weak self] in
                guard let self = self else { return }
                Store.shared.event("gate_rest", reason)
                self.currentPlan = nil
                self.startBreak(until: Date().addingTimeInterval(Double(self.capacity.gateRestMinutes) * 60), title: "An hour off, by your own numbers 💛", reason: reason)
            }
        case .soften(let drop, let moved):
            softened = true
            Store.shared.event("gate_soften", "Down \(drop) from this morning (\(moved)): blocks drop to \(capacity.blockMin) min and breaks are plain rest for the rest of today.")
        case .adapt:
            adaptBlock(now, readings: readings)
        }
    }

    /// The gate's question card. Rest = the lock, as before. Keep working (or no answer in 10 min,
    /// e.g. you walked away) = no lock, shortest blocks and plain rest for today, logged as declined.
    private func askGate(title: String, reason: String, restLabel: String, kind: String, rest: @escaping () -> Void) {
        let keepGoing: (String) -> Void = { [weak self] how in
            guard let self = self else { return }
            Store.shared.event("gate_declined", "\(kind): \(how). \(reason)")
            if !self.softened {
                self.softened = true
                Store.shared.event("gate_soften", "Kept working after a drop: blocks \(self.capacity.blockMin) min and plain-rest breaks for the rest of today.")
            }
        }
        Store.shared.event("gate_asked", "\(kind): \(reason)")
        Card.shared.ask(title, body: reason + "\n\nYour numbers stay as you gave them either way. Keep working = \(capacity.blockMin)-min blocks and plain rest for today.",
                        buttons: [(restLabel, rest), ("Keep working", { keepGoing("chose to keep working") })],
                        seconds: 600, tag: "Your call", onTimeout: { keepGoing("no answer in 10 min") })
    }

    private func endBreak(reason: String, outcome: String) {
        LockScreen.shared.hide()
        let wasNight = nightBreak; nightBreak = false
        let plan = currentPlan
        if workoutPending { WorkoutSession.shared.dismiss() }; workoutPending = false
        movePending = nil; MoveCounter.shared.stop(); LockScreen.shared.setMove(nil)
        clearBreakState()
        breakUntil = nil; blockActiveSeconds = 0; eyeActiveSeconds = 0; nudged = false; awaitingCompletion = false; phoneAsking = false; currentPlan = nil
        if plan?.activity.minutes ?? 0 >= capacity.longRestMinutes && plan?.activity.load == "none" { activeSinceLongRest = 0; Store.shared.event("long_rest_done", "\(plan?.activity.minutes ?? 0) min") }
        if dayLocked && (outcome == "day" || outcome == "paused") { dayLocked = false } // new day, or Claude paused it: re-evaluate afterwards
        Store.shared.event("break_end", reason)
        if !dayLocked, outcome != "day", !wasNight {   // late-night breaks aren't logged one by one
            let key = plan?.activity.key ?? "rest"
            let done = outcome == "did" ? key : outcome == "rested" ? "rest" : "skipped"
            Store.shared.event("break_done", "\(done)|\(plan?.activity.load ?? "none")|\(outcome)")
            CalendarBridge.shared.writeBreakEvent(from: breakStartedAt, to: Date(), activity: done == "rest" ? Activity.catalog["rest"]! : (Activity.catalog[done] ?? plan?.activity), outcome: outcome)
        }
        maybeDayClose()
    }

    private func countdown(_ until: Date) -> String {
        let s = max(0, Int(until.timeIntervalSinceNow))
        return s > 3600 ? "until morning" : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Once-a-day cards

    /// Care reminders ride on the break screen, never as their own alert.
    private func careLine() -> String? {
        let now = Date()
        let h = Calendar.current.component(.hour, from: now), m = Calendar.current.component(.minute, from: now)
        let t = Double(h) + Double(m) / 60
        // Once a day each, softly worded (Oct 26: "you almost always say you haven't stepped away since 11";
        // it repeated on every break and asserted what it couldn't know).
        let shown = Store.shared.eventDetails(kind: "care_line", since: Day.today)
        if !mealBreakSeen && t >= 11.5 && t <= 14.5 && !shown.contains("meal") {
            Store.shared.event("care_line", "meal")
            return Voice.pick(["🍽️ If you haven't eaten yet, now's a good time.", "🍽️ Lunch, if it hasn't happened.", "🍽️ A good moment for food, if you're due."], h)
        }
        if t >= 14.5 && t <= 18 && !shown.contains("water") {
            Store.shared.event("care_line", "water")
            return Voice.pick(["💧 Some water while you're up.", "💧 A glass of water on the way back.", "💧 Water, if the bottle's low."], h)
        }
        return nil
    }

    func daySummary() -> String {
        let l = todayLoad()
        let top = l.byCategory.filter { $0.key != "leisure" }.sorted { $0.value > $1.value }.prefix(3).map { "\(Int($0.value))m \($0.key)" }
        let breaks = Store.shared.countEvents(kind: "break_start", since: Day.today)
        return "\(Int(l.weighted)) weighted min (\(top.joined(separator: ", "))), \(Int(l.meeting)) min of meetings, \(breaks) rests taken."
    }

    private func maybeHorizontalPrompt() {
        guard meetingMinutesToday() >= 60, -lastHorizontalPrompt.timeIntervalSinceNow > 2 * 3600,
              blockActiveSeconds < 5 * 60, meetingBlocker() == nil else { return }
        lastHorizontalPrompt = Date()
        let why = "\(Int(meetingMinutesToday())) min of meetings today. Upright time costs energy on its own, so 10 min flat now buys back the afternoon."
        Card.shared.showNudge("Lie down for 10 minutes? 🛏️", reason: why, seconds: 40)
        Store.shared.event("horizontal_prompt", why)
    }

    // MARK: - Morning briefing: how today will run, shown at the first activity of the day

    private let briefTitles = ["Good morning 🌤️ Here's today", "Here's how today will run ☀️", "Today's plan, before you start 🌱", "Morning 💛 Here's the shape of today"]

    /// The plan in plain words, from the same numbers the engine uses.
    func todayPlanText() -> String {
        let t = tier, b = Baseline.load()
        let (cap, capWhy) = capToday()
        let used = usedToday()
        var lines: [String] = []
        if b.isToday, let r = b.recovery {
            lines.append("🩺 Whoop \(r) → \(t). Resting HR \(b.restingHR ?? 0), sleep \(String(format: "%.1f", b.sleepHours ?? 0)) h.")
        } else {
            lines.append("🩺 No Whoop reading yet, so I'm treating today as yellow. I'll tell you if that changes.")
        }
        let (start, startWhy) = startingBlock()
        lines.append("⏱️ Blocks start at \(start) min" + (startWhy.isEmpty ? "" : " (\(startWhy.joined(separator: "; ")))") + (blockLen.map { $0 != start ? ", now \($0) min" : "" } ?? "") + ". Each how-are-you card moves the next one \(capacity.blockStep) min up or down (\(capacity.blockMin)–\(capacity.blockMax)).")
        lines.append("🌙 \(restMinutes)-min breaks between blocks, and a \(capacity.longRestMinutes)-min lie-down every \(capacity.longRestEveryMinutes / 60) h.")
        lines.append("📊 Cap: \(String(format: "%g", cap / 60)) h on the computer" + (used > 1 ? ", \(Int(used / 60)) h \(Int(used) % 60) min used" : "") + (capWhy.isEmpty ? "" : " (\(capWhy.joined(separator: "; ")))") + ".")
        let m = CalendarBridge.shared.meetingsScheduledToday()
        if m.count > 0 { lines.append("📅 \(m.count) video meeting\(m.count == 1 ? "" : "s") on the calendar (~\(Int(m.minutes)) min).") }
        let acts = contexts.active.activities.compactMap { Activity.catalog[$0] }
            .filter { $0.load != "none" && Tier.rank[$0.minTier]! <= Tier.rank[t]! }.prefix(5)
        if !acts.isEmpty { lines.append("🧘 Breaks can include: " + acts.map { "\($0.emoji) \($0.title.lowercased())" }.joined(separator: ", ") + (b.hrCeiling.map { ". HR ceiling \($0)." } ?? ".")) }
        else { lines.append("🌙 Breaks today are rest and music.") }
        if let ad = adaptLine() { lines.append(ad) }
        lines.append("🔢 If clear, head or not-crashing drops \(capacity.gateDropBy) from this morning, or hits \(capacity.gateFloor), you get an hour off; a second time ends the day. Energy never locks you.")
        lines.append("🔬 \(capacity.experimentLabel) · clean-day streak \(capacity.cleanStreak) of \(capacity.cleanDaysToStepUp).")
        return lines.joined(separator: "\n")
    }

    /// After an exercise session is logged (from Whoop), the work day adapts once:
    ///   any session       → the next break is the long lie-down (recovery first)
    ///   a hard one        → the rest of the day is softened (shortest blocks, plain rest)
    /// "Hard" = max heart rate over the plan's cap, average above the zone, or 1.5× the minutes.
    private func maybeReactToWorkout() {
        guard -lastWorkoutCheck.timeIntervalSinceNow > 120 else { return }
        lastWorkoutCheck = Date()
        guard Store.shared.lastEvent(kind: "workout_reacted", since: Day.today) == nil,
              let s = Store.shared.adaptSessionsToday().max(by: { $0.minutes < $1.minutes }),
              let plan = lenientLoad(AdaptPlan.file, defaults: AdaptPlan()) else { return }
        activeSinceLongRest = Double(capacity.longRestEveryMinutes) * 60   // next break = the long lie-down
        var why = "\(s.minutes) min of \(s.mode)" + (s.avgHR.map { ", avg \($0)" } ?? "") + (s.maxHR.map { ", max \($0) bpm" } ?? "")
        let hard = (s.maxHR ?? 0) > plan.hardCap || (s.avgHR ?? 0) > plan.zoneHigh || Double(s.minutes) > Double(plan.minutes) * 1.5
        if hard && !softened {
            softened = true
            why += ": harder than the plan (zone \(plan.zoneLow)–\(plan.zoneHigh), cap \(plan.hardCap)), so the rest of today is gentler"
            Store.shared.event("gate_soften", "After today's workout (\(why)): shortest blocks and plain-rest breaks for the rest of today.")
        }
        Store.shared.event("workout_reacted", why + ". Next break is the long lie-down.")
    }

    /// Today's ADaPT plan, one line for the morning card. Nil if there's no plan yet.
    func adaptLine() -> String? {
        guard let plan = lenientLoad(AdaptPlan.file, defaults: AdaptPlan()) else { return nil }
        let days = Store.shared.adaptSessionDays(since: Day.today.addingTimeInterval(-6 * 86400))
        let last = Store.shared.adaptSessionDays(since: Day.today.addingTimeInterval(-60 * 86400)).max()
        let daysOff = last.flatMap { Day.date($0) }.map { Int(Day.today.timeIntervalSince($0) / 86400) }
        if days.contains(Day.string(Date())) { return "🏋️ ADaPT: done for today ✅ Rest up." }
        if let m = lenientLoad(MusePlan.file, defaults: MusePlan()), m.date == Day.string(Date()), !m.workout.isEmpty {
            return "🏋️ ADaPT (Muse's plan): \(m.workout)" + (m.why.isEmpty ? "" : " (\(m.why))")
        }
        let t = plan.today(tier: tier, dipped: softened, hour: hourNow, days: days.count, daysOff: daysOff, doneToday: false)
        return "🏋️ ADaPT (until Muse's plan arrives): \(t.workout) (\(t.why))"
    }

    private func maybeMorningBrief() {
        let start = Day.today
        if let shown = Store.shared.lastEvent(kind: "morning_brief", since: start) {
            // Whoop arrived after the brief: one short update, once.
            if shown.1 == "unknown", tier != "unknown", Store.shared.lastEvent(kind: "brief_update", since: start) == nil {
                let msg = "Recovery \(Baseline.load().recovery ?? 0) → \(tier). Blocks now start at \(startingBlock().minutes) min."
                Store.shared.event("brief_update", msg)
                Card.shared.showNudge("Whoop's in 📈", reason: msg, seconds: 30)
            }
            return
        }
        let n = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        Store.shared.event("morning_brief", tier)
        Card.shared.showBrief(title: Voice.pick(briefTitles, n), body: { [weak self] in self?.todayPlanText() ?? "" })
    }

    private func maybeDayClose() {
        guard !dayCloseShown, hourNow >= 17 else { return }
        dayCloseShown = true
        let summary = daySummary()
        Card.shared.showNudge("Today, closed well 💛", reason: "\(summary) Every rest you took today is tomorrow's headroom.", seconds: 60)
        Store.shared.event("day_close", summary)
    }

    // MARK: - Contexts, hours, days

    private func maybeSwitchContext() {
        guard -lastContextCheck.timeIntervalSinceNow > 60 else { return }
        lastContextCheck = Date()
        contexts = Contexts.load()
        if let m = contexts.manualUntil, m > Date() { return }
        guard let ssid = Contexts.currentSSID() else { return }
        guard let match = contexts.contexts.first(where: { $0.ssids.contains(ssid) }) else {
            askWhere(ssid); return
        }
        guard match.name != contexts.current else { return }
        contexts.current = match.name; contexts.save()
        Store.shared.event("context", "Switched to '\(match.name)' (Wi-Fi: \(ssid))")
    }
    var contextName: String { contexts.active.name }

    /// A Wi-Fi network the app hasn't seen: one card, one tap, remembered (Oct 26). Never asked twice.
    private func askWhere(_ ssid: String) {
        guard !contexts.askedSSIDs.contains(ssid), breakUntil == nil else { return }
        contexts.askedSSIDs.append(ssid); contexts.save()
        let choices = contexts.contexts.filter { $0.name != "elsewhere" }.prefix(5).map { c in
            (c.label ?? c.name.capitalized, { [weak self] in
                guard let self = self else { return }
                var cs = Contexts.load()
                if let i = cs.contexts.firstIndex(where: { $0.name == c.name }) { cs.contexts[i].ssids.append(ssid) }
                cs.current = c.name; cs.save(); self.contexts = cs
                Store.shared.event("context", "Wi-Fi '\(ssid)' is \(c.name) (tapped)")
            })
        }
        let elsewhere: (String, () -> Void) = ("Somewhere else", { [weak self] in
            var cs = Contexts.load(); cs.current = "elsewhere"; cs.save(); self?.contexts = cs
            Store.shared.event("context", "Wi-Fi '\(ssid)': somewhere else")
        })
        Card.shared.ask("Where are you? 📍", body: "New Wi-Fi (\(ssid)). One tap and I'll remember it, so breaks and workouts fit the place.",
                        buttons: Array(choices) + [elsewhere], seconds: 600, tag: "New place", onTimeout: {})
    }

    private func writeHourIfNeeded() {
        let h = Calendar.current.component(.hour, from: Date())
        guard h != lastHourWritten else { return }
        lastHourWritten = h
        let end = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
        CalendarBridge.shared.writeHourSummary(from: end.addingTimeInterval(-3600), to: end)
        // The exact numbers the budget used, for `supervisionctl daily-json` (weighted|focused|meeting).
        let l = todayLoad()
        Store.shared.event("day_load", "\(Int(l.weighted))|\(Int(l.focused))|\(Int(l.meeting))|\(Int(l.screen))")   // screen = what the 8 h cap counts
    }

    private func rolloverDayIfNeeded() {
        let today = Day.today
        guard today != lastDay else { return }
        lastDay = today; dayLocked = false; dayCloseShown = false; lastHorizontalPrompt = .distantPast
        mealBreakSeen = false; softened = false; blockLen = nil; activeSinceLongRest = 0
        if breakUntil != nil, breakUntil! > Date().addingTimeInterval(3600) { endBreak(reason: "new day", outcome: "day") }
        var c = Control.load(); c.extraBudgetMinutes = 0
        saveJSON(c, to: Control.file)
        evaluateRamp()
    }

    // MARK: - The ramp (docs/DESIGN.md §6): credit clean days at day+2, step up after 3, step down only on patterns

    func evaluateRamp() {
        var cap = Capacity.load()
        let today = Day.today
        // Credit the day two days ago, if not yet credited and its two follow-up mornings are known.
        let d = today.addingTimeInterval(-2 * 86400)
        let dKey = Day.string(d)
        if cap.lastCreditedDay < dKey, let b1 = Store.shared.baseline(day: Day.string(d.addingTimeInterval(86400))), let b2 = Store.shared.baseline(day: Day.string(today)) {
            let median = Store.shared.medianRHR(days: 28) ?? b1.rhr
            let crash = Store.shared.countEvents(kind: "flag_crash", since: d, until: today.addingTimeInterval(86400)) > 0
            let gated = Store.shared.countEvents(kind: "gate_stop", since: d.addingTimeInterval(86400), until: today.addingTimeInterval(86400)) > 0
            let clean = b1.recovery >= 34 && b2.recovery >= 34 && !crash && !gated && b1.rhr <= median + 4 && b2.rhr <= median + 4
            cap.lastCreditedDay = dKey
            if clean {
                cap.cleanStreak += 1
                cap.history.append("\(dKey): clean (recovery \(b1.recovery)/\(b2.recovery) the two mornings after). Streak \(cap.cleanStreak).")
                if cap.cleanStreak >= cap.cleanDaysToStepUp {
                    cap.cleanStreak = 0
                    cap.blockGreen = min(cap.blockMax, cap.blockGreen + cap.stepUpBlockMinutes)
                    cap.blockYellow = min(cap.blockMax - 5, cap.blockYellow + cap.stepUpBlockMinutes)
                    cap.blockRed = min(cap.blockMax - 10, cap.blockRed + cap.stepUpBlockMinutes)
                    cap.experimentNumber += 1
                    cap.experimentStarted = Day.string(today); cap.reviewDate = Day.string(today.addingTimeInterval(14 * 86400))
                    cap.history.append("\(Day.string(today)): 3 clean days → experiment \(cap.experimentNumber): starting blocks \(cap.blockGreen)/\(cap.blockYellow)/\(cap.blockRed).")
                    Store.shared.event("ramp_up", cap.history.last!)
                }
            } else {
                cap.cleanStreak = 0
                cap.history.append("\(dKey): not credited (recovery \(b1.recovery)/\(b2.recovery)\(crash ? ", crash flagged" : "")\(gated ? ", symptom gate fired" : "")). Streak reset, nothing else changes.")
            }
        }
        // Step down only on a pattern.
        let week = today.addingTimeInterval(-7 * 86400)
        var reds = 0, rhrHigh = 0
        let median = Store.shared.medianRHR(days: 28)
        for i in 0..<7 {
            if let b = Store.shared.baseline(day: Day.string(today.addingTimeInterval(-Double(i) * 86400))) {
                if b.recovery < 34 { reds += 1 }
                if let m = median, b.rhr >= m + 5 { rhrHigh += 1 } else { rhrHigh = 0 }
            }
        }
        let crashWeek = Store.shared.countEvents(kind: "flag_crash", since: week, until: today.addingTimeInterval(86400)) > 0
        if (crashWeek || reds >= 2 || rhrHigh >= 3), cap.stepDownUntil < Day.string(today) {
            cap.stepDownUntil = Day.string(today.addingTimeInterval(Double(cap.stepDownDays) * 86400))
            cap.cleanStreak = 0
            let why = crashWeek ? "a crash this week" : reds >= 2 ? "\(reds) red mornings in 7 days" : "resting HR ≥ +5 for 3 days"
            cap.history.append("\(Day.string(today)): step-down (blocks \(cap.blockStep) min shorter) until \(cap.stepDownUntil) because of \(why). Earned back the same way.")
            Store.shared.event("ramp_down", cap.history.last!)
        }
        cap.save(); capacity = cap
    }
}
