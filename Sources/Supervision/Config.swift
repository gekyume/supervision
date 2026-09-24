import Foundation

/// All tunable numbers live here. Edited only through Claude (supervisionctl) so every
/// change has a logged reason — that's what keeps the app believable.
struct Config: Codable {
    var workMinutes: Double = 15          // ~50% of a ~30 min tolerance (RTHM 50% rule)
    var breakMinutes: Double = 10         // real rest: lie down, eyes closed, no screens
    var nudgeMinutesBefore: Double = 2    // gentle heads-up before the takeover
    var zoomBufferMinutes: Double = 10    // no takeovers this close to a video meeting
    var dailyBudgetMinutes: Double = 120  // focused computer minutes per day; meetings count 1:1
    var idleResetMinutes: Double = 8      // being away this long counts as a break taken
    var checkInHours: [Int] = [13, 18]    // one-tap "how's your head?" — never more than this
    var swapBreakMaxLoadPercent: Double = 40 // offer walk/rap/craft only when day load is below this

    static let dir: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Supervision")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let file = dir.appendingPathComponent("config.json")

    static func load() -> Config {
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(Config.self, from: d) {
            return c
        }
        let c = Config()
        c.save()
        return c
    }

    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: Config.file)
    }
}

/// Written only by `supervisionctl` (i.e. by Claude in chat). The app never writes it.
struct Control: Codable {
    var pauseUntil: Date? = nil      // no takeovers until this time
    var reason: String = ""
    var allowQuitUntil: Date? = nil  // the app may exit (for updates) until this time
    var extraBudgetMinutes: Double = 0 // one-day budget adjustment, reset nightly

    static let file = Config.dir.appendingPathComponent("control.json")
    static func load() -> Control {
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(Control.self, from: d) { return c }
        return Control()
    }
    var isPaused: Bool { if let p = pauseUntil { return p > Date() } else { return false } }
    var mayQuit: Bool { if let q = allowQuitUntil { return q > Date() } else { return false } }
}

/// Personal settings that don't belong in code. Read leniently so a missing key
/// just means the default. Lives next to config.json.
enum Profile {
    static let file = Config.dir.appendingPathComponent("profile.json")
    private static var values: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
    }
    /// Name of the calendar the hourly log is written to.
    static var logCalendarName: String { values["logCalendar"] as? String ?? "Energy log" }
}
