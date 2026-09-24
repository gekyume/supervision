import Foundation

// MARK: - Capacity: the adaptive model (PLAN-v2)
//
// The budget is "what you could repeat tomorrow". Blocks and budgets depend on the
// morning Whoop tier; the ramp raises them after clean days (verified at day+2) and
// lowers them only on patterns. Everything here is an experiment with a review date.

struct Capacity: Codable {
    // Blocks (minutes of focused work before a short rest), by tier.
    var blockGreen = 30, blockYellow = 25, blockRed = 15
    // Short rest after a block, by tier; long horizontal rest every `longRestEveryMinutes`.
    var restGreen = 5, restYellow = 7, restRed = 10
    var longRestMinutes = 15, longRestEveryMinutes = 120
    // Weighted daily budget, by tier. Start conservative (2–3 h) and let the ramp raise it.
    var baseGreen = 180.0, baseYellow = 150.0, baseRed = 90.0
    // Guard rails.
    var rolling3DayFactor = 2.5        // 3-day weighted load ≤ factor × base
    var yesterdayHeavyPercent = 85.0   // if yesterday used more than this…
    var afterHeavyCapPercent = 75.0    // …today is capped at this
    // Ramp.
    var cleanDaysToStepUp = 3
    var stepUpMinutes = 20.0           // 15–30 min steps
    var stepUpBlockMinutes = 5
    var maxBase = 360.0, maxBlock = 45
    var stepDownPercent = 15.0, stepDownDays = 14
    // Symptom gate (1 = great … 5 = worst).
    var gateWorsenBy = 2               // any symptom up this much vs the day's first reading → done for today
    var gateAbsolute = 4               // or any symptom at this level
    var softenBy = 1                   // up by this → shorter blocks, rest-only breaks
    // Bookkeeping.
    var experimentNumber = 1
    var experimentStarted = ""         // yyyy-MM-dd
    var reviewDate = ""                // yyyy-MM-dd
    var stepDownUntil = ""             // yyyy-MM-dd, when a step-down is in force
    var lastCreditedDay = ""           // last day evaluated as clean/not
    var cleanStreak = 0
    var history: [String] = []         // human-readable ramp log

    static let file = Config.dir.appendingPathComponent("capacity.json")
    static func load() -> Capacity {
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(Capacity.self, from: d) { return c }
        var c = Capacity()
        c.experimentStarted = Day.string(Date()); c.reviewDate = Day.string(Date().addingTimeInterval(14 * 86400))
        c.history.append("\(c.experimentStarted): experiment 1 starts — blocks 30/25/15, base 180/150/90")
        c.save(); return c
    }
    func save() { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(self).write(to: Capacity.file) }

    func block(for tier: String) -> Int { tier == "green" ? blockGreen : tier == "red" ? blockRed : blockYellow }
    func rest(for tier: String) -> Int { tier == "green" ? restGreen : tier == "red" ? restRed : restYellow }
    func base(for tier: String) -> Double {
        let b = tier == "green" ? baseGreen : tier == "red" ? baseRed : baseYellow
        if !stepDownUntil.isEmpty, stepDownUntil >= Day.string(Date()) { return b * (1 - stepDownPercent / 100) }
        return b
    }
    var experimentLabel: String { "Experiment \(experimentNumber) · review \(Day.pretty(reviewDate))" }
}

enum Day {
    static func string(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d) }
    static func date(_ s: String) -> Date? { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.date(from: s) }
    static func pretty(_ s: String) -> String { guard let d = date(s) else { return s }; let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d) }
    static func start(_ s: String) -> Date { date(s) ?? Date() }
}

// MARK: - Weighted load

/// Kinds of work cost different amounts. These are first guesses, reviewed every fortnight.
enum Weights {
    static let byCategory: [String: Double] = [
        "admin": 0.8, "comms": 0.8, "reading": 1.0, "writing": 1.0, "analysis": 1.0, "building": 1.0,
        "video": 1.2, "meeting": 1.3, "other": 1.0, "leisure": 0.0,
    ]
    static let intenseMeeting = 1.6
    static let contextSwitchPenalty = 0.10    // per hour with > threshold app switches
    static let contextSwitchThreshold = 20
    static let offscreenWork = 0.5            // paper / voice work the user reports
}

struct DayLoad {
    var weighted = 0.0            // the number the budget is measured in
    var focused = 0.0             // raw focused screen minutes (non-meeting, non-leisure)
    var meeting = 0.0             // screen meeting minutes (max with calendar)
    var offscreen = 0.0           // reported paper/voice minutes (raw)
    var switchHours = 0           // hours with heavy context switching
    var byCategory: [String: Double] = [:]
}

extension Store {
    /// Weighted load for a day, from samples, calendar meetings, flags and reported off-screen work.
    func dayLoad(_ day: Date, calendarMeetingMinutes: Double = 0) -> DayLoad {
        let start = Calendar.current.startOfDay(for: day), end = min(start.addingTimeInterval(86400), Date())
        var l = DayLoad()
        let secs = activeSeconds(from: start, to: end)
        for (cat, s) in secs {
            let m = s / 60
            l.byCategory[cat] = m
            if cat == "meeting" { continue }
            if cat != "leisure" { l.focused += m }
            l.weighted += m * (Weights.byCategory[cat] ?? 1.0)
        }
        l.meeting = max((secs["meeting"] ?? 0) / 60, calendarMeetingMinutes)
        let intense = countEvents(kind: "flag_intense", since: start, until: end) > 0
        l.weighted += l.meeting * (intense ? Weights.intenseMeeting : Weights.byCategory["meeting"]!)
        // Context switching: hours with many app changes.
        l.switchHours = heavySwitchHours(from: start, to: end)
        l.weighted *= 1 + Double(l.switchHours) * Weights.contextSwitchPenalty / max(1, Double(max(1, Int(l.focused / 60))))
        // Off-screen work the user told us about: "minutes|what".
        for d in eventDetails(kind: "offscreen_work", since: start, until: end) {
            if let m = Double(d.split(separator: "|").first ?? "") { l.offscreen += m; l.weighted += m * Weights.offscreenWork }
        }
        return l
    }

    func heavySwitchHours(from: Date, to: Date) -> Int {
        var hours = 0
        var t = from
        while t < to {
            let next = t.addingTimeInterval(3600)
            if appSwitches(from: t, to: next) > Weights.contextSwitchThreshold { hours += 1 }
            t = next
        }
        return hours
    }
}
