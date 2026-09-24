import AppKit

/// The decision-maker. Ticks every 5 s. Every decision it makes is logged with
/// its reason, and the same reason is shown on screen. v2: tiered blocks,
/// weighted budget, symptom gate after each break, 3-day cap, ramp.
final class Engine {
    static let shared = Engine()
    var config = Config.load()
    var capacity = Capacity.load()
    private var timer: Timer?

    private var blockActiveSeconds = 0.0   // focused seconds in the current work block
    private var activeSinceLongRest = 0.0  // focused seconds since the last long horizontal rest
    private var nudged = false
    private var breakUntil: Date?
    private var breakDeferredSince: Date?
    private var dayLocked = false
    private var softened = false           // symptoms up by 1 → shorter blocks, rest-only breaks
    private var lastHourWritten = Calendar.current.component(.hour, from: Date())
    private var checkinsDoneToday: Set<Int> = []
    private var lastDay = Calendar.current.startOfDay(for: Date())
    private var lastLoggedPause = ""
    private var lastHorizontalPrompt = Date.distantPast
    private var dayCloseShown = false
    private var maxDeferralMinutes = 60.0 // a mic left on can't postpone rest forever
    private var mealBreakSeen = false
    private var currentPlan: BreakPlan?
    private var awaitingCompletion = false
    private var breakStartedAt = Date()
    private var contexts = Contexts.load()
    private var lastContextCheck = Date.distantPast
    private var lastCapacityReload = Date()

    // MARK: - Lifecycle

    func start() {
        restoreTodayState()
        evaluateRamp()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        Store.shared.event("start", "Supervision started. \(capacity.experimentLabel). Blocks \(capacity.blockGreen)/\(capacity.blockYellow)/\(capacity.blockRed), base \(Int(capacity.baseGreen))/\(Int(capacity.baseYellow))/\(Int(capacity.baseRed)).")
    }

    /// Once-a-day things must stay once-a-day across restarts (updates, crashes),
    /// so they're rebuilt from the event log rather than kept only in memory.
    private func restoreTodayState() {
        let start = Calendar.current.startOfDay(for: Date())
        for d in Store.shared.eventDetails(kind: "checkin_shown", since: start) { if let h = Int(d) { checkinsDoneToday.insert(h) } }
        dayCloseShown = Store.shared.lastEvent(kind: "day_close", since: start) != nil
        lastHorizontalPrompt = Store.shared.lastEvent(kind: "horizontal_prompt", since: start)?.0 ?? .distantPast
        mealBreakSeen = Store.shared.lastEvent(kind: "meal_break", since: start) != nil
        softened = Store.shared.lastEvent(kind: "gate_soften", since: start) != nil
        if let lock = Store.shared.lastEvent(kind: "day_lock", since: start), lock.0 > start, !Control.load().isPaused {
            dayLocked = true
            startBreak(until: tomorrowMorning(), title: "Still done for today 💛", reason: lock.1)
        }
    }

    private func tomorrowMorning() -> Date {
        Calendar.current.date(bySettingHour: 6, minute: 0, second: 0, of: Date().addingTimeInterval(86400))!
    }

    // MARK: - Today's numbers (all derived from the log, so they survive restarts)

    var tier: String { Baseline.load().tier }
    var experimentLabel: String { capacity.experimentLabel }

    func todayLoad() -> DayLoad { Store.shared.dayLoad(Date(), calendarMeetingMinutes: CalendarBridge.shared.meetingMinutesToday()) }
    func focusedMinutesToday() -> Double { todayLoad().focused }
    func meetingMinutesToday() -> Double { todayLoad().meeting }
    func weightedToday() -> Double { todayLoad().weighted }

    /// Today's budget in weighted minutes, with its reasons.
    func budgetToday() -> (minutes: Double, reasons: [String]) {
        let t = tier
        var b = capacity.base(for: t)
        var why = ["\(t == "unknown" ? "no Whoop yet (yellow)" : t) base \(Int(b))"]
        if !capacity.stepDownUntil.isEmpty, capacity.stepDownUntil >= Day.string(Date()) { why.append("step-down until \(Day.pretty(capacity.stepDownUntil))") }
        let start = Calendar.current.startOfDay(for: Date())
        let bl = Baseline.load()
        if bl.isToday, let s = bl.sleepHours, s > 0, s < 6 { b *= 0.75; why.append("sleep \(String(format: "%.1f", s)) h → −25%") }
        if Store.shared.lastEvent(kind: "flag_travel", since: start) != nil { b *= 0.7; why.append("travel day → −30%") }
        if Store.shared.lastEvent(kind: "flag_stress", since: start) != nil { b *= 0.7; why.append("stressful day → −30%") }
        if let c = Store.shared.lastCheckin(), c.0 >= start, c.1 <= 2 { b *= 0.7; why.append("check-in \(c.1)/5 → −30%") }
        // Yesterday heavy → today capped (the every-other-day heuristic, softened).
        let y = Store.shared.dayLoad(Date().addingTimeInterval(-86400))
        let yBase = capacity.base(for: Store.shared.baseline(day: Day.string(Date().addingTimeInterval(-86400))).map { $0.recovery >= 67 ? "green" : $0.recovery >= 34 ? "yellow" : "red" } ?? "yellow")
        if y.weighted > yBase * capacity.yesterdayHeavyPercent / 100 { b = min(b, capacity.base(for: t) * capacity.afterHeavyCapPercent / 100); why.append("yesterday was heavy (\(Int(y.weighted))) → capped at \(Int(capacity.afterHeavyCapPercent))%") }
        // Rolling 3-day cap: the real downside protection.
        let d2 = Store.shared.dayLoad(Date().addingTimeInterval(-2 * 86400))
        let room = capacity.rolling3DayFactor * capacity.base(for: t) - y.weighted - d2.weighted
        if room < b { b = room; why.append("3-day cap: \(Int(y.weighted)) + \(Int(d2.weighted)) already this window") }
        b = max(30, b)
        if Control.load().extraBudgetMinutes != 0 { b += Control.load().extraBudgetMinutes; why.append("Claude adjusted \(Int(Control.load().extraBudgetMinutes)) today") }
        return (b, why)
    }

    func loadPercent() -> Double { min(100, weightedToday() / max(1, budgetToday().minutes) * 100) }

    var blockMinutes: Int { softened ? capacity.blockRed : capacity.block(for: tier) }
    var restMinutes: Int { softened ? capacity.restRed : capacity.rest(for: tier) }

    var statusText: String {
        if let b = breakUntil { return "🌙 \(Int(max(0, b.timeIntervalSinceNow) / 60) + 1)m" }
        if dayLocked { return "🔒 done" }
        if Control.load().isPaused { return "⏸ paused" }
        return "🧠 \(Int(blockActiveSeconds / 60))/\(blockMinutes) · \(Int(loadPercent()))%"
    }

    // MARK: - Main loop

    private func tick() {
        rolloverDayIfNeeded()
        writeHourIfNeeded()
        if -lastCapacityReload.timeIntervalSinceNow > 60 { capacity = Capacity.load(); lastCapacityReload = Date() }
        let control = Control.load()
        let idle = Tracker.idleSeconds

        // 1. In a break: count down, then one tap, then three faces, then release.
        if let until = breakUntil {
            if control.isPaused { endBreak(reason: "paused by Claude: \(control.reason)", outcome: "paused"); return }
            if awaitingCompletion { return }
            if Date() >= until {
                if dayLocked { endBreak(reason: "new day", outcome: "day"); return }
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

        // 2. Pause from Claude: never lock, but keep tracking.
        if control.isPaused {
            if lastLoggedPause != control.reason { lastLoggedPause = control.reason; Store.shared.event("pause", control.reason) }
            return
        }

        // 3. Being away long enough counts as a break taken (AMMES: rest between activities).
        if idle > config.idleResetMinutes * 60 {
            if blockActiveSeconds > 0 { Store.shared.event("natural_break", "Away \(Int(idle / 60))m — block reset") }
            let hour = Calendar.current.component(.hour, from: Date())
            if idle > 20 * 60 && (11...14).contains(hour) && !mealBreakSeen {
                mealBreakSeen = true; Store.shared.event("meal_break", "Away \(Int(idle / 60))m at \(hour)h")
            }
            if idle > Double(capacity.longRestMinutes) * 60 { activeSinceLongRest = 0 }
            blockActiveSeconds = 0; nudged = false; breakDeferredSince = nil
            return
        }
        if idle > 60 { return } // short pause: don't count, don't reset

        blockActiveSeconds += 5; activeSinceLongRest += 5

        // 4. Daily budget (weighted) is a hard line, and it's explained.
        let (budget, why) = budgetToday()
        let weighted = weightedToday()
        if !dayLocked && weighted >= budget {
            dayLocked = true
            let reason = "Today's budget is spent: \(Int(weighted)) of \(Int(budget)) weighted minutes (\(why.joined(separator: "; "))). \(daySummary()) The number that matters now is the day-after-tomorrow's morning. \(capacity.experimentLabel)."
            Store.shared.event("day_lock", reason)
            startBreak(until: tomorrowMorning(), title: "That's today's experiment done 💛", reason: reason)
            return
        }

        // 5. Gentle nudge before the takeover — once per block, no stacking.
        let workSecs = Double(blockMinutes) * 60
        if !nudged && blockActiveSeconds >= workSecs - config.nudgeMinutesBefore * 60 {
            nudged = true
            Card.shared.showNudge("Break in \(Int(config.nudgeMinutesBefore)) min 🌱",
                                  reason: "\(Int(blockActiveSeconds / 60)) min of \(Tracker.shared.lastCategory) this block. Today: \(Int(weighted)) of \(Int(budget)) weighted min. Find a stopping point.")
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
            let deferred = breakDeferredSince.map { " (waited \(Int(-$0.timeIntervalSinceNow / 60)) min for your meeting)" } ?? ""
            let plan = makePlan()
            let reasonLine = "\(Int(blockActiveSeconds / 60)) min of focused \(Tracker.shared.lastCategory)\(deferred). " + plan.reason + " \(capacity.experimentLabel)."
            currentPlan = plan
            Store.shared.event("break_plan", "\(plan.activity.key)|\(plan.activity.load)|\(plan.acknowledgement ?? plan.reason)")
            startBreak(until: Date().addingTimeInterval(Double(plan.activity.minutes) * 60), title: plan.headline, reason: reasonLine, plan: plan)
            return
        }

        maybeHorizontalPrompt()

        // 7. One-tap check-in, at most twice a day, only while active.
        let hour = Calendar.current.component(.hour, from: Date())
        if config.checkInHours.contains(hour) && !checkinsDoneToday.contains(hour) {
            checkinsDoneToday.insert(hour)
            Store.shared.event("checkin_shown", "\(hour)")
            Card.shared.showCheckin(context: "day \(Int(weighted))/\(Int(budget)) weighted, \(Int(meetingMinutesToday()))m meetings")
        }
    }

    // MARK: - Planning

    /// Every ~2 h of focused work the break is the long horizontal one; otherwise
    /// the planner picks. Softened days (symptoms up by 1) are rest-only.
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
        if softened { inputs.lastCheckin = min(inputs.lastCheckin ?? 5, 2) } // forces the rest-only gate with its own wording
        var plan = Planner.plan(inputs)
        if softened, plan.acknowledgement != nil {
            plan = BreakPlan(activity: plan.activity, headline: plan.headline, reason: plan.reason,
                             acknowledgement: "Your faces after the last break were up a notch, so the rest of today is plain rest and shorter blocks. That's the gate working, not a verdict.",
                             unlock: "What brings the options back: tomorrow morning, and steady faces.", alternatives: plan.alternatives, hrCeiling: plan.hrCeiling)
        }
        // Short rests by tier: the planner's rest activity gets today's rest length.
        if plan.activity.load == "none" {
            let r = plan.activity
            plan.activity = Activity(key: r.key, title: r.title, emoji: r.emoji, minutes: max(restMinutes, 5), load: r.load, instructions: r.instructions, minTier: r.minTier)
        }
        return plan
    }

    private func plannerInputs() -> Planner.Inputs {
        let start = Calendar.current.startOfDay(for: Date())
        let done = Store.shared.eventDetails(kind: "break_done", since: start).map { $0.split(separator: "|").map(String.init) }
        let keys = done.compactMap { $0.first }.filter { $0 != "skipped" }
        let active = done.filter { $0.count > 1 && $0[1] != "none" && $0[0] != "rest" && $0[0] != "skipped" }.count
        let lastLoad = done.last.map { $0[0] == "rest" || $0[0] == "skipped" ? "none" : ($0.count > 1 ? $0[1] : "none") } ?? "none"
        let checkin = Store.shared.lastCheckin().flatMap { $0.0 >= start ? $0.1 : nil }
        let b = budgetToday()
        return Planner.Inputs(baseline: Baseline.load(), context: contexts.active, loadPercent: loadPercent(),
                              focusedMinutes: weightedToday(), budgetMinutes: b.minutes,
                              meetingMinutes: meetingMinutesToday(), lastCheckin: checkin,
                              hour: Calendar.current.component(.hour, from: Date()), breaksToday: keys,
                              activeBreaksToday: active, lastBreakLoad: lastLoad)
    }

    /// Calendar and Zoom's own process are trusted without limit. Camera, mic and
    /// meeting-window signals are trusted for `maxDeferralMinutes`, then rest wins.
    private func meetingBlocker() -> String? {
        if let t = CalendarBridge.shared.meetingNearby(bufferMinutes: config.zoomBufferMinutes) { return "'\(t)' is within \(Int(config.zoomBufferMinutes)) min" }
        if ZoomGuard.inMeeting() { return "You're in a Zoom call" }
        guard let live = MeetingDetector.activeCall() else { return nil }
        if let since = breakDeferredSince, -since.timeIntervalSinceNow > maxDeferralMinutes * 60 {
            Store.shared.event("deferral_cap", "\(live), but the break has waited \(Int(maxDeferralMinutes)) min with no calendar meeting — resting anyway")
            return nil
        }
        return live
    }

    // MARK: - Breaks

    private func startBreak(until: Date, title: String, reason: String, plan: BreakPlan? = nil) {
        breakUntil = until; breakDeferredSince = nil; breakStartedAt = Date(); awaitingCompletion = false
        Card.shared.hide()
        Store.shared.event("break_start", reason)
        LockScreen.shared.onChoose = { [weak self] a in
            guard let self = self, var p = self.currentPlan else { return }
            p.activity = a; self.currentPlan = p
            let wanted = self.breakStartedAt.addingTimeInterval(Double(a.minutes) * 60)
            if wanted > (self.breakUntil ?? wanted) { self.breakUntil = wanted }
            Store.shared.event("break_choice", "\(a.key)|\(a.load)|chosen from the alternatives")
        }
        LockScreen.shared.show(title: title, reason: reason, plan: plan, extra: careLine())
    }

    /// After "how did that go": three faces. Then the gate decides what the rest
    /// of the day looks like. Skipping is allowed and just means no reading.
    private func askSymptomsThenEnd(outcome: String) {
        let intro = Voice.pick(["Three quick faces, then you're free 💛", "Last thing: how's the head?", "Quick receipt for that block:", "Three taps and we're done:"], Store.shared.countEvents(kind: "break_done", since: Calendar.current.startOfDay(for: Date())))
        LockScreen.shared.askSymptoms(intro: intro) { [weak self] r in
            guard let self = self else { return }
            if let r = r {
                Store.shared.symptoms(fog: r.fog, headache: r.headache, crashy: r.crashy, context: "after break, \(Int(self.weightedToday()))/\(Int(self.budgetToday().minutes))")
                self.applyGate(fog: r.fog, headache: r.headache, crashy: r.crashy)
            } else {
                Store.shared.event("symptoms_skipped", "after break")
            }
            self.endBreak(reason: "break complete", outcome: outcome)
        }
    }

    /// The symptom gate: compared with the day's first reading. Up by 2 (or any
    /// symptom at 4+) → done for today. Up by 1 → shorter blocks, rest-only breaks.
    private func applyGate(fog: Int, headache: Int, crashy: Int) {
        let readings = Store.shared.symptomReadings(day: Date())
        guard let first = readings.first else { return }
        let worst = max(fog, headache, crashy)
        let rise = max(fog - first.1, headache - first.2, crashy - first.3)
        if worst >= capacity.gateAbsolute || rise >= capacity.gateWorsenBy {
            let reason = "Your faces moved: fog \(first.1)→\(fog), headache \(first.2)→\(headache), crashy \(first.3)→\(crashy). Up by \(rise) (or at \(worst)/5) is the gate. Stopping now is the experiment working, not a failure; the reading that matters is the morning after tomorrow. \(capacity.experimentLabel)."
            Store.shared.event("gate_stop", reason)
            Store.shared.event("day_lock", reason)
            dayLocked = true
            breakUntil = tomorrowMorning()
            currentPlan = nil
            // endBreak will hide the lock; re-show it as the day lock.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.startBreak(until: self.tomorrowMorning(), title: "That's today's block budget, by your own faces 💛", reason: reason)
            }
        } else if rise >= capacity.softenBy && !softened {
            softened = true
            Store.shared.event("gate_soften", "Faces up by \(rise) vs the morning: blocks drop to \(capacity.blockRed) min and breaks are plain rest for the rest of today.")
        }
    }

    private func endBreak(reason: String, outcome: String) {
        LockScreen.shared.hide()
        let plan = currentPlan
        breakUntil = nil; blockActiveSeconds = 0; nudged = false; awaitingCompletion = false; currentPlan = nil
        if plan?.activity.minutes ?? 0 >= capacity.longRestMinutes && plan?.activity.load == "none" { activeSinceLongRest = 0 }
        if dayLocked && !Control.load().isPaused && outcome == "day" { dayLocked = false } // new day
        Store.shared.event("break_end", reason)
        if !dayLocked, outcome != "day" {
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
        if !mealBreakSeen && t >= 11.5 && t <= 14.5 { return "🍽️ Good time to eat something. You haven't stepped away since 11." }
        if t >= 14.5 && t <= 18 { return "💧 Drink some water while you're up." }
        return nil
    }

    func daySummary() -> String {
        let l = todayLoad()
        let top = l.byCategory.filter { $0.key != "leisure" }.sorted { $0.value > $1.value }.prefix(3).map { "\(Int($0.value))m \($0.key)" }
        let breaks = Store.shared.countEvents(kind: "break_start", since: Calendar.current.startOfDay(for: Date()))
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

    private func maybeDayClose() {
        guard !dayCloseShown, Calendar.current.component(.hour, from: Date()) >= 17 else { return }
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
        guard let ssid = Contexts.currentSSID(),
              let match = contexts.contexts.first(where: { $0.ssids.contains(ssid) }),
              match.name != contexts.current else { return }
        contexts.current = match.name; contexts.save()
        Store.shared.event("context", "Switched to '\(match.name)' (Wi-Fi: \(ssid))")
    }
    var contextName: String { contexts.active.name }

    private func writeHourIfNeeded() {
        let h = Calendar.current.component(.hour, from: Date())
        guard h != lastHourWritten else { return }
        lastHourWritten = h
        let end = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
        CalendarBridge.shared.writeHourSummary(from: end.addingTimeInterval(-3600), to: end)
    }

    private func rolloverDayIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != lastDay else { return }
        lastDay = today; checkinsDoneToday = []; dayLocked = false; dayCloseShown = false; lastHorizontalPrompt = .distantPast
        mealBreakSeen = false; softened = false; activeSinceLongRest = 0
        if breakUntil != nil, breakUntil! > Date().addingTimeInterval(3600) { endBreak(reason: "new day", outcome: "day") }
        var c = Control.load(); c.extraBudgetMinutes = 0
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: Control.file) }
        evaluateRamp()
    }

    // MARK: - The ramp (PLAN-v2 §5): credit clean days at day+2, step up after 3, step down only on patterns

    func evaluateRamp() {
        var cap = Capacity.load()
        let today = Calendar.current.startOfDay(for: Date())
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
                    cap.baseGreen = min(cap.maxBase, cap.baseGreen + cap.stepUpMinutes)
                    cap.baseYellow = min(cap.maxBase * 0.8, cap.baseYellow + cap.stepUpMinutes)
                    cap.baseRed = min(cap.maxBase * 0.5, cap.baseRed + cap.stepUpMinutes / 2)
                    cap.blockGreen = min(cap.maxBlock, cap.blockGreen + cap.stepUpBlockMinutes)
                    cap.blockYellow = min(cap.maxBlock - 5, cap.blockYellow + cap.stepUpBlockMinutes)
                    cap.experimentNumber += 1
                    cap.experimentStarted = Day.string(today); cap.reviewDate = Day.string(today.addingTimeInterval(14 * 86400))
                    cap.history.append("\(Day.string(today)): 3 clean days → experiment \(cap.experimentNumber): base \(Int(cap.baseGreen))/\(Int(cap.baseYellow))/\(Int(cap.baseRed)), blocks \(cap.blockGreen)/\(cap.blockYellow)/\(cap.blockRed).")
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
            cap.history.append("\(Day.string(today)): step-down \(Int(cap.stepDownPercent))% until \(cap.stepDownUntil) because of \(why). Earned back the same way.")
            Store.shared.event("ramp_down", cap.history.last!)
        }
        cap.save(); capacity = cap
    }
}
