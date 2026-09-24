import Foundation
import SQLite3

/// Local-only SQLite log. Nothing here ever leaves the Mac except the hourly
/// summary that goes to the "Energy log" calendar.
final class Store {
    static let shared = Store()
    private var db: OpaquePointer?
    private let q = DispatchQueue(label: "supervision.store")

    private init() {
        let path = Config.dir.appendingPathComponent("supervision.sqlite").path
        sqlite3_open(path, &db)
        exec("""
        CREATE TABLE IF NOT EXISTS samples(ts REAL, app TEXT, title TEXT, category TEXT, idle INTEGER);
        CREATE TABLE IF NOT EXISTS events(ts REAL, kind TEXT, detail TEXT);
        CREATE TABLE IF NOT EXISTS checkins(ts REAL, score INTEGER, context TEXT);
        CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
        CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
        CREATE TABLE IF NOT EXISTS symptoms(ts REAL, fog INTEGER, headache INTEGER, crashy INTEGER, context TEXT);
        CREATE TABLE IF NOT EXISTS baselines(day TEXT PRIMARY KEY, recovery INTEGER, rhr INTEGER, hrv REAL, sleep REAL);
        """)
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    func sample(app: String, title: String, category: String, idle: Bool) {
        q.async {
            var s: OpaquePointer?
            sqlite3_prepare_v2(self.db, "INSERT INTO samples VALUES(?,?,?,?,?)", -1, &s, nil)
            sqlite3_bind_double(s, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(s, 2, app, -1, Self.transient)
            sqlite3_bind_text(s, 3, title, -1, Self.transient)
            sqlite3_bind_text(s, 4, category, -1, Self.transient)
            sqlite3_bind_int(s, 5, idle ? 1 : 0)
            sqlite3_step(s); sqlite3_finalize(s)
        }
    }

    /// Every decision the app makes is logged with its reason. `supervision log` shows it.
    func event(_ kind: String, _ detail: String) {
        q.async {
            var s: OpaquePointer?
            sqlite3_prepare_v2(self.db, "INSERT INTO events VALUES(?,?,?)", -1, &s, nil)
            sqlite3_bind_double(s, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(s, 2, kind, -1, Self.transient)
            sqlite3_bind_text(s, 3, detail, -1, Self.transient)
            sqlite3_step(s); sqlite3_finalize(s)
        }
    }

    func checkin(score: Int, context: String) {
        q.async {
            var s: OpaquePointer?
            sqlite3_prepare_v2(self.db, "INSERT INTO checkins VALUES(?,?,?)", -1, &s, nil)
            sqlite3_bind_double(s, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int(s, 2, Int32(score))
            sqlite3_bind_text(s, 3, context, -1, Self.transient)
            sqlite3_step(s); sqlite3_finalize(s)
        }
    }

    /// Active (non-idle) seconds per category between two times. Samples are 5 s apart.
    func activeSeconds(from: Date, to: Date) -> [String: Double] {
        var out: [String: Double] = [:]
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT category, COUNT(*)*5.0 FROM samples WHERE ts>=? AND ts<? AND idle=0 GROUP BY category", -1, &s, nil)
            sqlite3_bind_double(s, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(s, 2, to.timeIntervalSince1970)
            while sqlite3_step(s) == SQLITE_ROW {
                out[String(cString: sqlite3_column_text(s, 0))] = sqlite3_column_double(s, 1)
            }
            sqlite3_finalize(s)
        }
        return out
    }

    /// What was actually worked on: minutes per (app, window title), active only.
    /// This is the raw material for the activity ledger and the calendar notes.
    func titleLedger(from: Date, to: Date, limit: Int = 12) -> [(app: String, title: String, category: String, minutes: Int)] {
        var out: [(String, String, String, Int)] = []
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT app, title, category, COUNT(*)*5/60 FROM samples WHERE ts>=? AND ts<? AND idle=0 AND title<>'' GROUP BY app, title HAVING COUNT(*)>=12 ORDER BY 4 DESC LIMIT ?", -1, &s, nil)
            sqlite3_bind_double(s, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(s, 2, to.timeIntervalSince1970)
            sqlite3_bind_int(s, 3, Int32(limit))
            while sqlite3_step(s) == SQLITE_ROW {
                out.append((String(cString: sqlite3_column_text(s, 0)), String(cString: sqlite3_column_text(s, 1)),
                            String(cString: sqlite3_column_text(s, 2)), Int(sqlite3_column_int(s, 3))))
            }
            sqlite3_finalize(s)
        }
        return out.map { (app: $0.0, title: Self.cleanTitle($0.1, app: $0.0), category: $0.2, minutes: $0.3) }
    }

    /// Strip the app-name suffixes browsers and editors add ("… - Google Docs - Comet").
    static func cleanTitle(_ t: String, app: String) -> String {
        var s = t
        for suffix in [" - \(app)", " — \(app)", " - Google Chrome", " - Google Docs", " - Google Sheets", " - Gmail", " — Mozilla Firefox"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Symptoms (1 = great … 5 = worst), after breaks and at check-ins

    func symptoms(fog: Int, headache: Int, crashy: Int, context: String) {
        q.async {
            var s: OpaquePointer?
            sqlite3_prepare_v2(self.db, "INSERT INTO symptoms VALUES(?,?,?,?,?)", -1, &s, nil)
            sqlite3_bind_double(s, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int(s, 2, Int32(fog)); sqlite3_bind_int(s, 3, Int32(headache)); sqlite3_bind_int(s, 4, Int32(crashy))
            sqlite3_bind_text(s, 5, context, -1, Self.transient)
            sqlite3_step(s); sqlite3_finalize(s)
        }
    }

    /// Readings for a day, oldest first: (time, fog, headache, crashy).
    func symptomReadings(day: Date) -> [(Date, Int, Int, Int)] {
        let start = Calendar.current.startOfDay(for: day), end = start.addingTimeInterval(86400)
        var out: [(Date, Int, Int, Int)] = []
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT ts, fog, headache, crashy FROM symptoms WHERE ts>=? AND ts<? ORDER BY ts", -1, &s, nil)
            sqlite3_bind_double(s, 1, start.timeIntervalSince1970); sqlite3_bind_double(s, 2, end.timeIntervalSince1970)
            while sqlite3_step(s) == SQLITE_ROW {
                out.append((Date(timeIntervalSince1970: sqlite3_column_double(s, 0)), Int(sqlite3_column_int(s, 1)), Int(sqlite3_column_int(s, 2)), Int(sqlite3_column_int(s, 3))))
            }
            sqlite3_finalize(s)
        }
        return out
    }

    // MARK: Baselines (one row per day from Whoop), for the day+2 ramp check

    func saveBaseline(day: String, recovery: Int, rhr: Int, hrv: Double, sleep: Double) {
        q.async {
            var s: OpaquePointer?
            sqlite3_prepare_v2(self.db, "INSERT OR REPLACE INTO baselines VALUES(?,?,?,?,?)", -1, &s, nil)
            sqlite3_bind_text(s, 1, day, -1, Self.transient)
            sqlite3_bind_int(s, 2, Int32(recovery)); sqlite3_bind_int(s, 3, Int32(rhr))
            sqlite3_bind_double(s, 4, hrv); sqlite3_bind_double(s, 5, sleep)
            sqlite3_step(s); sqlite3_finalize(s)
        }
    }

    func baseline(day: String) -> (recovery: Int, rhr: Int)? {
        var r: (Int, Int)?
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT recovery, rhr FROM baselines WHERE day=?", -1, &s, nil)
            sqlite3_bind_text(s, 1, day, -1, Self.transient)
            if sqlite3_step(s) == SQLITE_ROW { r = (Int(sqlite3_column_int(s, 0)), Int(sqlite3_column_int(s, 1))) }
            sqlite3_finalize(s)
        }
        return r
    }

    func medianRHR(days: Int) -> Int? {
        var v: [Int] = []
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT rhr FROM baselines WHERE rhr>0 ORDER BY day DESC LIMIT ?", -1, &s, nil)
            sqlite3_bind_int(s, 1, Int32(days))
            while sqlite3_step(s) == SQLITE_ROW { v.append(Int(sqlite3_column_int(s, 0))) }
            sqlite3_finalize(s)
        }
        guard !v.isEmpty else { return nil }
        return v.sorted()[v.count / 2]
    }

    /// Number of front-app changes in a window (context switching).
    func appSwitches(from: Date, to: Date) -> Int {
        var n = 0
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT app FROM samples WHERE ts>=? AND ts<? AND idle=0 ORDER BY ts", -1, &s, nil)
            sqlite3_bind_double(s, 1, from.timeIntervalSince1970); sqlite3_bind_double(s, 2, to.timeIntervalSince1970)
            var last = ""
            while sqlite3_step(s) == SQLITE_ROW {
                let a = String(cString: sqlite3_column_text(s, 0))
                if a != last { if !last.isEmpty { n += 1 }; last = a }
            }
            sqlite3_finalize(s)
        }
        return n
    }

    func countEvents(kind: String, since: Date, until: Date) -> Int {
        var n = 0
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events WHERE kind=? AND ts>=? AND ts<?", -1, &s, nil)
            sqlite3_bind_text(s, 1, kind, -1, Self.transient)
            sqlite3_bind_double(s, 2, since.timeIntervalSince1970); sqlite3_bind_double(s, 3, until.timeIntervalSince1970)
            if sqlite3_step(s) == SQLITE_ROW { n = Int(sqlite3_column_int(s, 0)) }
            sqlite3_finalize(s)
        }
        return n
    }

    func eventDetails(kind: String, since: Date, until: Date) -> [String] {
        var out: [String] = []
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT detail FROM events WHERE kind=? AND ts>=? AND ts<?", -1, &s, nil)
            sqlite3_bind_text(s, 1, kind, -1, Self.transient)
            sqlite3_bind_double(s, 2, since.timeIntervalSince1970); sqlite3_bind_double(s, 3, until.timeIntervalSince1970)
            while sqlite3_step(s) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(s, 0))) }
            sqlite3_finalize(s)
        }
        return out
    }

    /// Most recent event of a kind since a time, so state survives restarts.
    func lastEvent(kind: String, since: Date) -> (Date, String)? {
        var r: (Date, String)?
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT ts, detail FROM events WHERE kind=? AND ts>=? ORDER BY ts DESC LIMIT 1", -1, &s, nil)
            sqlite3_bind_text(s, 1, kind, -1, Self.transient)
            sqlite3_bind_double(s, 2, since.timeIntervalSince1970)
            if sqlite3_step(s) == SQLITE_ROW { r = (Date(timeIntervalSince1970: sqlite3_column_double(s, 0)), String(cString: sqlite3_column_text(s, 1))) }
            sqlite3_finalize(s)
        }
        return r
    }

    func eventDetails(kind: String, since: Date) -> [String] {
        var out: [String] = []
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT detail FROM events WHERE kind=? AND ts>=?", -1, &s, nil)
            sqlite3_bind_text(s, 1, kind, -1, Self.transient)
            sqlite3_bind_double(s, 2, since.timeIntervalSince1970)
            while sqlite3_step(s) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(s, 0))) }
            sqlite3_finalize(s)
        }
        return out
    }

    func countEvents(kind: String, since: Date) -> Int {
        var n = 0
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events WHERE kind=? AND ts>=?", -1, &s, nil)
            sqlite3_bind_text(s, 1, kind, -1, Self.transient)
            sqlite3_bind_double(s, 2, since.timeIntervalSince1970)
            if sqlite3_step(s) == SQLITE_ROW { n = Int(sqlite3_column_int(s, 0)) }
            sqlite3_finalize(s)
        }
        return n
    }

    func lastCheckin() -> (Date, Int)? {
        var r: (Date, Int)?
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT ts, score FROM checkins ORDER BY ts DESC LIMIT 1", -1, &s, nil)
            if sqlite3_step(s) == SQLITE_ROW {
                r = (Date(timeIntervalSince1970: sqlite3_column_double(s, 0)), Int(sqlite3_column_int(s, 1)))
            }
            sqlite3_finalize(s)
        }
        return r
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// Sorts what's on screen into kinds of work. Different kinds use different
/// parts of the brain, and the calendar summary is built from these.
enum Categorizer {
    static func category(app: String, title: String) -> String {
        let a = app.lowercased(), t = title.lowercased()
        if a.contains("zoom") || t.contains("zoom meeting") || t.contains("meet.google") || a.contains("facetime") { return "meeting" }
        if a.contains("slack") || a.contains("mail") || a.contains("messages") || t.contains("gmail") || t.contains("superhuman") || a.contains("whatsapp") { return "comms" }
        if t.contains("google docs") || t.contains("notion") || a.contains("pages") || a.contains("word") || a.contains("obsidian") || a.contains("notes") || a.contains("bear") || t.contains("google slides") { return "writing" }
        if t.contains("google sheets") || a.contains("excel") || a.contains("numbers") || t.contains("airtable") || t.contains("affinity") { return "analysis" }
        if a.contains("capcut") || a.contains("premiere") || a.contains("final cut") || a.contains("imovie") || a.contains("descript") || a.contains("davinci") || a.contains("canva") || t.contains("capcut") { return "video" }
        if a.contains("xcode") || a.contains("terminal") || a.contains("code") || a.contains("claude") || a.contains("cursor") || a.contains("iterm") { return "building" }
        if a.contains("spotify") || a.contains("music") || t.contains("youtube") || t.contains("netflix") || t.contains("twitter") || t.contains(" x ") || t.contains("instagram") || t.contains("reddit") { return "leisure" }
        if a.contains("safari") || a.contains("chrome") || a.contains("arc") || a.contains("firefox") || a.contains("comet") { return "reading" }
        if a.contains("calendar") || a.contains("finder") || a.contains("system settings") || a.contains("1password") { return "admin" }
        return "other"
    }
}
