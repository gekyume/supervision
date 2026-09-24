import AppKit

/// Menu-bar app. No Quit item. Quitting is refused unless Claude (supervisionctl)
/// has allowed it, and launchd relaunches it anyway if it's killed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var menuTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🧠"
        rebuildMenu()
        menuTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in self.rebuildMenu() }
        if Onboarding.done { startEverything() }
        else { onboarding = Onboarding { self.startEverything() }; onboarding?.show() }
    }

    private var onboarding: Onboarding?
    private func startEverything() {
        CalendarBridge.shared.start()
        Tracker.shared.start()
        Engine.shared.start()
    }

    private func rebuildMenu() {
        let e = Engine.shared
        item.button?.title = e.statusText
        let m = NSMenu()
        let b = e.budgetToday()
        m.addItem(withTitle: "Today: \(Int(e.weightedToday())) of \(Int(b.minutes)) weighted min (\(Int(e.focusedMinutesToday())) screen)", action: nil, keyEquivalent: "")
        m.addItem(withTitle: "Budget: " + b.reasons.joined(separator: " · "), action: nil, keyEquivalent: "")
        m.addItem(withTitle: "Meetings today: \(Int(e.meetingMinutesToday())) min · block \(e.blockMinutes) min", action: nil, keyEquivalent: "")
        m.addItem(withTitle: e.experimentLabel, action: nil, keyEquivalent: "")
        m.addItem(.separator())
        let how = NSMenuItem(title: "How Supervision decides…", action: #selector(openHowItWorks), keyEquivalent: "")
        how.target = self; m.addItem(how)
        let bl = Baseline.load()
        m.addItem(withTitle: bl.isToday ? "Whoop: recovery \(bl.recovery ?? 0) (\(bl.tier)), HR ceiling \(bl.hrCeiling ?? 0)" : "Whoop: no reading yet today", action: nil, keyEquivalent: "")
        m.addItem(withTitle: "Context: \(e.contextName)", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Now: \(Tracker.shared.lastCategory) — \(Tracker.shared.lastApp)", action: nil, keyEquivalent: "")
        let c = Control.load()
        if c.isPaused { m.addItem(withTitle: "⏸ Paused by Claude: \(c.reason)", action: nil, keyEquivalent: "") }
        m.addItem(.separator())
        m.addItem(withTitle: "To pause or stop: ask Claude in your chat 💬", action: nil, keyEquivalent: "")
        item.menu = m
    }

    /// The logic explainer: shipped inside the app bundle, openable any time.
    @objc func openHowItWorks() {
        if let u = Bundle.main.url(forResource: "how-it-works", withExtension: "html") { NSWorkspace.shared.open(u) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Control.load().mayQuit { Store.shared.event("quit", "allowed by Claude"); return .terminateNow }
        Store.shared.event("quit_refused", "quit attempted without Claude's OK")
        return .terminateCancel
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
