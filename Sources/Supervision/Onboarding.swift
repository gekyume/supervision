import AppKit
import ApplicationServices

/// First-run welcome. Explains the why before asking for anything, then asks
/// for the two macOS permissions with a live status for each. The engine only
/// starts once the user taps "Let's go".
final class Onboarding {
    static let marker = Config.dir.appendingPathComponent("onboarded")
    static var done: Bool { FileManager.default.fileExists(atPath: marker.path) }

    private var window: NSWindow!
    private var page = 0
    private var content = NSView()
    private var pollTimer: Timer?
    private let onFinish: () -> Void
    private let cfg = Config.load()

    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

    /// ", Sam" from the Mac account's full name, or "" if there isn't one.
    static var firstName: String {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "" : " " + first
    }

    func show() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.16, alpha: 1)
        window.isReleasedWhenClosed = false; window.level = .floating
        window.center()
        render()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var pages: [(String, String, String)] {[
        ("👋", "Hi\(Onboarding.firstName). I'm Supervision.",
         "I'm the person sitting behind you while you work, whose only job is making sure you stop before your head starts to hurt.\n\nME/CFS means the bill for effort arrives 12–48 hours later. By the time you feel it, it's already too late. So I won't wait for you to feel it. I'll stop you on a schedule, and I'll always tell you why."),
        ("🧠", "How I'll work, and why",
         "• Work in blocks: 30, 25 or 15 minutes depending on how recovered you are this morning, then a short real rest. Pacing research says stay near 50% of what you could do, not 100%.\n\n• A daily budget of focused minutes, weighted by kind of work. Meetings cost more than email.\n\n• After each break, three faces: brain fog, headache, how crashy. If they climb, the day gets gentler or ends.\n\n• I'll never interrupt a call, or the \(Int(cfg.zoomBufferMinutes)) minutes either side of one.\n\n• Each day is judged by the two mornings after it. Clean days earn you more time.\n\nThe whole logic, with diagrams: menu bar 🧠 → How Supervision decides…"),
        ("🔐", "Two permissions",
         "Accessibility lets me see which app and window is in front, so I can sort your work into kinds (writing, email, meetings) and write an hourly summary to an \"Energy log\" calendar. Nothing leaves this Mac except that summary.\n\nCalendar lets me see your meetings so I never lock the screen during one."),
        ("🤝", "The deal",
         "I can't be quit from the Dock, and I come back if I'm force-quit. The only way to pause me is to ask Claude in your chat, and every pause gets logged with its reason. That's not to trap you. It's so a tired 4pm brain can't undo what a clear 9am brain decided.\n\nWhen you catch yourself wanting to skip a break, that's exactly the moment this is for. 💛"),
    ]}

    private func render() {
        let (emoji, title, body) = pages[page]
        let v = NSView(frame: window.contentView!.bounds)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 40, bottom: 28, right: 40)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let e = NSTextField(labelWithString: emoji); e.font = .systemFont(ofSize: 44)
        let t = NSTextField(wrappingLabelWithString: title); t.font = .systemFont(ofSize: 26, weight: .semibold); t.textColor = .white
        let b = NSTextField(wrappingLabelWithString: body); b.font = .systemFont(ofSize: 14); b.textColor = NSColor(white: 0.82, alpha: 1)
        [e, t, b].forEach { $0.preferredMaxLayoutWidth = 480; stack.addArrangedSubview($0) }

        if page == 2 {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
            let ax = button("Allow Accessibility") {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            let cal = button("Allow Calendar") { CalendarBridge.shared.start() }
            axStatus = NSTextField(labelWithString: ""); calStatus = NSTextField(labelWithString: "")
            [axStatus, calStatus].forEach { $0.textColor = NSColor(white: 0.7, alpha: 1); $0.font = .systemFont(ofSize: 13) }
            let col1 = NSStackView(views: [ax, axStatus]); col1.orientation = .vertical; col1.alignment = .leading
            let col2 = NSStackView(views: [cal, calStatus]); col2.orientation = .vertical; col2.alignment = .leading
            row.addArrangedSubview(col1); row.addArrangedSubview(col2)
            stack.addArrangedSubview(row)
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.refreshStatus() }
            refreshStatus()
        } else { pollTimer?.invalidate() }

        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(spacer)
        let nav = NSStackView(); nav.orientation = .horizontal; nav.spacing = 10
        let dots = NSTextField(labelWithString: (0..<pages.count).map { $0 == page ? "●" : "○" }.joined(separator: " "))
        dots.textColor = NSColor(white: 0.5, alpha: 1)
        nav.addArrangedSubview(dots)
        let gap = NSView(); gap.setContentHuggingPriority(.defaultLow, for: .horizontal); nav.addArrangedSubview(gap)
        if page > 0 { nav.addArrangedSubview(button("Back") { self.page -= 1; self.render() }) }
        let last = page == pages.count - 1
        let next = button(last ? "Let's go 💛" : "Next") {
            if last { self.finish() } else { self.page += 1; self.render() }
        }
        next.keyEquivalent = "\r"
        nav.addArrangedSubview(next)
        stack.addArrangedSubview(nav)
        nav.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -80).isActive = true

        v.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: v.leadingAnchor), stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: v.topAnchor), stack.bottomAnchor.constraint(equalTo: v.bottomAnchor)])
        window.contentView = v
    }

    private var axStatus = NSTextField(labelWithString: "")
    private var calStatus = NSTextField(labelWithString: "")
    private func refreshStatus() {
        axStatus.stringValue = AXIsProcessTrusted() ? "✅ granted" : "⏳ not yet"
        calStatus.stringValue = CalendarBridge.shared.granted ? "✅ granted" : "⏳ not yet"
    }

    private func finish() {
        pollTimer?.invalidate()
        FileManager.default.createFile(atPath: Onboarding.marker.path, contents: Data())
        Store.shared.event("onboarded", "Onboarding finished. Accessibility: \(AXIsProcessTrusted()), Calendar: \(CalendarBridge.shared.granted)")
        window.orderOut(nil)
        onFinish()
    }

    private var handlers: [Card.Handler] = []
    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let h = Card.Handler(action); handlers.append(h)
        let b = NSButton(title: title, target: h, action: #selector(Card.Handler.fire))
        b.bezelStyle = .rounded; b.controlSize = .large
        return b
    }
}
