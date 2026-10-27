import Foundation

// The decisions, as pure functions: no clock, no database, no screen. The engine feeds them
// what it knows and acts on the answer; `scripts/test.sh` checks them without the app.
// Every rule here mirrors one the user agreed to (CLAUDE.md "The model"). Change the rule
// and its test together.

// MARK: - Day phases

enum DayPhase: Equatable { case off, late, day }

enum Rules {
    /// Midnight → `morningHour`: off. `nightStartHour` → midnight: 2 on / 10 off. Otherwise: a day.
    static func phase(hour: Int, nightStartHour: Int, morningHour: Int) -> DayPhase {
        hour < morningHour ? .off : hour >= nightStartHour ? .late : .day
    }

    /// The next `morningHour` after `now`: today's if it's still ahead, otherwise tomorrow's.
    static func nextMorning(after now: Date, morningHour: Int, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: now)!
        return today > now ? today : today.addingTimeInterval(86400)
    }
}

// MARK: - The symptom gate (1 = worst … 10 = best)

enum GateOutcome: Equatable {
    case stop(trigger: String, moved: String, stops: Int)   // the day ends
    case rest(trigger: String, moved: String)               // an hour off
    case soften(drop: Int, moved: String)                   // shortest blocks, plain rest
    case adapt                                              // nothing gated: BlockRule decides
}

enum GateRule {
    /// `readings` are today's answers so far, oldest first (the current one included).
    /// Each gated key is compared with its first answer today. `priorRests` = hour-offs already
    /// taken today. Only `keys` count; everything else is logged, never gated.
    static func evaluate(now: [String: Int], readings: [[String: Int]], keys: [String], labels: [String: String],
                         dropBy: Int, floor: Int, softenBy: Int, softened: Bool, priorRests: Int, stopsForDay: Int) -> GateOutcome {
        var drops: [String] = [], maxDrop = 0, lowest: (String, Int)? = nil
        for k in keys {
            guard let v = now[k] else { continue }
            let name = labels[k] ?? k
            if v <= floor, v < (lowest?.1 ?? 11) { lowest = (name, v) }
            if let first = readings.first(where: { $0[k] != nil })?[k], first > v {
                drops.append("\(name) \(first)→\(v)"); maxDrop = max(maxDrop, first - v)
            }
        }
        let moved = drops.isEmpty ? "no drop from this morning" : drops.joined(separator: ", ")
        if maxDrop >= dropBy || lowest != nil {
            let trigger = lowest.map { "\($0.0) is at \($0.1)/10" } ?? "down \(maxDrop) from this morning"
            let stops = priorRests + 1
            return stops >= stopsForDay ? .stop(trigger: trigger, moved: moved, stops: stops) : .rest(trigger: trigger, moved: moved)
        }
        if maxDrop >= softenBy && !softened { return .soften(drop: maxDrop, moved: moved) }
        return .adapt
    }
}

// MARK: - Block length after a card

enum BlockRule {
    /// A gated number below its first answer today → a step shorter; otherwise overall ≥ `upOverall`
    /// → a step longer. Within [min, max]. Nil when nothing changes (or the day is softened).
    static func adapt(before: Int, now: [String: Int], readings: [[String: Int]], keys: [String],
                      step: Int, min lo: Int, max hi: Int, upOverall: Int, softened: Bool) -> (after: Int, why: String)? {
        guard !softened else { return nil }
        let gated = now.filter { keys.contains($0.key) }
        guard !gated.isEmpty || now["overall"] != nil else { return nil }
        var worse = false
        for (k, v) in gated { if let first = readings.first(where: { $0[k] != nil })?[k], v < first { worse = true } }
        var after = before, why = ""
        if worse { after = max(lo, before - step); why = "a number dipped since this morning" }
        else if let o = now["overall"], o >= upOverall { after = min(hi, before + step); why = "steady, and overall \(o)/10" }
        return after == before ? nil : (after, why)
    }
}

// MARK: - 20-20-20

enum EyeAction: Equatable { case nothing, notice, coveredByBreak, wait, start }

enum EyeRule {
    /// `active` = focused seconds since the last look-away. The heads-up comes `notice` s before
    /// `due`, only if the break can actually follow (not near the night switch, not in a call, and
    /// the regular break isn't about to cover it: 3 min). At `due`: covered → reset; in a call →
    /// wait; else start. `inCall` is a closure because it's expensive (checked only when it matters).
    static func decide(active: Double, due: Double, notice: Double, nudged: Bool, blockRemaining: Double,
                       nearNight: Bool, late: Bool, inCall: () -> Bool) -> EyeAction {
        guard due > 0, !late else { return .nothing }
        if !nudged, active >= due - notice, active < due, !nearNight, blockRemaining >= 180 + notice, !inCall() { return .notice }
        guard active >= due else { return .nothing }
        if blockRemaining < 180 { return .coveredByBreak }
        if inCall() { return .wait }
        return .start
    }
}

// MARK: - Blinks (the eye break counts down blinks; the user, Oct 24)

enum BlinkRule {
    /// Done when the blinks are in; or, if the camera can't see a face (looking out a window,
    /// no camera), after the plain timer; and never longer than `maxSeconds`.
    static func done(blinks: Int, target: Int, elapsed: Double, secondsSinceFace: Double, timerSeconds: Double, maxSeconds: Double) -> Bool {
        if blinks >= target { return true }
        if elapsed >= maxSeconds { return true }
        return secondsSinceFace >= 3 && elapsed >= timerSeconds
    }

    /// One blink = the eyes' openness (height / width) dips below 60% of its open level, then
    /// recovers above 80%. `open` is a slowly updated baseline of open-eye openness.
    struct Detector {
        var open: Double? = nil
        var closed = false
        var blinks = 0
        mutating func feed(_ ratio: Double) {
            guard ratio > 0 else { return }
            let base = open ?? ratio
            if !closed && ratio < base * 0.6 { closed = true }
            else if closed && ratio > base * 0.8 { closed = false; blinks += 1 }
            if !closed { open = base * 0.95 + max(ratio, base * 0.9) * 0.05 }   // drift toward the open level
        }
    }
}

// MARK: - Task switching (user, Oct 24: hopping "makes my brain in a certain way that all I can do is …hop")

enum SwitchRule {
    /// One gentle card when the app switches in the window reach `threshold`, at most once per
    /// `cooldown` seconds. Never during a pause, a call or the late-night cycle. It never locks.
    static func shouldNudge(switches: Int, threshold: Int, secondsSinceLastNudge: Double, cooldown: Double,
                            paused: Bool, inCall: Bool, late: Bool) -> Bool {
        threshold > 0 && switches >= threshold && secondsSinceLastNudge >= cooldown && !paused && !inCall && !late
    }
}

// MARK: - What counts as a meeting

enum MeetingKind {
    /// A calendar event protects you from breaks only if it's a real meeting: a video link or
    /// other attendees, and not travel or a long block. Oct 24: "Flight to Boston (DL 860)"
    /// counted, and held off every break for the whole flight. Travel = flight/train/ferry words,
    /// ✈️, or a flight number like "(DL 860)". Anything over 4 h isn't a meeting either.
    static func counts(title: String, minutes: Double, hasVideo: Bool, hasAttendees: Bool) -> Bool {
        guard hasVideo || hasAttendees, minutes <= 240 else { return false }
        return !isTravel(title)
    }

    static func isTravel(_ title: String) -> Bool {
        let t = title.lowercased()
        let words = ["flight", "✈", "train to", "train from", "amtrak", "ferry", "bus to", "check-in", "check in at", "hotel", "airbnb", "drive to", "layover", "boarding"]
        if words.contains(where: { t.contains($0) }) { return true }
        // A flight number: two letters/digits then 1–4 digits, e.g. "DL 860", "UA1234", "B6 417".
        return title.range(of: #"\b(?:[A-Z]{2}|[A-Z]\d|\d[A-Z]) ?\d{1,4}\b"#, options: .regularExpression) != nil
            && (t.contains("to ") || t.contains("→") || t.contains("->"))
    }
}

// MARK: - Statements to type (user, Oct 25: "change the message every time so it takes more time")

enum Statements {
    /// Unlocking from the phone during a lock. {time} = now.
    static let unlock = [
        "I understand I am breaking my own policy for health",
        "I am choosing to skip my rest at {time}, knowing it costs me later",
        "My health policy says rest now and I am overriding it",
        "I know this break protects tomorrow and I am ending it early",
        "At {time} I am unlocking my computer against my own plan",
        "Rest is the plan and I am choosing screen time instead",
    ]
    /// Adding an app mid-block. {app} = the app, {time} = now.
    static let addApp = [
        "I need {app} for this block",
        "{app} is part of what I am doing right now",
        "I am choosing to open {app} at {time}",
        "This block really does need {app}",
        "Adding {app} on purpose, not out of habit",
        "I picked my apps and I am adding {app} anyway",
    ]
    /// A different one from last time, with the blanks filled in. `roll` is any number (random in the app).
    static func pick(_ pool: [String], last: Int?, roll: Int, app: String = "", time: String = "") -> (index: Int, text: String) {
        var i = abs(roll) % pool.count
        if i == last { i = (i + 1) % pool.count }
        return (i, pool[i].replacingOccurrences(of: "{app}", with: app).replacingOccurrences(of: "{time}", with: time))
    }
}

// MARK: - Coherent breathing (rest breaks; the user, Oct 25)

enum Breath {
    static let inhale = 5.5, exhale = 5.5   // ≈ 5.5 breaths a minute
    /// 0 = lungs empty … 1 = full, eased, starting on an inhale.
    static func phase(seconds t: Double) -> Double {
        let cycle = inhale + exhale, x = t.truncatingRemainder(dividingBy: cycle)
        let u = x < inhale ? x / inhale : 1 - (x - inhale) / exhale
        return (1 - cos(u * .pi)) / 2
    }
    static func inhaling(seconds t: Double) -> Bool { t.truncatingRemainder(dividingBy: inhale + exhale) < inhale }
}

// MARK: - Movement, checked by the camera (user, Oct 25: "start mandating moving around")

enum MoveRule {
    static let holdSeconds = 15.0, giveUpSeconds = 180.0
    /// One camera frame, in Vision's normalized coordinates (y up). Reaching = both wrists above
    /// the nose. Standing (when required) = hips in view too, which a desk camera only sees once
    /// you stand and step back. Red days ask for the seated reach only (POTS).
    static func posed(leftWristY: Double?, rightWristY: Double?, noseY: Double?, hipsVisible: Bool, needStand: Bool) -> Bool {
        guard let l = leftWristY, let r = rightWristY, let n = noseY else { return false }
        return l > n && r > n && (hipsVisible || !needStand)
    }
    /// Live coaching (user, Oct 26: "sometimes I need to back up for it to see me … back up, come closer").
    /// Inputs are Vision's normalized positions (0–1); shoulderWidth is the distance between the shoulders.
    /// Returns what to say next, most basic problem first.
    static func coach(bodySeen: Bool, shoulderWidth: Double?, centerX: Double?, hipsVisible: Bool, needStand: Bool,
                      leftWristUp: Bool, rightWristUp: Bool) -> String {
        guard bodySeen else { return "Step in front of the camera" }
        if let w = shoulderWidth, w > 0.42 { return "Back up a bit" }
        if needStand && !hipsVisible { return "Back up so I can see your hips" }
        if let w = shoulderWidth, w < 0.09 { return "Come a little closer" }
        if let x = centerX, x < 0.2 || x > 0.8 { return "Move toward the middle" }
        if !leftWristUp && !rightWristUp { return "Both arms up, over your head" }
        if leftWristUp != rightWristUp { return "Other arm up too" }
        return "✓ That's it, hold it"
    }

    /// The countdown starts when the pose has been held `holdSeconds` in total, or after
    /// `giveUpSeconds` of trying (never a trap), or right away without a camera.
    static func release(held: Double, trying: Double, cameraOK: Bool) -> (go: Bool, why: String) {
        if !cameraOK { return (true, "no camera") }
        if held >= holdSeconds { return (true, "seen") }
        if trying >= giveUpSeconds { return (true, "gave up after 3 min") }
        return (false, "")
    }
}

// MARK: - Avoidance (user, Oct 25: "when I'm avoiding … texts, emails, my to-do list … usually means I'm tired")

enum AvoidRule {
    /// Call it out when unread on the watched apps grew by `growth`+ over the window while none of
    /// them was opened for `quietMinutes`+ and the person was active elsewhere that long; at most
    /// `maxPerDay` times, `gapHours` apart; never in a call, a pause or the late-night cycle.
    static func shouldCallOut(unreadNow: Int, unreadThen: Int, minutesSinceOpened: Double, activeMinutes: Double,
                              callsToday: Int, hoursSinceLast: Double, blocked: Bool,
                              growth: Int = 10, quietMinutes: Double = 90, maxPerDay: Int = 2, gapHours: Double = 2) -> Bool {
        !blocked && unreadNow - unreadThen >= growth && minutesSinceOpened >= quietMinutes && activeMinutes >= quietMinutes * 0.6
            && callsToday < maxPerDay && hoursSinceLast >= gapHours
    }
}

// MARK: - Micro stretch breaks (user, Oct 26: "similar to the 20-20-20 … hold a pose … then it lets me resume")

enum MicroRule {
    /// Every `every` focused seconds (a clock regular breaks don't reset), unless a regular break is
    /// under 3 min away, an eye break is due within a minute, or it's late / a call / paused.
    static func due(active: Double, every: Double, blockRemaining: Double, eyeIn: Double, blocked: Bool) -> Bool {
        every > 0 && active >= every && blockRemaining >= 180 && eyeIn >= 60 && !blocked
    }
}

// MARK: - Counting reps (user, Oct 26: push-ups and clamshells, counted by the camera)

enum Rep {
    /// The angle at `b` (degrees) formed by a–b–c, from 2D points.
    static func angle(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double)) -> Double {
        let v1 = (a.0 - b.0, a.1 - b.1), v2 = (c.0 - b.0, c.1 - b.1)
        let dot = v1.0 * v2.0 + v1.1 * v2.1, n = hypot(v1.0, v1.1) * hypot(v2.0, v2.1)
        guard n > 0 else { return 0 }
        return acos(max(-1, min(1, dot / n))) * 180 / .pi
    }

    /// One rep = the measure crosses `enter`, then comes back past `exit`. Push-ups watch the elbow
    /// angle going below 100° (down) and back above 150° (up); clamshells watch the knees opening
    /// past 30° and closing below 12°. The gap between the two thresholds keeps jitter from counting.
    struct Counter {
        let enter: Double, exit: Double
        var armed = false
        var reps = 0
        /// `rising`: the rep starts by going UP past `enter` (clamshell opening); else by going DOWN (push-up).
        let rising: Bool
        @discardableResult mutating func feed(_ v: Double) -> Bool {
            if !armed { if rising ? v > enter : v < enter { armed = true } ; return false }
            if rising ? v < exit : v > exit { armed = false; reps += 1; return true }
            return false
        }
        static func pushUp() -> Counter { Counter(enter: 100, exit: 150, rising: false) }
        static func clamshell() -> Counter { Counter(enter: 30, exit: 12, rising: true) }
        /// Glute bridge: the shoulder–hip–knee line straightens past 158° (hips up), back below 140° (down).
        static func bridge() -> Counter { Counter(enter: 158, exit: 140, rising: true) }
    }
}

enum WorkoutRule {
    /// The daily workout break: the first regular break from `afterHour`, not on red days, not from
    /// 5 pm (the evening rule for movement), once a day.
    static func due(hour: Int, afterHour: Int, tier: String, doneToday: Bool, triedToday: Bool) -> Bool {
        hour >= afterHour && hour < 17 && tier != "red" && !doneToday && !triedToday
    }
}

// MARK: - Breaks around meetings

enum MeetingRule {
    /// A regular break (≤ 30 min, not a day lock) ends 5 min before the next meeting, if that
    /// still leaves at least 2 min. Returns the new end, or nil to leave it alone.
    static func trimmedEnd(requested: Date, now: Date, dayLocked: Bool, nextMeetingStart: Date?) -> Date? {
        guard requested.timeIntervalSince(now) <= 30 * 60, !dayLocked, let start = nextMeetingStart else { return nil }
        let cut = start.addingTimeInterval(-5 * 60)
        return cut < requested && cut > now.addingTimeInterval(2 * 60) ? cut : nil
    }

    /// A lock that steps aside for a meeting comes back after it when it's a day lock or
    /// more than a minute of it would remain. Resume = meeting end + 5 min.
    static func resumesAfter(meetingEnd: Date, lockUntil: Date, dayLocked: Bool) -> (resume: Date, comesBack: Bool) {
        let resume = meetingEnd.addingTimeInterval(5 * 60)
        return (resume, dayLocked || lockUntil.timeIntervalSince(resume) > 60)
    }
}

// MARK: - Phone unlock

enum PhoneMessage: Equatable {
    case end
    case pause(minutes: Int, reason: String?)
    /// From the phone workout page: "workout|done|<summary>" or "workout|stopped|<summary>".
    case workout(done: Bool, summary: String)

    /// "<minutes>|<reason>" → pause 1–120 min; "end…" → resume. Anything else still unlocks
    /// (30 min): a tap on the phone must never silently fail.
    static func parse(_ message: String) -> PhoneMessage {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("end") { return .end }
        if text.lowercased().hasPrefix("workout|") {
            let w = text.split(separator: "|", maxSplits: 2).map(String.init)
            return .workout(done: w.count > 1 && w[1].lowercased() == "done", summary: w.count > 2 ? w[2] : "")
        }
        let parts = text.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let mins = parts.first.flatMap { Int($0.filter(\.isNumber)) }.map { min(max($0, 1), 120) } ?? 30
        let reason = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        return .pause(minutes: mins, reason: reason)
    }

    /// Only fresh messages count: an old one must never unlock the Mac later.
    static func isFresh(sentAt: Double, now: Double) -> Bool { now - sentAt < 300 }
}

// MARK: - App picker (which apps this block may use)

enum AppGateRule {
    /// Block a regular app when a picker list is in force for this block, it isn't on it or on the
    /// always-allowed list, and nothing makes blocking wrong: a pause, or a live call / meeting
    /// (Supervision never keeps you from a meeting).
    static func blocks(bundleID: String, picked: Set<String>?, always: Set<String>, paused: Bool, inCall: Bool) -> Bool {
        guard let picked = picked, !paused, !inCall else { return false }
        return !picked.contains(bundleID) && !always.contains(bundleID)
    }
}

// MARK: - Picking a block's apps (user, Oct 25: "I can only choose 3")

enum AppPickRule {
    /// Free picks up to `limit`; each one past it needs the typed statement first.
    static func needsPermission(alreadyPicked: Int, limit: Int) -> Bool { limit > 0 && alreadyPicked >= limit }
}

// MARK: - Clean slate

enum CleanSlateRule {
    /// The "first time the computer is opened" run: after `cleanSlateHour`, once a day, either
    /// while the Mac is awake in the small hours (before `morningHour`) or on the first wake or
    /// unlock after which the computer hasn't really been used since `cleanSlateHour`
    /// (under a minute of activity). A wake at 11 am after a morning of work is not a morning.
    static func morningDue(hour: Int, cleanSlateHour: Int, morningHour: Int, woke: Bool,
                           activeSecondsSinceCleanSlateHour: Double, ranToday: Bool) -> Bool {
        guard cleanSlateHour >= 0, hour >= cleanSlateHour, !ranToday else { return false }
        return hour < morningHour || (woke && activeSecondsSinceCleanSlateHour < 60)
    }

    /// Away long enough with nothing to explain the stillness, and not already cleared this stretch.
    static func awayDue(idleSeconds: Double, awayMinutes: Int, clearedWithinStretch: Bool, explained: Bool) -> Bool {
        awayMinutes > 0 && idleSeconds >= Double(awayMinutes) * 60 && !clearedWithinStretch && !explained
    }
}
