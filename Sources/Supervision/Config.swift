import Foundation

/// Decode `T` from `file`, starting from `defaults` and overlaying the keys the file has
/// (including optionals the defaults leave out). Missing keys keep their defaults and
/// unknown keys are ignored, so renaming a setting can never make a file unreadable.
func lenientLoad<T: Codable>(_ file: URL, defaults: T) -> T? {
    guard let d = try? Data(contentsOf: file),
          let fileDict = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          let baseData = try? JSONEncoder().encode(defaults),
          var merged = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any] else { return nil }
    for (k, v) in fileDict { merged[k] = v }
    guard let m = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
    return try? JSONDecoder().decode(T.self, from: m)
}

func saveJSON<T: Encodable>(_ value: T, to file: URL) {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? e.encode(value).write(to: file)
}

/// Timing settings that aren't part of the adaptive model (that's `Capacity`).
/// Changed through `supervisionctl set`, so every change has a logged reason.
struct Config: Codable {
    var nudgeMinutesBefore: Double = 2    // gentle heads-up before the takeover
    var zoomBufferMinutes: Double = 10    // no takeovers this close to a calendar video meeting
    var idleResetMinutes: Double = 8      // being away this long counts as a break taken
    var maxDeferralMinutes: Double = 60   // camera/mic/window signals can postpone a break this long
    var phoneUnlockStatement = "I understand I am breaking my own policy for health"   // typed on the lock screen
    var eyeEveryMinutes: Double = 20      // 20-20-20: a look-away after this much focused time (0 = off)
    var eyeSeconds = 20
    var eyeBlinks = 20                    // the eye break ends after this many blinks (camera; 0 = timer only)
    var eyeMaxSeconds: Double = 60        // never longer than this
    var eyeNoticeSeconds: Double = 30
    var workoutOn = true                  // once a day the first break after `workoutAfterHour` is a counted workout (not red days)
    var workoutAfterHour = 11
    var workoutStandingReps = 8              // standing set (office): per leg
    var workoutPromiseOn = true              // "I promise I did it" (honour system, reviewed weekly; false removes it)
    var workoutBridges = 8, workoutClamshells = 10   // lying-down set (POTS-friendly); clamshells per side; grow only if the mornings after look fine
    var workoutStopStatement = "I am stopping my workout even though it is part of my plan"
    var microEveryMinutes: Double = 30    // a 10-s stand + reach micro-break this often (focused time; 0 = off)
    var microHoldSeconds: Double = 10
    var microSkipStatement = "I am skipping this stretch even though moving helps me"    // a small heads-up card this long before it
    var eyeSkipStatement = "I am ignoring this eye break even though it is good for my health"
    var appGateOn = true                  // after each break, pick this block's apps (user, Oct 24)
    var appGateAlways = ["com.electron.wispr-flow", "com.granola.app", "screenpi.pe", "com.tinyspeck.slackmacgap"]
    var appPickLimit = 3                  // free picks per block; more need the typed statement (0 = no limit)   // never on the picker, never blocked
    var switchThreshold = 25              // app switches in `switchWindowMinutes` that bring one gentle card (0 = off)
    var switchWindowMinutes: Double = 10
    var switchCooldownMinutes: Double = 30
    var moveCheckOn = true                // each regular break starts with a camera-checked stand + reach (seated on red days)
    var avoidWatch = ["Beeper", "Superhuman", "Messages", "WhatsApp", "Mail", "Reminders", "Things", "Todoist"]   // texts, email, to-do: unread here + not opened = maybe tired
    var sheetSyncId = ""                  // the user's data spreadsheet; empty = no sync from the app
    var sheetSyncHour = 21.5              // nightly sync from 9:30 pm (catches up the next morning if the Mac slept)
    var insightsOn = true                 // one observation a day from the digest (Claude), with 👍 / 👎
    var cleanSlateAwayMinutes = 60        // this long away (idle, asleep, or a Supervision lock) also clears (0 = off)
    var cleanSlateHour = 4                // apps quit + Chrome tabs saved and closed each morning (-1 = off)
    var cleanSlateBrowsers = ["ai.perplexity.comet", "com.google.Chrome"]   // tabs saved, then closed
    var cleanSlateKeep = ["com.apple.finder", "com.anthropic.claudefordesktop", "screenpi.pe", "com.electron.wispr-flow", "com.granola.app", "com.spotify.client", "com.apple.Music"]

    static let dir = Paths.dir
    static let file = dir.appendingPathComponent("config.json")
    static func load() -> Config { lenientLoad(file, defaults: Config()) ?? { let c = Config(); saveJSON(c, to: file); return c }() }
}

/// Written only by `supervisionctl` (i.e. by Claude in chat). The app only resets
/// the one-day budget adjustment at midnight.
struct Control: Codable {
    var pauseUntil: Date? = nil        // no takeovers until this time
    var reason: String = ""
    var allowQuitUntil: Date? = nil    // the app may exit (for updates) until this time
    var extraBudgetMinutes: Double = 0 // one-day budget adjustment, reset nightly
    var syncNow = false                // `supervisionctl sync`: run the nightly sheet sync now (then cleared)
    var workoutNow = false             // `supervisionctl workout [reps]`: the workout screen now (to try it)
    var workoutTryReps = 0             // with `workout <n>`: n reps of each for a quick test
    var microNow = false               // `supervisionctl stretch`: a micro stretch now (to try it), then cleared
    var eyeNow = false                 // `supervisionctl eye`: an eye break now (to try it), then cleared
    var breakNowMinutes: Double = 0    // `supervisionctl break`: start a break of this length now (then cleared)

    static let file = Config.dir.appendingPathComponent("control.json")
    static func load() -> Control { lenientLoad(file, defaults: Control()) ?? Control() }
    var isPaused: Bool { pauseUntil.map { $0 > Date() } ?? false }
    var mayQuit: Bool { allowQuitUntil.map { $0 > Date() } ?? false }
}

/// Personal settings that don't belong in code (profile.json, next to config.json).
enum Profile {
    static let file = Config.dir.appendingPathComponent("profile.json")
    private static var values: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
    }
    /// Name of the calendar the hourly log is written to.
    static var logCalendarName: String { values["logCalendar"] as? String ?? "Energy log" }
}
