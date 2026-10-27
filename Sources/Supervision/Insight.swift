import Foundation

/// The noticing part (user, Oct 25: "I want this software to breathe … things I didn't
/// mention, behaviours I'm not aware of"). Once a day, after the morning Whoop reading, Claude
/// reads `supervisionctl digest` (one line per day) and returns ONE observation with its
/// numbers. It's shown on a card with 👍 / 👎; the feedback goes back into the next digest, so
/// it learns what's useful. Nothing leaves the Mac except this text to Claude (the user's own
/// account, via the Claude command-line tool, no tools allowed). A private context file
/// (insight-context.txt, next to the data) can say who the person is.
enum Insight {
    static let contextFile = Paths.dir.appendingPathComponent("insight-context.txt")

    private static let prompt = """
    You are the noticing part of Supervision, a Mac app that paces computer work for someone with an \
    energy-limiting condition (ME/CFS). Below is optional context about the person, then one line per day \
    (newest last), then recent observations and the person's feedback on them. Find ONE thing the person \
    probably hasn't noticed and would find useful today: a pattern across days, a change, a lagged effect \
    (what a day held vs recovery 1–2 mornings later), a habit forming, or something going well. Rules: cite \
    specific numbers and dates; say how much data it rests on; frame it as a pattern worth watching, never a \
    verdict or diagnosis; no "should", no medical advice; never repeat or rephrase a recent observation; lean \
    toward kinds marked useful and away from kinds marked not useful; at most 2 short sentences, optionally \
    followed by one small experiment starting "Try:". If nothing is worth saying, reply {"none":true}. Reply \
    with ONLY one line of JSON: {"text":"...","evidence":"..."}
    """

    enum Result { case ok(text: String, evidence: String), nothing, failed(String) }

    static func run(_ done: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let r = generate()
            DispatchQueue.main.async { done(r) }
        }
    }

    private static func generate() -> Result {
        let claude = ["~/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude"].map { NSString(string: $0).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let ctl = ["/usr/local/bin/supervisionctl", NSString(string: "~/bin/supervisionctl").expandingTildeInPath].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let claude, let ctl else { return .failed("Claude or supervisionctl isn't installed") }
        // 1. The digest.
        let d = Process(); d.executableURL = URL(fileURLWithPath: ctl); d.arguments = ["digest", "28"]
        let dout = Pipe(); d.standardOutput = dout; d.standardError = Pipe()
        do { try d.run() } catch { return .failed("digest: \(error.localizedDescription)") }
        let digest = String(data: dout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        d.waitUntilExit()
        let context = (try? String(contentsOf: contextFile, encoding: .utf8)) ?? ""
        let input = (context.isEmpty ? "" : "CONTEXT ABOUT THE PERSON:\n\(context)\n\n") + "TODAY: \(Day.string(Date()))\n\n" + digest
        // 2. Claude, with no tools: it only reads what it's given.
        let p = Process(); p.executableURL = URL(fileURLWithPath: claude)
        // Everything goes in the one argument (piping it in hung when launched from the app, Oct 25).
        p.arguments = ["-p", prompt + "\n\n" + input, "--tools", "", "--max-turns", "1"]
        p.currentDirectoryURL = Paths.dir
        let out = Pipe(); p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return .failed("claude: \(error.localizedDescription)") }
        let deadline = Date().addingTimeInterval(180)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        if p.isRunning { p.terminate(); return .failed("Claude took too long") }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").last(where: { $0.contains("{") }),
              let a = line.firstIndex(of: "{"), let b = line.lastIndex(of: "}"),
              let obj = (try? JSONSerialization.jsonObject(with: Data(line[a...b].utf8))) as? [String: Any] else {
            return .failed("unreadable answer: " + String(text.suffix(200)))
        }
        if obj["none"] as? Bool == true { return .nothing }
        guard let t = obj["text"] as? String, !t.isEmpty else { return .failed("empty answer") }
        return .ok(text: t, evidence: obj["evidence"] as? String ?? "")
    }
}
