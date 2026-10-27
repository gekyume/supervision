import Foundation

/// "Get Whoop reading" on the morning card. The app can't reach Whoop itself: the
/// connection lives in the user's Claude account. So this asks the Claude command-line
/// tool (logged in with the same account) to read today's recovery and sleep and reply
/// with one line of JSON. The app then writes it with `supervisionctl baseline`, exactly
/// like the scheduled morning task does. Claude gets read-only Whoop tools, nothing else.
enum WhoopFetch {
    enum Result { case ok(recovery: Int), notScoredYet, failed(String) }

    private static let claudePaths = ["~/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        .map { NSString(string: $0).expandingTildeInPath }

    private static var prompt: String {
        let today = Day.string(Date())
        return """
        Using the Whoop connector only, get recoveries and sleeps for start=\(Day.string(Date().addingTimeInterval(-86400)))T00:00:00Z \
        end=\(Day.string(Date().addingTimeInterval(86400)))T12:00:00Z. Pick the most recent SCORED recovery whose created_at is \
        \(today) in local time (\(TimeZone.current.identifier)), and its matching non-nap sleep. Reply with ONLY one line of JSON, \
        no prose: {"date":"\(today)","recovery":INT,"rhr":INT,"hrv":FLOAT_1DP,"sleep":HOURS_1DP} where sleep = \
        (total_in_bed_time_milli - total_awake_time_milli)/3600000. If there is no scored recovery for today yet, reply {"none":true}.
        """
    }

    /// Runs off the main thread; calls back on the main thread.
    static func run(_ done: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = fetch()
            DispatchQueue.main.async { done(r) }
        }
    }

    private static func fetch() -> Result {
        guard let claude = claudePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .failed("The Claude command-line tool isn't installed on this Mac.")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        // Read-only Whoop tools; everything else stays unavailable in this run.
        p.arguments = ["-p", prompt, "--max-turns", "6",
                       "--allowedTools", "mcp__claude_ai_Whoop__get_recoveries", "mcp__claude_ai_Whoop__get_sleeps", "ToolSearch"]
        p.currentDirectoryURL = Paths.dir
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return .failed("Couldn't start Claude: \(error.localizedDescription)") }
        let deadline = Date().addingTimeInterval(150)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        if p.isRunning { p.terminate(); return .failed("Claude took too long to answer. Try again in a minute.") }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if text.contains("Not logged in") || text.contains("/login") {
            return .failed("Claude on this Mac isn't logged in yet. In Terminal, run `claude`, type /login, and sign in once.")
        }
        guard let line = text.split(separator: "\n").last(where: { $0.contains("{") }),
              let start = line.firstIndex(of: "{"), let end = line.lastIndex(of: "}"),
              let obj = (try? JSONSerialization.jsonObject(with: Data(line[start...end].utf8))) as? [String: Any] else {
            Store.shared.event("whoop_fetch", "failed: " + String(text.suffix(300)))
            return .failed("Claude answered, but not with a Whoop reading. Ask Claude in chat and it'll look into it.")
        }
        if obj["none"] as? Bool == true { return .notScoredYet }
        guard let rec = obj["recovery"] as? Int, let rhr = obj["rhr"] as? Int else { return .failed("The Whoop reading came back incomplete.") }
        let hrv = (obj["hrv"] as? Double) ?? 0, sleep = (obj["sleep"] as? Double) ?? 0
        let ctl = ["/usr/local/bin/supervisionctl", NSString(string: "~/bin/supervisionctl").expandingTildeInPath].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ctl else { return .failed("supervisionctl isn't installed.") }
        let w = Process(); w.executableURL = URL(fileURLWithPath: ctl)
        w.arguments = ["baseline", Day.string(Date()), "\(rec)", "\(rhr)", String(format: "%.1f", hrv), String(format: "%.1f", sleep), "whoop (fetched from the morning card)"]
        w.standardOutput = Pipe(); w.standardError = Pipe()
        try? w.run(); w.waitUntilExit()
        return .ok(recovery: rec)
    }
}
