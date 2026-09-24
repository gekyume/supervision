import Foundation
import SQLite3

// supervisionctl — the only way to pause, adjust or quit Supervision. Meant to be run by
// Claude from chat, so every override comes with a conversation and a reason.
//
//   supervisionctl pause <minutes> "<reason>"     no takeovers for a while
//   supervisionctl resume                          end a pause
//   supervisionctl budget +30 "<reason>"           adjust today's budget
//   supervisionctl allow-quit                      let the app exit for 2 minutes (updates)
//   supervisionctl set workMinutes 20 "<reason>"   change a config value
//   supervisionctl status                          today's numbers
//   supervisionctl log [n]                         last n decisions with reasons
//   supervisionctl report [days]                   per-day summary for the last n days

let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Supervision")
let controlFile = dir.appendingPathComponent("control.json")
let configFile = dir.appendingPathComponent("config.json")
let args = Array(CommandLine.arguments.dropFirst())

func readJSON(_ u: URL) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: u))) as? [String: Any] ?? [:]
}
func writeJSON(_ o: [String: Any], _ u: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]).write(to: u)
}
func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
func logEvent(_ kind: String, _ detail: String) {
    var db: OpaquePointer?
    sqlite3_open(dir.appendingPathComponent("supervision.sqlite").path, &db)
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, "INSERT INTO events VALUES(?,?,?)", -1, &s, nil)
    sqlite3_bind_double(s, 1, Date().timeIntervalSince1970)
    let t = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(s, 2, kind, -1, t); sqlite3_bind_text(s, 3, detail, -1, t)
    sqlite3_step(s); sqlite3_finalize(s); sqlite3_close(db)
}
func query(_ sql: String, _ row: (OpaquePointer?) -> Void) {
    var db: OpaquePointer?
    sqlite3_open(dir.appendingPathComponent("supervision.sqlite").path, &db)
    var s: OpaquePointer?
    if sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK { while sqlite3_step(s) == SQLITE_ROW { row(s) } }
    sqlite3_finalize(s); sqlite3_close(db)
}
func text(_ s: OpaquePointer?, _ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE MMM d HH:mm"; return f }()

var control = readJSON(controlFile)
switch args.first ?? "status" {
case "pause":
    let mins = Double(args.count > 1 ? args[1] : "15") ?? 15
    let reason = args.count > 2 ? args[2] : "no reason given"
    control["pauseUntil"] = Date().addingTimeInterval(mins * 60).timeIntervalSinceReferenceDate
    control["reason"] = reason
    writeJSON(control, controlFile)
    logEvent("override", "Claude paused Supervision for \(Int(mins)) min: \(reason)")
    print("Paused for \(Int(mins)) min. Reason logged: \(reason)")
case "resume":
    control["pauseUntil"] = nil; control["reason"] = ""
    writeJSON(control, controlFile); logEvent("override", "Claude resumed Supervision"); print("Resumed.")
case "budget":
    let delta = Double(args.count > 1 ? args[1] : "0") ?? 0
    let reason = args.count > 2 ? args[2] : "no reason given"
    control["extraBudgetMinutes"] = ((control["extraBudgetMinutes"] as? Double) ?? 0) + delta
    writeJSON(control, controlFile); logEvent("override", "Budget \(delta >= 0 ? "+" : "")\(Int(delta)) min today: \(reason)")
    print("Today's budget adjusted by \(Int(delta)) min.")
case "allow-quit":
    control["allowQuitUntil"] = Date().addingTimeInterval(120).timeIntervalSinceReferenceDate
    writeJSON(control, controlFile); logEvent("override", "Claude allowed quit for 2 min"); print("Quit allowed for 2 minutes.")
case "set":
    guard args.count >= 3, let v = Double(args[2]) else { print("usage: supervisionctl set <key> <number> \"reason\""); exit(1) }
    var cfg = readJSON(configFile); cfg[args[1]] = v; writeJSON(cfg, configFile)
    logEvent("config", "\(args[1]) = \(v): \(args.count > 3 ? args[3] : "no reason given")")
    print("\(args[1]) set to \(v). Supervision picks it up on next launch (supervisionctl allow-quit; launchd relaunches it).")
case "flag":
    // supervisionctl flag intense|travel|stress|crash|headache "note"   → one-tap facts that change today's budget / the record
    guard args.count >= 2, ["intense", "travel", "stress", "crash", "headache"].contains(args[1]) else { print("usage: supervisionctl flag intense|travel|stress|crash|headache \"note\""); exit(1) }
    logEvent("flag_\(args[1])", args.count > 2 ? args[2] : "flagged via Claude")
    print("Flagged \(args[1]) for today.")
case "offscreen":
    // supervisionctl offscreen 30 "memo on paper"   → work done off the computer (counts at half weight)
    guard args.count >= 2, let m = Double(args[1]) else { print("usage: supervisionctl offscreen <minutes> \"what\""); exit(1) }
    logEvent("offscreen_work", "\(Int(m))|\(args.count > 2 ? args[2] : "off-screen work")")
    print("Logged \(Int(m)) min of off-screen work.")
case "capacity":
    // supervisionctl capacity            → current experiment numbers and ramp history
    // supervisionctl capacity set baseGreen 200 "reason"
    let cf = dir.appendingPathComponent("capacity.json")
    var cap = readJSON(cf)
    if args.count >= 4, args[1] == "set", let v = Double(args[3]) {
        cap[args[2]] = v; writeJSON(cap, cf); logEvent("capacity", "\(args[2]) = \(v): \(args.count > 4 ? args[4] : "no reason given")")
        print("\(args[2]) set to \(v). Takes effect within a minute.")
    } else {
        print("\(cap["experimentNumber"] ?? 1) · review \(cap["reviewDate"] ?? "?") · clean streak \(cap["cleanStreak"] ?? 0)")
        print("blocks G/Y/R: \(cap["blockGreen"] ?? "")/\(cap["blockYellow"] ?? "")/\(cap["blockRed"] ?? "") min · base G/Y/R: \(cap["baseGreen"] ?? "")/\(cap["baseYellow"] ?? "")/\(cap["baseRed"] ?? "") weighted min")
        if let s = cap["stepDownUntil"] as? String, !s.isEmpty { print("step-down in force until \(s)") }
        for h in (cap["history"] as? [String] ?? []).suffix(8) { print("  " + h) }
    }
case "daily-json":
    // Machine-readable day summary for the nightly Airtable/Calendar sync. `daily-json [YYYY-MM-DD]`
    var dayStart = Calendar.current.startOfDay(for: Date())
    if args.count > 1 { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; if let d = f.date(from: args[1]) { dayStart = d } }
    let s0 = dayStart.timeIntervalSince1970, e0 = s0 + 86400
    var byCat: [String: Int] = [:]
    query("SELECT category, COUNT(*)*5/60 FROM samples WHERE ts>=\(s0) AND ts<\(e0) AND idle=0 GROUP BY category") { r in byCat[text(r, 0)] = Int(sqlite3_column_int(r, 1)) }
    var worked: [String] = []
    query("SELECT app, title, COUNT(*)*5/60 m FROM samples WHERE ts>=\(s0) AND ts<\(e0) AND idle=0 AND title<>'' GROUP BY app, title HAVING COUNT(*)>=12 ORDER BY m DESC LIMIT 20") { r in worked.append("\(sqlite3_column_int(r, 2))m \(text(r, 1).prefix(70)) [\(text(r, 0))]") }
    var breaks: [String] = [], flags: [String] = [], locks: [String] = []
    query("SELECT kind, detail FROM events WHERE ts>=\(s0) AND ts<\(e0) AND (kind='break_done' OR kind LIKE 'flag_%' OR kind='day_lock' OR kind='gate_stop' OR kind='override' OR kind='offscreen_work')") { r in
        let k = text(r, 0), d = text(r, 1)
        if k == "break_done" { breaks.append(String(d.split(separator: "|").first ?? "")) }
        else if k.hasPrefix("flag_") { flags.append(String(k.dropFirst(5))) }
        else if k == "offscreen_work" { flags.append("offscreen " + d.replacingOccurrences(of: "|", with: "m ")) }
        else { locks.append(k + ": " + String(d.prefix(120))) }
    }
    var sym: [[Int]] = []
    query("SELECT fog, headache, crashy FROM symptoms WHERE ts>=\(s0) AND ts<\(e0) ORDER BY ts") { r in sym.append([Int(sqlite3_column_int(r, 0)), Int(sqlite3_column_int(r, 1)), Int(sqlite3_column_int(r, 2))]) }
    var checkins: [Int] = []
    query("SELECT score FROM checkins WHERE ts>=\(s0) AND ts<\(e0)") { r in checkins.append(Int(sqlite3_column_int(r, 0))) }
    let weights: [String: Double] = ["admin": 0.8, "comms": 0.8, "reading": 1, "writing": 1, "analysis": 1, "building": 1, "video": 1.2, "meeting": 1.3, "other": 1, "leisure": 0]
    let weighted = byCat.reduce(0.0) { $0 + Double($1.value) * (weights[$1.key] ?? 1) }
    let focused = byCat.filter { $0.key != "leisure" && $0.key != "meeting" }.values.reduce(0, +)
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    let out: [String: Any] = ["date": f.string(from: dayStart), "weighted": Int(weighted), "focused": focused, "meeting": byCat["meeting"] ?? 0,
                              "byCategory": byCat, "workedOn": worked, "breaks": breaks, "flags": flags, "locks": locks,
                              "symptoms": sym, "checkins": checkins, "baseline": readJSON(dir.appendingPathComponent("baseline.json"))]
    if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) { print(String(data: d, encoding: .utf8)!) }
case "symptoms":
    let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    print("Today (1 = great … 5 = worst): time  fog  head  crashy")
    query("SELECT datetime(ts,'unixepoch','localtime'), fog, headache, crashy, context FROM symptoms WHERE ts>=\(start) ORDER BY ts") { r in
        print("  \(text(r, 0).suffix(8))   \(sqlite3_column_int(r, 1))    \(sqlite3_column_int(r, 2))     \(sqlite3_column_int(r, 3))   \(text(r, 4))")
    }
case "context":
    // supervisionctl context            → show current + available
    // supervisionctl context office  → switch for 8 h (Wi-Fi auto-switch resumes after)
    // supervisionctl context add-wifi office "Office WiFi"
    var ctx = readJSON(dir.appendingPathComponent("contexts.json"))
    var list = (ctx["contexts"] as? [[String: Any]]) ?? []
    if args.count == 1 {
        print("Current: \(ctx["current"] ?? "home")")
        for c in list { print("  \(c["name"] ?? "?"): \((c["activities"] as? [String] ?? []).joined(separator: ", "))  wifi=\((c["ssids"] as? [String] ?? []).joined(separator: "/"))") }
    } else if args[1] == "add-wifi", args.count >= 4 {
        for i in list.indices where (list[i]["name"] as? String) == args[2] { var s = list[i]["ssids"] as? [String] ?? []; s.append(args[3]); list[i]["ssids"] = s }
        ctx["contexts"] = list; writeJSON(ctx, dir.appendingPathComponent("contexts.json")); print("Added Wi-Fi '\(args[3])' to \(args[2]).")
    } else {
        guard list.contains(where: { ($0["name"] as? String) == args[1] }) else { print("unknown context; known: \(list.compactMap { $0["name"] as? String })"); exit(1) }
        ctx["current"] = args[1]; ctx["manualUntil"] = Date().addingTimeInterval(8 * 3600).timeIntervalSinceReferenceDate
        writeJSON(ctx, dir.appendingPathComponent("contexts.json")); logEvent("context", "Claude set context to '\(args[1])' for 8 h")
        print("Context: \(args[1]) for the next 8 hours.")
    }
case "baseline":
    // supervisionctl baseline                          → show
    // supervisionctl baseline 2026-09-23 86 51 67.8 7.7 "note"   → set (recovery, resting HR, HRV, sleep h)
    let bf = dir.appendingPathComponent("baseline.json")
    if args.count >= 4 {
        let b: [String: Any] = ["date": args[1], "recovery": Int(args[2]) ?? 0, "restingHR": Int(args[3]) ?? 0,
                                "hrv": args.count > 4 ? (Double(args[4]) ?? 0) : 0, "sleepHours": args.count > 5 ? (Double(args[5]) ?? 0) : 0,
                                "note": args.count > 6 ? args[6] : ""]
        writeJSON(b, bf); logEvent("baseline", "\(args[1]): recovery \(args[2]), RHR \(args[3])")
        var db: OpaquePointer?
        sqlite3_open(dir.appendingPathComponent("supervision.sqlite").path, &db)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS baselines(day TEXT PRIMARY KEY, recovery INTEGER, rhr INTEGER, hrv REAL, sleep REAL)", nil, nil, nil)
        sqlite3_exec(db, "INSERT OR REPLACE INTO baselines VALUES('\(args[1])', \(Int(args[2]) ?? 0), \(Int(args[3]) ?? 0), \(b["hrv"] ?? 0), \(b["sleepHours"] ?? 0))", nil, nil, nil)
        sqlite3_close(db)
        print("Baseline set for \(args[1]).")
    } else { print(readJSON(bf)) }
case "day":
    // Activity ledger: what was worked on, by kind of work, from window titles.
    // `supervisionctl day` = today; `supervisionctl day 2026-09-22`; `supervisionctl day 3` = last 3 days.
    var start = Calendar.current.startOfDay(for: Date()), end = Date()
    if args.count > 1 {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        if let d = f.date(from: args[1]) { start = d; end = d.addingTimeInterval(86400) }
        else if let n = Int(args[1]) { start = start.addingTimeInterval(-Double(n - 1) * 86400) }
    }
    let s = start.timeIntervalSince1970, e = end.timeIntervalSince1970
    let hf = DateFormatter(); hf.dateFormat = "EEE MMM d"
    print("Activity \(hf.string(from: start)) → \(hf.string(from: end.addingTimeInterval(-1)))")
    var byCat: [String: [(String, String, Int)]] = [:]
    query("SELECT category, app, title, COUNT(*)*5/60 m FROM samples WHERE ts>=\(s) AND ts<\(e) AND idle=0 AND title<>'' GROUP BY app, title HAVING COUNT(*)>=24 ORDER BY m DESC") { r in
        byCat[text(r, 0), default: []].append((text(r, 1), text(r, 2), Int(sqlite3_column_int(r, 3))))
    }
    var catMin: [(String, Int)] = []
    query("SELECT category, COUNT(*)*5/60 FROM samples WHERE ts>=\(s) AND ts<\(e) AND idle=0 GROUP BY category ORDER BY 2 DESC") { r in catMin.append((text(r, 0), Int(sqlite3_column_int(r, 1)))) }
    for (cat, mins) in catMin {
        print("\n\(cat.uppercased())  \(mins)m")
        for (app, title, m) in (byCat[cat] ?? []).prefix(10) {
            var t = title
            for suf in [" - \(app)", " — \(app)", " - Google Chrome", " - Google Docs", " - Google Sheets", " - Gmail"] where t.hasSuffix(suf) { t = String(t.dropLast(suf.count)) }
            print("  \(String(format: "%3d", m))m  \(t.prefix(70))  [\(app)]")
        }
    }
    var breaks = 0, overrides = 0
    query("SELECT SUM(kind='break_start'), SUM(kind='override') FROM events WHERE ts>=\(s) AND ts<\(e)") { r in breaks = Int(sqlite3_column_int(r, 0)); overrides = Int(sqlite3_column_int(r, 1)) }
    print("\nRests: \(breaks)   Overrides: \(overrides)")
    query("SELECT datetime(ts,'unixepoch','localtime'), score, context FROM checkins WHERE ts>=\(s) AND ts<\(e)") { r in print("Check-in \(text(r, 0)): \(sqlite3_column_int(r, 1))/5  (\(text(r, 2)))") }
case "log":
    let n = Int(args.count > 1 ? args[1] : "30") ?? 30
    query("SELECT ts, kind, detail FROM events ORDER BY ts DESC LIMIT \(n)") { s in
        print("\(df.string(from: Date(timeIntervalSince1970: sqlite3_column_double(s, 0))))  \(text(s, 1).padding(toLength: 14, withPad: " ", startingAt: 0))  \(text(s, 2))")
    }
case "report":
    let days = Int(args.count > 1 ? args[1] : "7") ?? 7
    let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(days - 1) * 86400).timeIntervalSince1970
    print("day         focused  meetings  leisure  breaks  overrides  checkin")
    query("""
        SELECT date(ts,'unixepoch','localtime') d,
          SUM(CASE WHEN idle=0 AND category NOT IN ('leisure','meeting') THEN 5 ELSE 0 END)/60,
          SUM(CASE WHEN idle=0 AND category='meeting' THEN 5 ELSE 0 END)/60,
          SUM(CASE WHEN idle=0 AND category='leisure' THEN 5 ELSE 0 END)/60,
          (SELECT COUNT(*) FROM events e WHERE e.kind='break_start' AND date(e.ts,'unixepoch','localtime')=d),
          (SELECT COUNT(*) FROM events e WHERE e.kind='override' AND date(e.ts,'unixepoch','localtime')=d),
          (SELECT ROUND(AVG(score),1) FROM checkins c WHERE date(c.ts,'unixepoch','localtime')=d)
        FROM samples WHERE ts >= \(start) GROUP BY d ORDER BY d
        """) { s in
        print("\(text(s, 0))  \(String(format: "%6d", sqlite3_column_int(s, 1)))   \(String(format: "%6d", sqlite3_column_int(s, 2)))   \(String(format: "%6d", sqlite3_column_int(s, 3)))  \(String(format: "%5d", sqlite3_column_int(s, 4)))  \(String(format: "%8d", sqlite3_column_int(s, 5)))     \(text(s, 6))")
    }
    print("\nBy category (minutes):")
    query("SELECT category, SUM(5)/60 FROM samples WHERE ts >= \(start) AND idle=0 GROUP BY category ORDER BY 2 DESC") { s in
        print("  \(text(s, 0).padding(toLength: 10, withPad: " ", startingAt: 0)) \(sqlite3_column_int(s, 1))")
    }
default:
    let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    var focused = 0, meeting = 0
    query("SELECT SUM(CASE WHEN category NOT IN ('leisure','meeting') THEN 5 ELSE 0 END)/60, SUM(CASE WHEN category='meeting' THEN 5 ELSE 0 END)/60 FROM samples WHERE ts>=\(today) AND idle=0") { s in
        focused = Int(sqlite3_column_int(s, 0)); meeting = Int(sqlite3_column_int(s, 1))
    }
    let cap = readJSON(dir.appendingPathComponent("capacity.json"))
    let bl = readJSON(dir.appendingPathComponent("baseline.json"))
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    let rec = (bl["date"] as? String) == f.string(from: Date()) ? (bl["recovery"] as? Int) : nil
    let tier = rec.map { $0 >= 67 ? "green" : $0 >= 34 ? "yellow" : "red" } ?? "unknown (treated as yellow)"
    print("Today: \(focused) screen min, \(meeting) meeting min. Whoop \(rec.map(String.init) ?? "—") → \(tier). Experiment \(cap["experimentNumber"] ?? 1), review \(cap["reviewDate"] ?? "?"). Blocks G/Y/R \(cap["blockGreen"] ?? 30)/\(cap["blockYellow"] ?? 25)/\(cap["blockRed"] ?? 15), base \(cap["baseGreen"] ?? 180)/\(cap["baseYellow"] ?? 150)/\(cap["baseRed"] ?? 90) weighted.")
    if let p = control["pauseUntil"] as? Double, p > Date().timeIntervalSinceReferenceDate {
        print("Paused until \(df.string(from: Date(timeIntervalSinceReferenceDate: p))): \(control["reason"] ?? "")")
    }
    print("Last decisions:")
    query("SELECT ts, kind, detail FROM events ORDER BY ts DESC LIMIT 5") { s in
        print("  \(df.string(from: Date(timeIntervalSince1970: sqlite3_column_double(s, 0))))  \(text(s, 1))  \(text(s, 2))")
    }
}
