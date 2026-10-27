import Foundation

// MARK: - Capacity: the adaptive model (docs/DESIGN.md)
//
// Pacing over quotas (user, Sep 25): one generous daily cap on computer time, and work
// blocks whose length follows how you're doing. The morning recovery tier sets the first
// block; every how-are-you card nudges the next one up or down. The ramp lengthens the
// starting blocks after clean days (verified at day+2) and shortens them only on patterns.
// Everything here is an experiment with a review date.

struct Capacity: Codable {
    // Starting block (minutes of focused work before a short rest), by tier.
    var blockGreen = 30, blockYellow = 25, blockRed = 15
    // Live adjustment after each card: steady or better (and overall ≥ adaptUpOverall) → +step;
    // clear/head/not-crashing down 1 → −step. Always within [blockMin, blockMax].
    var blockStep = 5, blockMin = 15, blockMax = 45, adaptUpOverall = 7
    // Short rest after a block, by tier; a long horizontal rest every `longRestEveryMinutes`.
    var restGreen = 5, restYellow = 7, restRed = 10
    var longRestMinutes = 15, longRestEveryMinutes = 120
    // Night (user, Sep 25): from nightStartHour the computer "blinks" — nightBlock minutes of
    // work, nightBreak minutes of break — and from midnight it's off until morningHour.
    var nightStartHour = 22, morningHour = 6
    var nightBlockMinutes = 2, nightBreakMinutes = 10
    // The one daily cap: minutes on the computer (any active screen time, meetings included).
    var dailyCapMinutes = 480.0
    // Ramp: starting blocks +stepUpBlockMinutes after `cleanDaysToStepUp` clean days;
    // a step-down shortens them by `blockStep` for `stepDownDays`.
    var cleanDaysToStepUp = 3
    var stepUpBlockMinutes = 5
    var stepDownDays = 14
    // Symptom gate, on the 1–10 scale (10 = best). Only these answers count: energy and
    // overall dip for too many ordinary reasons (user, Sep 25: "it might mean go work out").
    var gateKeys = ["fog", "headache", "crashy"]
    var gateDropBy = 3                 // any gate score down this much vs its first reading today…
    var gateFloor = 3                  // …or at/below this → an hour off
    var gateRestMinutes = 60
    var gateStopsForDay = 2            // the second gate stop in a day ends the day
    var softenDropBy = 2               // down this much → shorter blocks, rest-only breaks
    // Bookkeeping.
    var experimentNumber = 1
    var experimentStarted = ""         // yyyy-MM-dd
    var reviewDate = ""                // yyyy-MM-dd
    var stepDownUntil = ""             // yyyy-MM-dd, while a step-down is in force
    var lastCreditedDay = ""           // last day judged clean/not
    var cleanStreak = 0
    var history: [String] = []         // human-readable ramp log

    static let file = Config.dir.appendingPathComponent("capacity.json")
    static func load() -> Capacity {
        if let c = lenientLoad(file, defaults: Capacity()) { return c }
        // Only if the file is truly missing or corrupt: keep a copy before starting fresh.
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.copyItem(at: file, to: file.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))"))
        }
        var c = Capacity()
        c.experimentStarted = Day.string(Date()); c.reviewDate = Day.string(Date().addingTimeInterval(14 * 86400))
        c.history.append("\(c.experimentStarted): experiment 1 starts — blocks \(c.blockGreen)/\(c.blockYellow)/\(c.blockRed), cap \(Int(c.dailyCapMinutes / 60)) h")
        c.save(); return c
    }
    func save() { saveJSON(self, to: Capacity.file) }

    /// Today's first block for a tier (a step shorter while a step-down is in force).
    func block(for tier: String) -> Int {
        let b = tier == "green" ? blockGreen : tier == "red" ? blockRed : blockYellow
        return max(blockMin, stepDownActive ? b - blockStep : b)
    }
    func rest(for tier: String) -> Int { tier == "green" ? restGreen : tier == "red" ? restRed : restYellow }
    var stepDownActive: Bool { !stepDownUntil.isEmpty && stepDownUntil >= Day.string(Date()) }
    var experimentLabel: String { "Experiment \(experimentNumber) · review \(Day.pretty(reviewDate))" }
}

// MARK: - Weighted load

struct DayLoad {
    var screen = 0.0              // all active computer minutes, meetings included: what the cap counts
    var weighted = 0.0            // weighted by kind of work: logged to learn which work costs most
    var focused = 0.0             // raw focused screen minutes (non-meeting, non-leisure)
    var meeting = 0.0             // meeting minutes (screen-detected or calendar, whichever is larger)
    var offscreen = 0.0           // reported paper/voice minutes (raw)
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
        l.screen = secs.values.reduce(0, +) / 60 - (secs["meeting"] ?? 0) / 60 + l.meeting
        let intense = countEvents(kind: "flag_intense", since: start, until: end) > 0
        l.weighted += l.meeting * (intense ? Weights.intenseMeeting : Weights.byCategory["meeting"]!)
        // Context switching: each heavy-switching hour adds a share of the day's screen load.
        let hoursWorked = max(1.0, (l.focused + l.meeting) / 60)
        l.weighted *= 1 + Double(heavySwitchHours(from: start, to: end)) / hoursWorked * Weights.contextSwitchPenalty
        // Off-screen work the user told us about: "minutes|what".
        for d in eventDetails(kind: "offscreen_work", since: start, until: end) {
            if let m = Double(d.split(separator: "|").first ?? "") { l.offscreen += m; l.weighted += m * Weights.offscreenWork }
        }
        return l
    }

    private func heavySwitchHours(from: Date, to: Date) -> Int {
        stride(from: from.timeIntervalSince1970, to: to.timeIntervalSince1970, by: 3600).filter {
            appSwitches(from: Date(timeIntervalSince1970: $0), to: Date(timeIntervalSince1970: $0 + 3600)) > Weights.contextSwitchThreshold
        }.count
    }
}
