import Foundation
import SQLite3

/// Local-only SQLite log. Nothing here leaves the Mac except the calendar log and
/// whatever integrations the user sets up (via supervisionctl daily-json).
final class Store {
    static let shared = Store()
    private var db: OpaquePointer?
    private let q = DispatchQueue(label: "supervision.store")

    private init() {
        sqlite3_open(Paths.database.path, &db)
        exec("""
        CREATE TABLE IF NOT EXISTS samples(ts REAL, app TEXT, title TEXT, category TEXT, idle INTEGER);
        CREATE TABLE IF NOT EXISTS events(ts REAL, kind TEXT, detail TEXT);
        CREATE TABLE IF NOT EXISTS checkins(ts REAL, score INTEGER, context TEXT);   -- historical (old head check-in card)
        CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
        CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
        CREATE TABLE IF NOT EXISTS symptoms(ts REAL, fog INTEGER, headache INTEGER, crashy INTEGER, context TEXT);
        CREATE TABLE IF NOT EXISTS quickchecks(ts REAL, fog INTEGER, tired INTEGER, crashy INTEGER);
        """)
        exec(Schema.baselines); exec(Schema.adapt)
        // Later columns (errors if they already exist are harmless). `scale` NULL = old 1–5 rows.
        for t in ["quickchecks", "symptoms"] { exec("ALTER TABLE \(t) ADD COLUMN overall INTEGER"); exec("ALTER TABLE \(t) ADD COLUMN scale TEXT") }
        exec("ALTER TABLE quickchecks ADD COLUMN headache INTEGER")
        exec("ALTER TABLE symptoms ADD COLUMN tired INTEGER")
        for t in ["quickchecks", "symptoms"] { exec("ALTER TABLE \(t) ADD COLUMN note TEXT") }   // one-liner: "drank water", "ate"
        exec("ALTER TABLE checkins ADD COLUMN scale TEXT")
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

    /// Every decision the app makes is logged with its reason. `supervisionctl log` shows it.
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
        return out.map { (app: $0.0, title: cleanTitle($0.1, app: $0.0), category: $0.2, minutes: $0.3) }
    }

    // MARK: Symptoms — 1 = feeling the worst … 10 = feeling the best

    /// Save one set of answers (keys from `Questions.columns`; any may be missing = skipped)
    /// plus an optional one-line note about what the user did ("drank water").
    /// Corner checks go to `quickchecks`, after-break answers to `symptoms` (with a context).
    func saveAnswers(_ a: [String: Int], note: String, afterBreak: Bool, context: String = "") {
        q.async {
            var s: OpaquePointer?
            let sql = afterBreak
                ? "INSERT INTO symptoms(ts, fog, tired, headache, crashy, overall, note, scale, context) VALUES(?,?,?,?,?,?,?,'\(Scale.tag)',?)"
                : "INSERT INTO quickchecks(ts, fog, tired, headache, crashy, overall, note, scale) VALUES(?,?,?,?,?,?,?,'\(Scale.tag)')"
            sqlite3_prepare_v2(self.db, sql, -1, &s, nil)
            sqlite3_bind_double(s, 1, Date().timeIntervalSince1970)
            for (i, k) in Questions.columns.enumerated() {
                if let v = a[k] { sqlite3_bind_int(s, Int32(i + 2), Int32(v)) } else { sqlite3_bind_null(s, Int32(i + 2)) }
            }
            if note.isEmpty { sqlite3_bind_null(s, 7) } else { sqlite3_bind_text(s, 7, note, -1, Self.transient) }
            if afterBreak { sqlite3_bind_text(s, 8, context, -1, Self.transient) }
            sqlite3_step(s); sqlite3_finalize(s)
        }
    }

    /// 1–10 readings for a day (after-break AND corner checks together), oldest first.
    /// Keys from `Questions.columns` — only the ones that were answered.
    func symptomReadings(day: Date) -> [(Date, [String: Int])] {
        let start = Calendar.current.startOfDay(for: day), end = start.addingTimeInterval(86400)
        var out: [(Date, [String: Int])] = []
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, """
                SELECT ts, fog, tired, headache, crashy, overall FROM symptoms WHERE ts>=? AND ts<? AND scale='\(Scale.tag)'
                UNION ALL
                SELECT ts, fog, tired, headache, crashy, overall FROM quickchecks WHERE ts>=? AND ts<? AND scale='\(Scale.tag)'
                ORDER BY ts
                """, -1, &s, nil)
            sqlite3_bind_double(s, 1, start.timeIntervalSince1970); sqlite3_bind_double(s, 2, end.timeIntervalSince1970)
            sqlite3_bind_double(s, 3, start.timeIntervalSince1970); sqlite3_bind_double(s, 4, end.timeIntervalSince1970)
            while sqlite3_step(s) == SQLITE_ROW {
                var r: [String: Int] = [:]
                for (i, k) in Questions.columns.enumerated() where sqlite3_column_type(s, Int32(i + 1)) != SQLITE_NULL {
                    r[k] = Int(sqlite3_column_int(s, Int32(i + 1)))
                }
                out.append((Date(timeIntervalSince1970: sqlite3_column_double(s, 0)), r))
            }
            sqlite3_finalize(s)
        }
        return out
    }

    /// The most recent "overall" answer today (after a break or from the corner), if any.
    func latestOverallToday() -> Int? { symptomReadings(day: Date()).last(where: { $0.1["overall"] != nil })?.1["overall"] }

    /// Focused seconds in the current uninterrupted stretch of work (no gap ≥ `gap`),
    /// bounded by the last break. Lets the block counter survive a restart.
    func currentStretchSeconds(gap: Double, since floor: Date) -> Double {
        var secs = 0.0
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT ts FROM samples WHERE ts>=? AND idle=0 ORDER BY ts DESC", -1, &s, nil)
            sqlite3_bind_double(s, 1, floor.timeIntervalSince1970)
            var last = Date().timeIntervalSince1970
            while sqlite3_step(s) == SQLITE_ROW {
                let t = sqlite3_column_double(s, 0)
                if last - t > gap { break }
                secs += 5; last = t
            }
            sqlite3_finalize(s)
        }
        return secs
    }

    /// When any of these apps was last in front (active samples).
    func lastAppUse(names: [String]) -> Date? {
        var t: Double?
        q.sync {
            var s: OpaquePointer?
            let likes = names.map { _ in "app LIKE ?" }.joined(separator: " OR ")
            sqlite3_prepare_v2(db, "SELECT MAX(ts) FROM samples WHERE idle=0 AND (\(likes))", -1, &s, nil)
            for (i, n) in names.enumerated() { sqlite3_bind_text(s, Int32(i + 1), "%\(n)%", -1, Self.transient) }
            if sqlite3_step(s) == SQLITE_ROW, sqlite3_column_type(s, 0) != SQLITE_NULL { t = sqlite3_column_double(s, 0) }
            sqlite3_finalize(s)
        }
        return t.map { Date(timeIntervalSince1970: $0) }
    }

    /// The most-used apps (active time) in the last `days`, most first: the app picker's list.
    func topApps(days: Int, minMinutes: Int, limit: Int) -> [String] {
        var out: [String] = []
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT app FROM samples WHERE ts>=? AND idle=0 GROUP BY app HAVING COUNT(*)*5 >= ? ORDER BY COUNT(*) DESC LIMIT ?", -1, &s, nil)
            sqlite3_bind_double(s, 1, Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970)
            sqlite3_bind_int(s, 2, Int32(minMinutes * 60)); sqlite3_bind_int(s, 3, Int32(limit))
            while sqlite3_step(s) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(s, 0))) }
            sqlite3_finalize(s)
        }
        return out
    }

    /// Today's logged ADaPT sessions (from Whoop workouts).
    func adaptSessionsToday() -> [AdaptSession] {
        var out: [AdaptSession] = []
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT day, minutes, avg_hr, max_hr, mode FROM adapt WHERE day = ?", -1, &s, nil)
            sqlite3_bind_text(s, 1, Day.string(Date()), -1, Self.transient)
            while sqlite3_step(s) == SQLITE_ROW {
                let opt: (Int32) -> Int? = { sqlite3_column_type(s, $0) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, $0)) }
                out.append(AdaptSession(day: String(cString: sqlite3_column_text(s, 0)), minutes: Int(sqlite3_column_int(s, 1)),
                                        avgHR: opt(2), maxHR: opt(3), mode: String(cString: sqlite3_column_text(s, 4))))
            }
            sqlite3_finalize(s)
        }
        return out
    }

    /// Days with a logged ADaPT session since a date (yyyy-MM-dd strings).
    func adaptSessionDays(since: Date) -> Set<String> {
        var out = Set<String>()
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT DISTINCT day FROM adapt WHERE day >= ?", -1, &s, nil)
            sqlite3_bind_text(s, 1, Day.string(since), -1, Self.transient)
            while sqlite3_step(s) == SQLITE_ROW { out.insert(String(cString: sqlite3_column_text(s, 0))) }
            sqlite3_finalize(s)
        }
        return out
    }

    // MARK: Baselines (one row per day, written by `supervisionctl baseline`), for the day+2 ramp check

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

    func eventDetails(kind: String, since: Date) -> [String] { eventDetails(kind: kind, since: since, until: .distantFuture) }
    func countEvents(kind: String, since: Date) -> Int { countEvents(kind: kind, since: since, until: .distantFuture) }

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
