import AppKit

/// Micro stretch breaks (user, Oct 26: "similar to the 20-20-20 … hold a pose or something for 10 seconds or
/// stand up and then it lets me resume work"). Full screen, like the eye break: stand and reach overhead
/// (seated reach on red days) until the camera has seen it for `hold` seconds, with live coaching
/// ("back up a bit", "come closer"). Ends by itself once seen; after 90 s it lets you go anyway (never a
/// trap); skipping early means typing a statement. No camera = it doesn't run at all.
final class MicroMove {
    static let shared = MicroMove()
    private var windows: [NSWindow] = []
    private var timer: Timer?
    private var previousApp: NSRunningApplication?
    private let number = NSTextField(labelWithString: "")
    private let coachLine = NSTextField(labelWithString: "")
    private let dots = ProgressDots(total: 10)
    private var handlers: [Card.Handler] = []
    var isShowing: Bool { !windows.isEmpty }

    /// `done(outcome)`: "seen", "gave up", "skipped".
    func show(hold: Double, needStand: Bool, statement: String, done: @escaping (_ outcome: String, _ held: Double) -> Void) -> Bool {
        guard windows.isEmpty, MoveCounter.shared.start(needStand: needStand) else { return false }
        previousApp = NSWorkspace.shared.frontmostApplication
        var held = 0.0, coach = "", posed = false
        MoveCounter.shared.onUpdate = { h, p, c in held = h; posed = p; coach = c }
        for screen in NSScreen.screens {
            let w = LockWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.backgroundColor = Brand.c.paper; w.appearance = Brand.appearance
            if screen == NSScreen.main {
                w.contentView = content(frame: screen.frame, needStand: needStand, hold: hold, statement: statement) { [weak self] in
                    self?.close(); done("skipped", held)
                }
            }
            w.makeKeyAndOrderFront(nil); windows.append(w)
        }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication]
        NSApp.activate(ignoringOtherApps: true)
        let started = Date(); var wasPosed = false
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let filled = min(Int(hold), Int(held))
            if filled > self.dots.filled { Brand.flash(self.dots) }
            self.dots.filled = filled
            self.number.stringValue = "\(max(0, Int(ceil(hold - held))))"
            self.coachLine.stringValue = coach.isEmpty ? "Looking for you…" : coach
            if posed && !wasPosed { Brand.flash(self.coachLine) }
            wasPosed = posed
            if held >= hold {
                self.timer?.invalidate(); self.timer = nil; MoveCounter.shared.stop()
                let today = Store.shared.eventDetails(kind: "micro_move", since: Day.today).filter { $0.hasPrefix("seen") }.count + 1
                self.number.stringValue = "✓"; self.coachLine.stringValue = "Nice. \(today) micro-stretch\(today == 1 ? "" : "es") today, back to it"
                Brand.flash(self.number)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.close(); done("seen", held) }
            } else if -started.timeIntervalSinceNow >= 90 {
                self.close(); done("gave up", held)
            }
        }
        return true
    }

    private func close() {
        timer?.invalidate(); timer = nil
        MoveCounter.shared.stop()
        NSApp.presentationOptions = []
        windows.forEach { $0.orderOut(nil) }; windows.removeAll(); handlers.removeAll()
        previousApp?.activate()
    }

    private func content(frame: NSRect, needStand: Bool, hold: Double, statement: String, skip: @escaping () -> Void) -> NSView {
        let c = Brand.c
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 16
        stack.addArrangedSubview(Brand.tag("Micro stretch · \(Int(hold)) s"))
        stack.addArrangedSubview(Brand.text(needStand ? "Stand up, both arms overhead" : "Both arms overhead, from your chair", Brand.display(36, .semibold), c.ink, align: .center))
        coachLine.font = Brand.display(22, .medium); coachLine.textColor = c.ink; coachLine.alignment = .center
        stack.addArrangedSubview(coachLine)
        number.font = Brand.digits(84); number.textColor = c.ink; number.alignment = .center
        let framed = BracketView(around: number, padding: 30)
        stack.setCustomSpacing(26, after: coachLine)
        stack.addArrangedSubview(framed)
        dots.total = Int(hold); dots.filled = 0
        stack.addArrangedSubview(dots)
        stack.setCustomSpacing(48, after: dots)
        stack.addArrangedSubview(Brand.text("To skip, type \u{201C}\(statement)\u{201D} and press Return", Brand.mono(11.5), c.faint, align: .center))
        let field = Brand.field("only if you really need to", width: 520, noPaste: true)
        let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").joined(separator: " ") }
        let h = Card.Handler { if norm(field.stringValue) == norm(statement) { skip() } }
        handlers.append(h); field.target = h; field.action = #selector(Card.Handler.fire)
        stack.addArrangedSubview(field)
        return BrandScreen.make(frame: frame, content: stack, tag: "Stretch · back to work after", calm: true)
    }
}
