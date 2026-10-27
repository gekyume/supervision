import Foundation

// Compiled into both the app and supervisionctl, so the two can never disagree about
// where data lives, how a recovery score maps to a tier, or what a kind of work weighs.

enum Paths {
    static let dir: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Supervision")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let database = dir.appendingPathComponent("supervision.sqlite")
}

/// Tables both the app and supervisionctl write. Defined once so they can never drift apart.
enum Schema {
    static let adapt = "CREATE TABLE IF NOT EXISTS adapt(day TEXT, minutes INTEGER, avg_hr INTEGER, max_hr INTEGER, mode TEXT, logged REAL, UNIQUE(day, mode, minutes))"
    static let baselines = "CREATE TABLE IF NOT EXISTS baselines(day TEXT PRIMARY KEY, recovery INTEGER, rhr INTEGER, hrv REAL, sleep REAL)"
}

/// Morning recovery → tier, using Whoop's own bands. No reading = "unknown", treated as yellow.
enum Tier {
    static func from(recovery: Int?) -> String {
        guard let r = recovery else { return "unknown" }
        return r >= 67 ? "green" : r >= 34 ? "yellow" : "red"
    }
    static let rank = ["red": 0, "yellow": 1, "green": 2, "unknown": 1]
}

/// Kinds of work cost different amounts. First guesses, reviewed every fortnight.
enum Weights {
    static let byCategory: [String: Double] = [
        "admin": 0.8, "comms": 0.8, "reading": 1.0, "writing": 1.0, "analysis": 1.0, "building": 1.0,
        "video": 1.2, "meeting": 1.3, "other": 1.0, "leisure": 0.0,
    ]
    static let intenseMeeting = 1.6
    static let contextSwitchPenalty = 0.10    // extra share of the day's load per heavy-switching hour
    static let contextSwitchThreshold = 20    // app changes in an hour that count as heavy
    static let offscreenWork = 0.5            // paper / voice work the user reports
}

/// Every symptom question is 1 = feeling the worst … 10 = feeling the best.
/// Rows written before Sep 25 2026 used 1 = best … 5 = worst and have no tag.
enum Scale {
    static let tag = "1-10 best=10"
    static let label = "1 = worst · 10 = best, on every row"
}

enum Day {
    private static let ymd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    private static let short: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
    static func string(_ d: Date) -> String { ymd.string(from: d) }
    static func date(_ s: String) -> Date? { ymd.date(from: s) }
    static func pretty(_ s: String) -> String { date(s).map { short.string(from: $0) } ?? s }
    static var today: Date { Calendar.current.startOfDay(for: Date()) }
    private static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
    /// "2:35 PM", for messages that name a time.
    static func clock(_ d: Date) -> String { hm.string(from: d) }
}

/// Strip the app-name suffixes browsers and editors add ("… - Google Docs - Comet").
func cleanTitle(_ t: String, app: String) -> String {
    var s = t
    for suffix in [" - \(app)", " — \(app)", " - Google Chrome", " - Google Docs", " - Google Sheets", " - Gmail", " — Mozilla Firefox"] where s.hasSuffix(suffix) {
        s = String(s.dropLast(suffix.count))
    }
    return s.trimmingCharacters(in: .whitespaces)
}
