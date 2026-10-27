import Foundation
import SQLite3

// supervisionctl — the only way to pause, adjust or quit Supervision. Meant to be run by
// Claude from chat, so every override comes with a conversation and a reason.
//
//   status | day [date|N] | report [days] | log [n] | symptoms | capacity | daily-json [date]
//   pause <min> "why" | resume | budget ±N "why" | allow-quit
//   flag intense|travel|stress|crash|headache "note" | offscreen <min> "what"
//   context [name | add-wifi <name> "<ssid>"] | baseline <date> <recovery> <rhr> <hrv> <sleepH> "source"
//   set <nudgeMinutesBefore|zoomBufferMinutes|idleResetMinutes|maxDeferralMinutes> <n> "why"
//   capacity set <key> <n> "why"

let dir = Paths.dir
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
func logEvent(_ kind: String, _ detail: String) {
    var db: OpaquePointer?
    sqlite3_open(Paths.database.path, &db)
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, "INSERT INTO events VALUES(?,?,?)", -1, &s, nil)
    sqlite3_bind_double(s, 1, Date().timeIntervalSince1970)
    let t = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(s, 2, kind, -1, t); sqlite3_bind_text(s, 3, detail, -1, t)
    sqlite3_step(s); sqlite3_finalize(s); sqlite3_close(db)
}
func query(_ sql: String, _ row: (OpaquePointer?) -> Void) {
    var db: OpaquePointer?
    sqlite3_open(Paths.database.path, &db)
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
case "break":
    // supervisionctl break <min> "why"   → start a break now (ends any pause)
    let mins = Double(args.count > 1 ? args[1] : "5") ?? 5
    let reason = args.count > 2 ? args[2] : "no reason given"
    control["pauseUntil"] = nil; control["breakNowMinutes"] = mins; control["reason"] = reason
    writeJSON(control, controlFile)
    logEvent("override", "Claude started a \(Int(mins))-min break: \(reason)")
    print("Break of \(Int(mins)) min starts within 5 s.")
case "sync":
    // supervisionctl sync   → the app runs tonight's sheet sync now
    control["syncNow"] = true; writeJSON(control, controlFile)
    logEvent("override", "Claude asked for a sheet sync now"); print("Sheet sync starts within 5 s (takes a few minutes).")
case "workout":
    // supervisionctl workout   → the workout screen now (push-ups, clamshells), to try it
    control["workoutNow"] = true; control["workoutTryReps"] = args.count > 1 ? (Int(args[1]) ?? 0) : 0; writeJSON(control, controlFile)
    logEvent("override", "Claude started a workout to try it"); print("Workout screen opens within 5 s. Prop your iPhone on the floor nearby to use it as the camera.")
case "stretch":
    // supervisionctl stretch   → a micro stretch now, to try it
    control["microNow"] = true; writeJSON(control, controlFile)
    logEvent("override", "Claude started a micro stretch to try it"); print("Micro stretch starts within 5 s.")
case "eye":
    // supervisionctl eye   → an eye break now, to try it
    control["eyeNow"] = true; writeJSON(control, controlFile)
    logEvent("override", "Claude started an eye break to try it"); print("Eye break starts within 5 s.")
case "digest":
    // supervisionctl digest [days]  → one line per day: the raw material for noticing patterns
    // (the app's daily insight and Claude's weekly review read this).
    let n = Int(args.count > 1 ? args[1] : "21") ?? 21
    print("day        | whoop rec/rhr/hrv/sleepH | computer min (after 10pm) | breaks rested/did/ended-early/skipped | eye done/skipped | switches avg-per-10min (bursts) | phone unlocks / chat pauses | check-ins overall,head,clear,crash first→last | flags & gate")
    for i in stride(from: n - 1, through: 0, by: -1) {
        let d0 = Day.today.addingTimeInterval(-Double(i) * 86400), ds = Day.string(d0)
        let s0 = d0.timeIntervalSince1970, e0 = s0 + 86400
        var whoop = "–"
        query("SELECT recovery, rhr, hrv, sleep FROM baselines WHERE day='\(ds)'") { r in whoop = "\(sqlite3_column_int(r, 0))/\(sqlite3_column_int(r, 1))/\(String(format: "%.0f", sqlite3_column_double(r, 2)))/\(String(format: "%.1f", sqlite3_column_double(r, 3)))" }
        var comp = 0, late = 0
        query("SELECT COUNT(*)*5/60, SUM(CASE WHEN CAST(strftime('%H',ts,'unixepoch','localtime') AS INT)>=22 THEN 5 ELSE 0 END)/60 FROM samples WHERE ts>=\(s0) AND ts<\(e0) AND idle=0") { r in comp = Int(sqlite3_column_int(r, 0)); late = Int(sqlite3_column_int(r, 1)) }
        var br = [String: Int]()
        query("SELECT detail FROM events WHERE kind='break_done' AND ts>=\(s0) AND ts<\(e0)") { r in br[String(text(r, 0).split(separator: "|").last ?? ""), default: 0] += 1 }
        var eyeDone = 0, eyeSkip = 0
        query("SELECT SUM(detail NOT LIKE 'skipped%'), SUM(detail LIKE 'skipped%') FROM events WHERE kind='eye_break' AND ts>=\(s0) AND ts<\(e0)") { r in eyeDone = Int(sqlite3_column_int(r, 0)); eyeSkip = Int(sqlite3_column_int(r, 1)) }
        var sw: [Double] = []; var bursts = 0
        query("SELECT kind, detail FROM events WHERE kind IN ('block_switches','switch_burst') AND ts>=\(s0) AND ts<\(e0)") { r in
            if text(r, 0) == "switch_burst" { bursts += 1; return }
            let p = text(r, 1).split(separator: "|").compactMap { Double($0) }
            if p.count == 2, p[1] >= 10 { sw.append(p[0] / p[1] * 10) }
        }
        var phone = 0, chat = 0
        query("SELECT SUM(detail LIKE 'iPhone unlock%'), SUM(detail LIKE 'Claude paused%') FROM events WHERE kind='override' AND ts>=\(s0) AND ts<\(e0)") { r in phone = Int(sqlite3_column_int(r, 0)); chat = Int(sqlite3_column_int(r, 1)) }
        var rows: [[String]] = []
        query("""
            SELECT ts, overall, headache, fog, crashy FROM symptoms WHERE ts>=\(s0) AND ts<\(e0) AND scale='\(Scale.tag)'
            UNION ALL SELECT ts, overall, headache, fog, crashy FROM quickchecks WHERE ts>=\(s0) AND ts<\(e0) AND scale='\(Scale.tag)' ORDER BY ts
            """) { r in rows.append((1...4).map { sqlite3_column_type(r, Int32($0)) == SQLITE_NULL ? "-" : "\(sqlite3_column_int(r, Int32($0)))" }) }
        let checks = rows.isEmpty ? "–" : rows.first!.joined(separator: ",") + (rows.count > 1 ? " → " + rows.last!.joined(separator: ",") : "") + " (\(rows.count))"
        var flags: [String] = []
        query("SELECT kind, COUNT(*) FROM events WHERE ts>=\(s0) AND ts<\(e0) AND (kind LIKE 'flag_%' OR kind IN ('gate_asked','gate_declined','gate_rest','gate_stop','day_lock','night_lock','clean_slate','app_blocked','app_added','reward','marker')) GROUP BY kind") { r in
            flags.append("\(text(r, 0).replacingOccurrences(of: "flag_", with: ""))×\(sqlite3_column_int(r, 1))")
        }
        let swText = sw.isEmpty ? "–" : String(format: "%.1f", sw.reduce(0, +) / Double(sw.count))
        print("\(ds) | \(whoop) | \(comp) (\(late)) | \(br["rested"] ?? 0)/\(br["did"] ?? 0)/\(br["paused"] ?? 0)/\(br["skipped"] ?? 0) | \(eyeDone)/\(eyeSkip) | \(swText) (\(bursts)) | \(phone)/\(chat) | \(checks) | \(flags.joined(separator: " "))")
    }
    if let m = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("markers.json")))) as? [String: Any], let list = m["markers"] as? [[String: Any]] {
        for x in list { print("marker: \(x["name"] ?? "") on \(x["date"] ?? "")") }
    }
    print("recent insights (newest first) and the user's feedback:")
    query("SELECT datetime(ts,'unixepoch','localtime'), kind, detail FROM events WHERE kind IN ('insight','insight_feedback') ORDER BY ts DESC LIMIT 20") { r in print("  \(text(r, 0)) \(text(r, 1)): \(text(r, 2))") }
case "mark", "compare":
    // supervisionctl mark "<name>" <YYYY-MM-DD>   → mark a change (a trial, a new medication); freezes the 14 days before it
    // supervisionctl compare ["<name>"]           → before (frozen) vs since, side by side (latest marker by default)
    let mf = dir.appendingPathComponent("markers.json")
    var markers = (try? JSONSerialization.jsonObject(with: Data(contentsOf: mf))) as? [[String: Any]] ?? []
    // Averages over [from, to): Whoop, 1–10 answers (10 = best), computer time, switching, and what happened.
    func stats(_ from: Date, _ to: Date) -> [(String, String)] {
        let f = from.timeIntervalSince1970, t = to.timeIntervalSince1970, fd = Day.string(from), td = Day.string(to)
        var out: [(String, String)] = []
        let fmt: (Double?) -> String = { $0.map { String(format: "%.1f", $0) } ?? "–" }
        query("SELECT COUNT(*), AVG(recovery), AVG(rhr), AVG(hrv), AVG(sleep), SUM(recovery<34) FROM baselines WHERE day>='\(fd)' AND day<'\(td)'") { r in
            let n = Int(sqlite3_column_int(r, 0))
            let d: (Int32) -> Double? = { n > 0 && sqlite3_column_type(r, $0) != SQLITE_NULL ? sqlite3_column_double(r, $0) : nil }
            out += [("Whoop days", "\(n)"), ("Recovery (avg)", fmt(d(1))), ("Red mornings", "\(sqlite3_column_int(r, 5))"),
                    ("Resting HR", fmt(d(2))), ("HRV", fmt(d(3))), ("Sleep h", fmt(d(4)))]
        }
        query("""
            SELECT COUNT(*), AVG(overall), AVG(headache), AVG(fog), AVG(crashy), AVG(tired) FROM (
              SELECT overall, headache, fog, crashy, tired FROM symptoms WHERE ts>=\(f) AND ts<\(t) AND scale='\(Scale.tag)'
              UNION ALL SELECT overall, headache, fog, crashy, tired FROM quickchecks WHERE ts>=\(f) AND ts<\(t) AND scale='\(Scale.tag)')
            """) { r in
            let n = Int(sqlite3_column_int(r, 0))
            let d: (Int32) -> Double? = { n > 0 && sqlite3_column_type(r, $0) != SQLITE_NULL ? sqlite3_column_double(r, $0) : nil }
            out += [("Check-ins", "\(n)"), ("Overall /10", fmt(d(1))), ("Head /10", fmt(d(2))), ("Clear /10", fmt(d(3))), ("Not crashing /10", fmt(d(4))), ("Energy /10", fmt(d(5)))]
        }
        query("SELECT AVG(m) FROM (SELECT COUNT(*)*5/60.0 m FROM samples WHERE ts>=\(f) AND ts<\(t) AND idle=0 GROUP BY date(ts,'unixepoch','localtime'))") { r in
            out.append(("Computer min/day", sqlite3_column_type(r, 0) == SQLITE_NULL ? "–" : String(format: "%.0f", sqlite3_column_double(r, 0))))
        }
        var sw: [Double] = []
        query("SELECT detail FROM events WHERE kind='block_switches' AND ts>=\(f) AND ts<\(t)") { r in
            let p = text(r, 0).split(separator: "|").compactMap { Double($0) }
            if p.count == 2, p[1] >= 10 { sw.append(p[0] / p[1] * 10) }
        }
        out.append(("Switches /10 min", sw.isEmpty ? "–" : String(format: "%.1f", sw.reduce(0, +) / Double(sw.count))))
        for (label, kinds) in [("Crash flags", "'flag_crash'"), ("Headache flags", "'flag_headache'"), ("Big drops (gate)", "'gate_asked','gate_rest'"), ("Overrides", "'override'")] {
            query("SELECT COUNT(*) FROM events WHERE kind IN (\(kinds)) AND ts>=\(f) AND ts<\(t)") { r in out.append((label, "\(sqlite3_column_int(r, 0))")) }
        }
        return out
    }
    if args.first == "mark" {
        guard args.count >= 3, let d = Day.date(args[2]) else { print("usage: supervisionctl mark \"<name>\" <YYYY-MM-DD>"); exit(1) }
        if let wrapped = (try? JSONSerialization.jsonObject(with: Data(contentsOf: mf))) as? [String: Any], let m = wrapped["markers"] as? [[String: Any]] { markers = m }
        var entry: [String: Any] = ["name": args[1], "date": args[2]]
        // A future date: the "before" freezes the first time `compare` runs on or after it, so it's complete.
        if d <= Date() { entry["before"] = stats(d.addingTimeInterval(-14 * 86400), d).map { [$0.0, $0.1] } }
        markers.append(entry)
        writeJSON(["markers": markers], mf)   // wrapped so writeJSON's dictionary type fits
        logEvent("marker", "\(args[1]) on \(args[2]); the 14 days before are frozen for comparison")
        print(d <= Date() ? "Marked '\(args[1])' on \(args[2]); the 14 days before are frozen." : "Marked '\(args[1])' for \(args[2]); the 14 days before it freeze on that day.")
    } else {
        if let wrapped = (try? JSONSerialization.jsonObject(with: Data(contentsOf: mf))) as? [String: Any], let m = wrapped["markers"] as? [[String: Any]] { markers = m }
        guard let m = (args.count > 1 ? markers.last { ($0["name"] as? String) == args[1] } : markers.last),
              let name = m["name"] as? String, let ds = m["date"] as? String, let d = Day.date(ds) else { print("No marker yet: supervisionctl mark \"<name>\" <YYYY-MM-DD>"); exit(1) }
        var before = (m["before"] as? [[String]] ?? []).map { ($0[0], $0[1]) }
        if before.isEmpty {
            before = stats(d.addingTimeInterval(-14 * 86400), min(d, Date()))
            if Date() >= d, let i = markers.lastIndex(where: { ($0["name"] as? String) == name && ($0["date"] as? String) == ds }) {
                markers[i]["before"] = before.map { [$0.0, $0.1] }; writeJSON(["markers": markers], mf)   // now frozen
            }
        }
        let after = Date() > d ? stats(d, Date()) : []
        let days = max(0, Int(Date().timeIntervalSince(d) / 86400))
        print(Date() < d ? "\(name) starts \(ds). Before so far (freezes that day):" : "\(name), \(ds) · before = 14 days before (frozen) · since = \(days) day\(days == 1 ? "" : "s") so far")
        print("  \("".padding(toLength: 18, withPad: " ", startingAt: 0))  before     since")
        for (i, (k, v)) in before.enumerated() {
            let now = i < after.count ? after[i].1 : "–"
            print("  \(k.padding(toLength: 18, withPad: " ", startingAt: 0))  \(v.padding(toLength: 9, withPad: " ", startingAt: 0))  \(now)")
        }
        if days < 7 { print("Under a week in: too early to read anything into it.") }
    }
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
    let keys = ["nudgeMinutesBefore", "zoomBufferMinutes", "idleResetMinutes", "maxDeferralMinutes"]
    guard args.count >= 3, keys.contains(args[1]), let v = Double(args[2]) else { print("usage: supervisionctl set <\(keys.joined(separator: "|"))> <number> \"reason\"  (budget/blocks/gate: supervisionctl capacity set)"); exit(1) }
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
    // supervisionctl capacity set dailyCapMinutes 420 "reason"   (or blockGreen, blockStep, gateDropBy…)
    let cf = dir.appendingPathComponent("capacity.json")
    var cap = readJSON(cf)
    if args.count >= 4, args[1] == "set", let v = Double(args[3]) {
        cap[args[2]] = v; writeJSON(cap, cf); logEvent("capacity", "\(args[2]) = \(v): \(args.count > 4 ? args[4] : "no reason given")")
        print("\(args[2]) set to \(v). Takes effect within a minute.")
    } else {
        print("\(cap["experimentNumber"] ?? 1) · review \(cap["reviewDate"] ?? "?") · clean streak \(cap["cleanStreak"] ?? 0)")
        print("starting blocks G/Y/R: \(cap["blockGreen"] ?? 30)/\(cap["blockYellow"] ?? 25)/\(cap["blockRed"] ?? 15) min (live ±\(cap["blockStep"] ?? 5), \(cap["blockMin"] ?? 15)–\(cap["blockMax"] ?? 45)) · cap \((cap["dailyCapMinutes"] as? Double ?? 480) / 60) h on the computer")
        if let s = cap["stepDownUntil"] as? String, !s.isEmpty { print("step-down in force until \(s)") }
        for h in (cap["history"] as? [String] ?? []).suffix(8) { print("  " + h) }
    }
case "daily-json":
    // Machine-readable day summary for the nightly Airtable/Calendar sync. `daily-json [YYYY-MM-DD]`
    var dayStart = Calendar.current.startOfDay(for: Date())
    if args.count > 1, let d = Day.date(args[1]) { dayStart = d }
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
    // Every symptom reading with its exact local timestamp (ISO 8601 with offset).
    let isoF = ISO8601DateFormatter(); isoF.timeZone = .current; isoF.formatOptions = [.withInternetDateTime]
    var readings: [[String: Any]] = []
    query("SELECT ts, fog, tired, crashy, overall, COALESCE(scale, '1-5 best-first'), headache, note FROM quickchecks WHERE ts>=\(s0) AND ts<\(e0) ORDER BY ts") { r in
        let new = text(r, 5) == Scale.tag
        var row: [String: Any] = ["time": isoF.string(from: Date(timeIntervalSince1970: sqlite3_column_double(r, 0))), "source": "Corner (1-10)",
                                  "scale": new ? "1 = worst, 10 = best" : "old 1–5 scale, 1 = best, 5 = worst"]
        for (i, k) in ["fog", "tired", "crashy", "overall"].enumerated() where sqlite3_column_type(r, Int32(i + 1)) != SQLITE_NULL { row[k] = Int(sqlite3_column_int(r, Int32(i + 1))) }
        if sqlite3_column_type(r, 6) != SQLITE_NULL { row["headache"] = Int(sqlite3_column_int(r, 6)) }
        if !text(r, 7).isEmpty { row["note"] = text(r, 7) }
        readings.append(row)
    }
    query("SELECT ts, fog, headache, crashy, overall, COALESCE(scale,''), context, tired, note FROM symptoms WHERE ts>=\(s0) AND ts<\(e0) ORDER BY ts") { r in
        let new = text(r, 5) == Scale.tag
        var row: [String: Any] = ["time": isoF.string(from: Date(timeIntervalSince1970: sqlite3_column_double(r, 0))),
                                  "source": new ? "After break (1-10)" : "After break (1-5)",
                                  "scale": new ? "1 = worst, 10 = best" : "old 1–5 scale, 1 = best, 5 = worst", "context": text(r, 6)]
        for (i, k) in ["fog", "headache", "crashy", "overall"].enumerated() where sqlite3_column_type(r, Int32(i + 1)) != SQLITE_NULL { row[k] = Int(sqlite3_column_int(r, Int32(i + 1))) }
        if sqlite3_column_type(r, 7) != SQLITE_NULL { row["tired"] = Int(sqlite3_column_int(r, 7)) }
        if !text(r, 8).isEmpty { row["note"] = text(r, 8) }
        readings.append(row)
    }
    // The app logs its own load numbers every hour ("day_load": weighted|focused|meeting), which
    // include calendar meetings, intense flags, context switching and off-screen work. Use the
    // last one for the day; fall back to a plain weighted count for days before it existed.
    var weighted = byCat.reduce(0.0) { $0 + Double($1.value) * (Weights.byCategory[$1.key] ?? 1) }
    var focused = byCat.filter { $0.key != "leisure" && $0.key != "meeting" }.values.reduce(0, +)
    var meeting = byCat["meeting"] ?? 0
    // Total computer time (what the cap counts): the app's own number when it logged one, else active samples.
    var computer = byCat.values.reduce(0, +)
    query("SELECT detail FROM events WHERE kind='day_load' AND ts>=\(s0) AND ts<\(e0) ORDER BY ts DESC LIMIT 1") { r in
        let p = text(r, 0).split(separator: "|").compactMap { Double($0) }
        if p.count >= 3 { weighted = p[0]; focused = Int(p[1]); meeting = Int(p[2]) }
        if p.count >= 4 { computer = Int(p[3]) }
    }
    // Earn-a-minute tasks done in breaks: one Rewards Ledger row each ($3).
    var rewards: [[String: Any]] = []
    query("SELECT ts, detail FROM events WHERE kind='reward' AND ts>=\(s0) AND ts<\(e0) ORDER BY ts") { r in
        let p = text(r, 1).split(separator: "|", maxSplits: 2).map(String.init)
        guard p.count == 3 else { return }
        let t = Date(timeIntervalSince1970: sqlite3_column_double(r, 0))
        rewards.append(["time": isoF.string(from: t), "task": p[0], "amount": Int(p[1]) ?? 3,
                        "reason": "\(p[2].components(separatedBy: ":").first ?? p[0]) in a break — \(df.string(from: t))"])
    }
    let out: [String: Any] = ["date": Day.string(dayStart), "weighted": Int(weighted), "focused": focused, "meeting": meeting, "computer": computer, "rewards": rewards,
                              "byCategory": byCat, "workedOn": worked, "breaks": breaks, "flags": flags, "locks": locks,
                              "readings": readings, "baseline": readJSON(dir.appendingPathComponent("baseline.json"))]
    if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) { print(String(data: d, encoding: .utf8)!) }
case "adapt":
    // supervisionctl adapt                                   → plan, this week, last sessions
    // supervisionctl adapt log <min> <avgHR|-> <maxHR|-> "mode" [YYYY-MM-DD]   → log a session
    // supervisionctl adapt set <stage|zoneLow|zoneHigh|hardCap|minutes> <n> "why"
    let af = dir.appendingPathComponent("adapt.json")
    var plan = readJSON(af)
    if plan.isEmpty, let d = try? JSONEncoder().encode(AdaptPlan()), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
        plan = o; plan["started"] = Day.string(Date()); writeJSON(plan, af)
    }
    var db: OpaquePointer?
    sqlite3_open(Paths.database.path, &db)
    sqlite3_exec(db, Schema.adapt, nil, nil, nil)
    sqlite3_close(db)
    if args.count >= 5, args[1] == "log", let m = Int(args[2]) {
        // The day goes into SQL, so it must be a real yyyy-MM-dd (B6).
        guard args.count <= 6 || Day.date(args[6]) != nil else { print("The date must be yyyy-MM-dd."); exit(1) }
        let day = args.count > 6 ? args[6] : Day.string(Date())
        let avg = Int(args[3]).map(String.init) ?? "NULL", mx = Int(args[4]).map(String.init) ?? "NULL"
        let mode = args[5].replacingOccurrences(of: "'", with: "''")
        var d2: OpaquePointer?; sqlite3_open(Paths.database.path, &d2)
        sqlite3_exec(d2, "INSERT OR IGNORE INTO adapt VALUES('\(day)', \(m), \(avg), \(mx), '\(mode)', \(Date().timeIntervalSince1970))", nil, nil, nil)
        let added = sqlite3_changes(d2); sqlite3_close(d2)
        if added > 0 { logEvent("adapt_session", "\(day): \(m) min \(args[5]), avg \(args[3]) max \(args[4]) bpm") }
        print(added > 0 ? "Logged \(m) min of \(args[5]) for \(day)." : "Already logged.")
    } else if args.count >= 4, args[1] == "muse" {
        // supervisionctl adapt muse "<status>" "<today's workout>" ["why"]   → Muse's plan for today (read from Airtable)
        let m: [String: Any] = ["date": Day.string(Date()), "status": args[2], "workout": args[3], "why": args.count > 4 ? args[4] : ""]
        writeJSON(m, MusePlan.file); logEvent("adapt_muse", "\(args[2]): \(args[3])")
        print("Stored Muse's plan for today.")
    } else if args.count >= 2, args[1] == "today" {
        // Today's plan as JSON, for Airtable and the morning text. Same logic as the morning card.
        let p = (try? JSONSerialization.data(withJSONObject: plan)).flatMap { try? JSONDecoder().decode(AdaptPlan.self, from: $0) } ?? AdaptPlan()
        var days = Set<String>(), last: String? = nil
        query("SELECT DISTINCT day FROM adapt WHERE day >= '\(Day.string(Day.today.addingTimeInterval(-6 * 86400)))'") { r in days.insert(text(r, 0)) }
        query("SELECT MAX(day) FROM adapt") { r in last = sqlite3_column_type(r, 0) == SQLITE_NULL ? nil : text(r, 0) }
        let daysOff = last.flatMap { Day.date($0) }.map { Int(Day.today.timeIntervalSince($0) / 86400) }
        let bl = readJSON(dir.appendingPathComponent("baseline.json"))
        let rec = (bl["date"] as? String) == Day.string(Date()) ? (bl["recovery"] as? Int) : nil
        var dipped = false
        query("SELECT COUNT(*) FROM events WHERE kind IN ('gate_soften','gate_rest','gate_stop') AND ts >= \(Day.today.timeIntervalSince1970)") { r in dipped = sqlite3_column_int(r, 0) > 0 }
        let t = p.today(tier: Tier.from(recovery: rec), dipped: dipped, hour: Calendar.current.component(.hour, from: Date()),
                        days: days.count, daysOff: daysOff, doneToday: days.contains(Day.string(Date())))
        var out: [String: Any] = ["date": Day.string(Date()), "status": t.status, "workout": t.workout, "why": t.why,
                                  "stage": p.stageName, "zone": "\(p.zoneLow)–\(p.zoneHigh) bpm", "minutes": p.minutes, "sessionsThisWeek": days.count]
        if let r = rec { out["recovery"] = r }
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) { print(String(data: d, encoding: .utf8)!) }
    } else if args.count >= 4, args[1] == "set", let v = Int(args[3]) {
        plan[args[2]] = v
        var h = plan["history"] as? [String] ?? []; h.append("\(Day.string(Date())): \(args[2]) = \(v): \(args.count > 4 ? args[4] : "no reason given")")
        plan["history"] = h; writeJSON(plan, af); logEvent("adapt", h.last!)
        print("\(args[2]) set to \(v).")
    } else {
        let st = plan["stage"] as? Int ?? 2
        print("\(AdaptPlan.stageNames[max(0, min(st, 5))]): \(plan["minutes"] ?? 20) min at \(plan["zoneLow"] ?? 90)–\(plan["zoneHigh"] ?? 100) bpm (cap \(plan["hardCap"] ?? 100)), \(plan["daysPerWeek"] ?? 3)×/week, ≤\(plan["maxDaysOff"] ?? 2) days off. Progressions this stage: \(plan["progressions"] ?? 0)/3.")
        let weekStart = Day.today.addingTimeInterval(-6 * 86400)
        var n = 0
        query("SELECT COUNT(DISTINCT day) FROM adapt WHERE day >= '\(Day.string(weekStart))'") { r in n = Int(sqlite3_column_int(r, 0)) }
        print("Last 7 days: \(n) session day(s).")
        query("SELECT day, minutes, COALESCE(avg_hr,'–'), COALESCE(max_hr,'–'), mode FROM adapt ORDER BY day DESC LIMIT 8") { r in
            print("  \(text(r, 0))  \(sqlite3_column_int(r, 1)) min  avg \(text(r, 2))  max \(text(r, 3))  \(text(r, 4))")
        }
        for h in (plan["history"] as? [String] ?? []).suffix(5) { print("  · " + h) }
    }
case "symptoms":
    let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    print("Today, 1 worst … 10 best (– = skipped):")
    print("  time      source       overall  head  clear  energy  not-crashing   note")
    query("""
        SELECT datetime(ts,'unixepoch','localtime'), 'after break', overall, headache, fog, tired, crashy, COALESCE(scale,''), COALESCE(note,'') FROM symptoms WHERE ts>=\(start)
        UNION ALL
        SELECT datetime(ts,'unixepoch','localtime'), 'corner', overall, headache, fog, tired, crashy, COALESCE(scale,''), COALESCE(note,'') FROM quickchecks WHERE ts>=\(start)
        ORDER BY 1
        """) { r in
        let v: (Int32) -> String = { sqlite3_column_type(r, $0) == SQLITE_NULL ? "–" : String(sqlite3_column_int(r, $0)) }
        let src = text(r, 1).padding(toLength: 11, withPad: " ", startingAt: 0)
        print("  \(text(r, 0).suffix(8))  \(src)   \(v(2))        \(v(3))     \(v(4))      \(v(5))       \(v(6))            \(text(r, 8))\(text(r, 7) == Scale.tag ? "" : "   (old 1–5 scale)")")
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
        // Only the newest day becomes "today's" baseline; older days (a backfill) go to the history table only.
        let current = readJSON(bf)["date"] as? String ?? ""
        if args[1] >= current { writeJSON(b, bf) }
        logEvent("baseline", "\(args[1]): recovery \(args[2]), RHR \(args[3])\(args[1] < current ? " (history)" : "")")
        var db: OpaquePointer?
        sqlite3_open(Paths.database.path, &db)
        sqlite3_exec(db, Schema.baselines, nil, nil, nil)
        sqlite3_exec(db, "INSERT OR REPLACE INTO baselines VALUES('\(args[1])', \(Int(args[2]) ?? 0), \(Int(args[3]) ?? 0), \(b["hrv"] ?? 0), \(b["sleepHours"] ?? 0))", nil, nil, nil)
        sqlite3_close(db)
        print("Baseline set for \(args[1]).")
    } else { print(readJSON(bf)) }
case "day":
    // Activity ledger: what was worked on, by kind of work, from window titles.
    // `supervisionctl day` = today; `supervisionctl day 2026-09-22`; `supervisionctl day 3` = last 3 days.
    var start = Calendar.current.startOfDay(for: Date()), end = Date()
    if args.count > 1 {
        if let d = Day.date(args[1]) { start = d; end = d.addingTimeInterval(86400) }
        else if let n = Int(args[1]) { start = start.addingTimeInterval(-Double(n - 1) * 86400) }
    }
    let s = start.timeIntervalSince1970, e = end.timeIntervalSince1970
    let hf = DateFormatter(); hf.dateFormat = "EEE MMM d"
    print("Activity \(hf.string(from: start)) → \(hf.string(from: end.addingTimeInterval(-1)))")
    var byCat: [String: [(String, String, Int)]] = [:]
    query("SELECT category, app, title, COUNT(*)*5/60 m FROM samples WHERE ts>=\(s) AND ts<\(e) AND idle=0 AND title<>'' GROUP BY app, title HAVING COUNT(*)>=12 ORDER BY m DESC") { r in
        byCat[text(r, 0), default: []].append((text(r, 1), text(r, 2), Int(sqlite3_column_int(r, 3))))
    }
    var catMin: [(String, Int)] = []
    query("SELECT category, COUNT(*)*5/60 FROM samples WHERE ts>=\(s) AND ts<\(e) AND idle=0 GROUP BY category ORDER BY 2 DESC") { r in catMin.append((text(r, 0), Int(sqlite3_column_int(r, 1)))) }
    for (cat, mins) in catMin {
        print("\n\(cat.uppercased())  \(mins)m")
        for (app, title, m) in (byCat[cat] ?? []).prefix(10) {
            print("  \(String(format: "%3d", m))m  \(cleanTitle(title, app: app).prefix(70))  [\(app)]")
        }
    }
    var breaks = 0, overrides = 0
    query("SELECT SUM(kind='break_start'), SUM(kind='override') FROM events WHERE ts>=\(s) AND ts<\(e)") { r in breaks = Int(sqlite3_column_int(r, 0)); overrides = Int(sqlite3_column_int(r, 1)) }
    print("\nRests: \(breaks)   Overrides: \(overrides)")
    query("SELECT datetime(ts,'unixepoch','localtime'), kind, detail FROM events WHERE ts>=\(s) AND ts<\(e) AND kind IN ('symptoms','quick_check') ORDER BY ts") { r in
        print("\(text(r, 1) == "symptoms" ? "After break" : "Corner     ") \(text(r, 0).suffix(8)): \(text(r, 2))")
    }
case "log":
    let n = Int(args.count > 1 ? args[1] : "30") ?? 30
    query("SELECT ts, kind, detail FROM events ORDER BY ts DESC LIMIT \(n)") { s in
        print("\(df.string(from: Date(timeIntervalSince1970: sqlite3_column_double(s, 0))))  \(text(s, 1).padding(toLength: 14, withPad: " ", startingAt: 0))  \(text(s, 2))")
    }
case "report":
    let days = Int(args.count > 1 ? args[1] : "7") ?? 7
    let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(days - 1) * 86400).timeIntervalSince1970
    print("day         focused  meetings  leisure  breaks  overrides  overall(avg 1–10)")
    query("""
        SELECT date(ts,'unixepoch','localtime') d,
          SUM(CASE WHEN idle=0 AND category NOT IN ('leisure','meeting') THEN 5 ELSE 0 END)/60,
          SUM(CASE WHEN idle=0 AND category='meeting' THEN 5 ELSE 0 END)/60,
          SUM(CASE WHEN idle=0 AND category='leisure' THEN 5 ELSE 0 END)/60,
          (SELECT COUNT(*) FROM events e WHERE e.kind='break_start' AND date(e.ts,'unixepoch','localtime')=d),
          (SELECT COUNT(*) FROM events e WHERE e.kind='override' AND date(e.ts,'unixepoch','localtime')=d),
          (SELECT ROUND(AVG(overall),1) FROM (SELECT ts, overall FROM symptoms WHERE scale='\(Scale.tag)' UNION ALL SELECT ts, overall FROM quickchecks WHERE scale='\(Scale.tag)') x
             WHERE x.overall IS NOT NULL AND date(x.ts,'unixepoch','localtime')=d)
        FROM samples WHERE ts >= \(start) GROUP BY d ORDER BY d
        """) { s in
        print("\(text(s, 0))  \(String(format: "%6d", sqlite3_column_int(s, 1)))   \(String(format: "%6d", sqlite3_column_int(s, 2)))   \(String(format: "%6d", sqlite3_column_int(s, 3)))  \(String(format: "%5d", sqlite3_column_int(s, 4)))  \(String(format: "%8d", sqlite3_column_int(s, 5)))     \(text(s, 6))")
    }
    print("\nBy category (minutes):")
    query("SELECT category, SUM(5)/60 FROM samples WHERE ts >= \(start) AND idle=0 GROUP BY category ORDER BY 2 DESC") { s in
        print("  \(text(s, 0).padding(toLength: 10, withPad: " ", startingAt: 0)) \(sqlite3_column_int(s, 1))")
    }
default:
    let today = Day.today.timeIntervalSince1970
    var focused = 0, meeting = 0
    query("SELECT SUM(CASE WHEN category NOT IN ('leisure','meeting') THEN 5 ELSE 0 END)/60, SUM(CASE WHEN category='meeting' THEN 5 ELSE 0 END)/60 FROM samples WHERE ts>=\(today) AND idle=0") { s in
        focused = Int(sqlite3_column_int(s, 0)); meeting = Int(sqlite3_column_int(s, 1))
    }
    let cap = readJSON(dir.appendingPathComponent("capacity.json"))
    let bl = readJSON(dir.appendingPathComponent("baseline.json"))
    let rec = (bl["date"] as? String) == Day.string(Date()) ? (bl["recovery"] as? Int) : nil
    let tier = Tier.from(recovery: rec)
    var used = 0
    query("SELECT COUNT(*)*5/60 FROM samples WHERE ts>=\(today) AND idle=0") { s in used = Int(sqlite3_column_int(s, 0)) }
    var block = ""
    query("SELECT detail FROM events WHERE kind='block_len' AND ts>=\(today) ORDER BY ts DESC LIMIT 1") { s in block = String(text(s, 0).split(separator: "|").first ?? "") }
    print("Today: \(used / 60) h \(used % 60) min on the computer of \((cap["dailyCapMinutes"] as? Double ?? 480) / 60) h (\(focused) focused, \(meeting) meetings). Whoop \(rec.map(String.init) ?? "—") → \(tier == "unknown" ? "unknown (treated as yellow)" : tier). Block now: \(block.isEmpty ? "tier start" : block + " min"). \(cap["experimentNumber"].map { "Experiment \($0)" } ?? ""), review \(cap["reviewDate"] ?? "?").")
    if let p = control["pauseUntil"] as? Double, p > Date().timeIntervalSinceReferenceDate {
        print("Paused until \(df.string(from: Date(timeIntervalSinceReferenceDate: p))): \(control["reason"] ?? "")")
    }
    print("Last decisions:")
    query("SELECT ts, kind, detail FROM events ORDER BY ts DESC LIMIT 5") { s in
        print("  \(df.string(from: Date(timeIntervalSince1970: sqlite3_column_double(s, 0))))  \(text(s, 1))  \(text(s, 2))")
    }
}
