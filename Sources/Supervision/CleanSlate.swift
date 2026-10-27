import AppKit

/// A clean slate each morning (user, Oct 1): yesterday's apps and Chrome tabs are gone,
/// so the day doesn't start by sliding back into last night's task.
/// Browsers: any Chromium browser with Chrome's AppleScript (Comet, Chrome).
///
/// When (user, Oct 1: "if I'm not using my computer for an hour, everything should clear up"):
///   - at `cleanSlateHour` (4 am) if the Mac is awake, otherwise on the first wake or unlock after;
///   - after `cleanSlateAwayMinutes` (60) with no keyboard/mouse, unless a call, a calendar
///     meeting or video playback (something keeping the display awake) explains the stillness;
///   - on waking from a sleep that long;
///   - when Supervision itself locks for that long (hour off, cap, night).
/// Never on a plain app launch mid-day (a rebuild must not quit things), and at most once per away stretch.
/// How: each browser's tab list is saved to tabs/<date>-<browser>.txt and its windows closed; every other
/// regular app gets a normal Quit (⌘Q), so anything with unsaved work asks and stays open.
final class CleanSlate {
    static let shared = CleanSlate()
    private var woke = false
    private var sleptAt: Date?
    private var wokeFromLongSleep = false
    private var lastAwayCheck = Date.distantPast
    private var running = false
    private let queue = DispatchQueue(label: "clean-slate")
    static let tabsDir = Paths.dir.appendingPathComponent("tabs")

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.sleptAt = Date() }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.woke = true
            let away = Double(Engine.shared.config.cleanSlateAwayMinutes) * 60
            if let t = self.sleptAt, -t.timeIntervalSinceNow >= away { self.wokeFromLongSleep = true }
            self.sleptAt = nil
        }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.woke = true }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.woke = true }
        // Ask for the browser permission now, while someone's here to click Allow, not at 4 am.
        for id in Engine.shared.config.cleanSlateBrowsers where Self.isRunning(id) {
            queue.async { _ = Self.run("tell application id \"\(id)\" to count windows") }
        }
    }

    /// Called from the engine's tick. The decisions are `CleanSlateRule` (tested); this gathers the facts.
    func maybeRun(config: Config, morningHour: Int) {
        guard !running else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        let ranToday = Store.shared.lastEvent(kind: "clean_slate", since: Day.today) != nil
        // "First time the computer is opened": only a wake/unlock needs the activity check (B4).
        var activeSinceHour = 0.0
        if woke, config.cleanSlateHour >= 0, let from = Calendar.current.date(bySettingHour: config.cleanSlateHour, minute: 0, second: 0, of: Date()) {
            activeSinceHour = Store.shared.activeSeconds(from: from, to: Date()).values.reduce(0, +)
        }
        if CleanSlateRule.morningDue(hour: hour, cleanSlateHour: config.cleanSlateHour, morningHour: morningHour, woke: woke,
                                     activeSecondsSinceCleanSlateHour: activeSinceHour, ranToday: ranToday) {
            return run(config: config, why: "morning")
        }
        woke = false   // a wake that wasn't a morning is spent; the next one is judged afresh
        guard config.cleanSlateAwayMinutes > 0 else { return }
        if wokeFromLongSleep {
            wokeFromLongSleep = false
            return run(config: config, why: "the Mac slept \(config.cleanSlateAwayMinutes)+ min")
        }
        let idle = Tracker.idleSeconds
        guard idle >= Double(config.cleanSlateAwayMinutes) * 60, -lastAwayCheck.timeIntervalSinceNow > 60 else { return }
        lastAwayCheck = Date()
        let cleared = Store.shared.lastEvent(kind: "clean_slate", since: Date().addingTimeInterval(-idle)) != nil
        // Stillness that isn't absence: a call, a meeting, a video playing.
        let explained = Engine.shared.liveCall(calendarBuffer: 5) != nil || Self.displayKeptAwake()
        if CleanSlateRule.awayDue(idleSeconds: idle, awayMinutes: config.cleanSlateAwayMinutes, clearedWithinStretch: cleared, explained: explained) {
            run(config: config, why: "no keyboard or mouse for \(Int(idle / 60)) min")
        }
    }

    /// Supervision's own long locks (an hour off, the cap, night) count as time away.
    func lockStarted(minutes: Double, config: Config) {
        guard config.cleanSlateAwayMinutes > 0, minutes >= Double(config.cleanSlateAwayMinutes), !running,
              Store.shared.lastEvent(kind: "clean_slate", since: Date().addingTimeInterval(-3600)) == nil else { return }
        run(config: config, why: "a \(Int(minutes))-min lock")
    }

    private func run(config: Config, why: String) {
        running = true; woke = false; wokeFromLongSleep = false   // one run spends every pending trigger
        let keep = Set(config.cleanSlateKeep + [Bundle.main.bundleIdentifier ?? ""])
        queue.async {
            var notes: [String] = [], keepBrowsers = Set<String>()
            for id in config.cleanSlateBrowsers where Self.isRunning(id) {
                let name = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }?.localizedName ?? id
                let script = """
                tell application id "\(id)"
                  set out to ""
                  repeat with w in windows
                    repeat with t in tabs of w
                      set out to out & (URL of t) & tab & (title of t) & linefeed
                    end repeat
                  end repeat
                  close every window
                  return out
                end tell
                """
                if let tabs = Self.run(script) {
                    try? FileManager.default.createDirectory(at: Self.tabsDir, withIntermediateDirectories: true)
                    let file = Self.tabsDir.appendingPathComponent("\(Day.string(Date()))-\(name).txt")
                    try? tabs.write(to: file, atomically: true, encoding: .utf8)
                    notes.append("\(tabs.split(separator: "\n").count) \(name) tabs saved to tabs/\(file.lastPathComponent)")
                } else {
                    keepBrowsers.insert(id)
                    notes.append("\(name) tabs not saved (no permission?), left open")
                }
            }
            DispatchQueue.main.async {
                let apps = NSWorkspace.shared.runningApplications.filter {
                    $0.activationPolicy == .regular && !keep.contains($0.bundleIdentifier ?? "")
                        && !keepBrowsers.contains($0.bundleIdentifier ?? "")
                }
                let names = apps.compactMap { $0.localizedName }
                apps.forEach { $0.terminate() }
                notes.insert("After \(why): quit \(names.count) apps: \(names.joined(separator: ", "))", at: 0)
                Store.shared.event("clean_slate", notes.joined(separator: ". "))
                self.running = false
            }
        }
    }

    private static func isRunning(_ id: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
    }

    /// True when an app (a video player, a browser tab playing video) is keeping the display awake.
    private static func displayKeptAwake() -> Bool {
        let p = Process(); p.launchPath = "/usr/bin/pmset"; p.arguments = ["-g", "assertions"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return false }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return parts.count == 2 && parts[0] == "PreventUserIdleDisplaySleep" && parts[1] != "0"
        }
    }

    private static func run(_ source: String) -> String? {
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return err == nil ? (r?.stringValue ?? "") : nil
    }
}
