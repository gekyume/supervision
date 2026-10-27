import Foundation

/// The nightly sheet sync and the morning backup, run by the app itself (Oct 25: the desktop app is
/// usually signed in to the user's work account, where the scheduled tasks can't reach Whoop or the
/// sheet). Uses the Claude command-line tool's own sign-in, with only the Google Sheets / Whoop tools
/// it needs. Off unless `sheetSyncId` (the spreadsheet id) is set in config.json.
enum SheetSync {
    enum Result { case ok(String), failed(String) }

    static func nightly(day: String, sheet: String, _ done: @escaping (Result) -> Void) {
        background(done) {
            guard let json = runCtl(["daily-json", day]), json.contains("\"date\"") else { return .failed("daily-json failed") }
            let prompt = """
            Sync one day of Supervision data into the "Baseline" Google Sheet (spreadsheet id \(sheet)) with the Google Sheets \
            tools (get_values / update_values / append_values). Work mechanically. The day's data is the JSON at the end.
            1. DAILY LOG tab. Columns: A Date, B Day, ... O Weighted Load, P Screen Min, Q Meeting Min, R Work By Kind, S Worked On, \
            T Breaks, U Symptoms, V Supervision Flags, W Computer Min. Read 'Daily Log'!A:A, find the row whose Date equals the JSON \
            date (YYYY-MM-DD); if none, append a row with A = date and B = weekday name. Write ONLY O–W of that row (never other \
            columns): O = weighted, P = focused, Q = meeting, R = byCategory as lines "kind: N min" sorted desc without zeros, \
            S = workedOn joined with newlines, T = "N breaks: a, b, c" or "none", U = a one-line summary of readings (first→last per \
            question, count) or "none", V = flags + locks joined with "; " (max 250 chars) or "none", W = computer.
            2. SYMPTOM CHECKS tab (A Check ID, B Time, C Source, D Brain Fog, E Tired, F Crashy, G Headache, H Overall, I Context, \
            J Note). Read column A; for each reading whose "<time>|<source>" isn't there, append A = that id, B = time as given, \
            C = source, D = fog, E = tired, F = crashy, G = headache, H = overall (empty when missing), I = context + " · " + scale, \
            J = note. Never convert numbers (1 = worst … 10 = best).
            3. REWARDS LEDGER tab (A Reason, B Amount, C Logged At, D Source; never touch columns E–G). Read column A; for each \
            reward whose reason isn't there, append A = reason, B = amount, C = time as "YYYY-MM-DD H:MM", D = "Supervision". \
            Only append; never edit or delete.
            Finish with one line exactly: SYNC OK row=<Daily Log row> checks=<added> rewards=<added>
            JSON:
            \(json)
            """
            let tools = ["mcp__claude_ai_Google_Sheets__get_values", "mcp__claude_ai_Google_Sheets__update_values",
                         "mcp__claude_ai_Google_Sheets__append_values", "ToolSearch"]
            guard let out = runClaude(prompt, tools: tools, turns: 30, timeout: 600) else { return .failed("Claude didn't answer") }
            if let line = out.split(separator: "\n").last(where: { $0.contains("SYNC OK") }) { return .ok(String(line)) }
            return .failed(String(out.suffix(200)))
        }
    }

    /// Whoop workouts → ADaPT sessions, and Muse's plan for today (read-only) from the ADaPT Log tab.
    static func morning(sheet: String, _ done: @escaping (Result) -> Void) {
        background(done) {
            let today = Day.string(Date())
            let prompt = """
            Two read-only lookups; reply with ONLY one line of JSON at the end.
            1. Whoop get_workouts from \(Day.string(Date().addingTimeInterval(-3 * 86400)))T00:00:00Z to \
            \(Day.string(Date().addingTimeInterval(86400)))T00:00:00Z. For each SCORED workout of 8+ minutes: minutes = round((end-start)/60s), \
            avg = score.average_heart_rate, max = score.max_heart_rate, mode = sport name lowercase, day = start date in local time \
            (\(TimeZone.current.identifier)).
            2. Google Sheets get_values on spreadsheet \(sheet), range 'ADaPT Log'!A:F (A Session, D Status, E Today's Workout, F Why): \
            the row whose Session is \(today), if any. Never write anything.
            Reply: {"workouts":[{"minutes":N,"avg":N,"max":N,"mode":"...","day":"YYYY-MM-DD"}],"muse":{"status":"...","workout":"...","why":"..."} or null}
            """
            let tools = ["mcp__claude_ai_Whoop__get_workouts", "mcp__claude_ai_Google_Sheets__get_values", "ToolSearch"]
            guard let out = runClaude(prompt, tools: tools, turns: 8, timeout: 240),
                  let line = out.split(separator: "\n").last(where: { $0.contains("{") }),
                  let a = line.firstIndex(of: "{"), let b = line.lastIndex(of: "}"),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line[a...b].utf8))) as? [String: Any] else { return .failed("no answer") }
            var notes: [String] = []
            for w in obj["workouts"] as? [[String: Any]] ?? [] {
                guard let m = w["minutes"] as? Int, let day = w["day"] as? String else { continue }
                let avg = (w["avg"] as? Int).map(String.init) ?? "-", mx = (w["max"] as? Int).map(String.init) ?? "-"
                _ = runCtl(["adapt", "log", "\(m)", avg, mx, w["mode"] as? String ?? "workout", day]); notes.append("\(day) \(m) min")
            }
            if let muse = obj["muse"] as? [String: Any], let wk = muse["workout"] as? String, !wk.isEmpty {
                _ = runCtl(["adapt", "muse", muse["status"] as? String ?? "", wk, muse["why"] as? String ?? ""]); notes.append("Muse's plan read")
            }
            return .ok(notes.isEmpty ? "nothing new" : notes.joined(separator: ", "))
        }
    }

    // MARK: plumbing

    private static func background(_ done: @escaping (Result) -> Void, _ work: @escaping () -> Result) {
        DispatchQueue.global(qos: .utility).async { let r = work(); DispatchQueue.main.async { done(r) } }
    }

    private static func runCtl(_ args: [String]) -> String? {
        guard let ctl = ["/usr/local/bin/supervisionctl", NSString(string: "~/bin/supervisionctl").expandingTildeInPath]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process(); p.executableURL = URL(fileURLWithPath: ctl); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe(); p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func runClaude(_ prompt: String, tools: [String], turns: Int, timeout: Double) -> String? {
        guard let claude = ["~/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
            .map({ NSString(string: $0).expandingTildeInPath }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process(); p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = ["-p", prompt, "--max-turns", "\(turns)", "--allowedTools"] + tools
        p.currentDirectoryURL = Paths.dir
        let out = Pipe(); p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return nil }
        // Drain while running so a long answer can't fill the pipe and stall the process.
        var data = Data()
        let h = out.fileHandleForReading
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { data.append(h.availableData) }
        if p.isRunning { p.terminate(); return nil }
        data.append(h.readDataToEndOfFile())
        return String(data: data, encoding: .utf8)
    }
}
