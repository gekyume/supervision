import AppKit

/// 20-20-20 (user, Oct 5: "I really honestly think that I should be looking away every 20
/// minutes"): after `eyeEveryMinutes` of focused screen time, a 20-second full-screen
/// "look 20 feet away". It ends by itself. Skipping early means typing `eyeSkipStatement`.
/// No nudge before it (it's 20 s), focus goes back to the app you were in afterwards.
final class EyeBreak {
    static let shared = EyeBreak()
    private var windows: [NSWindow] = []
    private var timer: Timer?
    private var previousApp: NSRunningApplication?
    private let countdown = NSTextField(labelWithString: "")
    private var handlers: [Card.Handler] = []
    var isShowing: Bool { !windows.isEmpty }

    func show(seconds: Int, statement: String, done: @escaping (_ skipped: Bool) -> Void) {
        guard windows.isEmpty else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        for screen in NSScreen.screens {
            let w = LockWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.backgroundColor = Brand.c.paper; w.appearance = Brand.appearance
            if screen == NSScreen.main { w.contentView = content(frame: screen.frame, statement: statement, skip: { [weak self] in self?.close(); done(true) }) }
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication]
        NSApp.activate(ignoringOtherApps: true)
        // Blinks (user, Oct 24): the count goes 20 → 0 as you blink. If the camera can't see you
        // (or isn't allowed), it falls back to the 20-second timer. Never longer than 60 s (BlinkRule).
        let started = Date()
        var blinks = 0, sinceFace = 99.0
        let usingCamera = blinkTarget > 0 && counter.start()
        var lastBlinkAt = Date.distantPast
        counter.onUpdate = { [weak self] b, f, level in
            guard let self = self else { return }
            if b > blinks { Brand.flash(self.countdown); self.dots.filled = min(b, self.blinkTarget); lastBlinkAt = Date() }
            blinks = b; sinceFace = f
            // Live, no video (Oct 27): the eyes on screen open and close with yours.
            self.eyes.seen = f < 0.6; self.eyes.level = level
            self.seeLine.stringValue = f >= 0.6 ? "I can't see your face. Turn toward the screen for a moment so blinks count"
                : -lastBlinkAt.timeIntervalSinceNow < 0.7 ? "✓ Blink!" : "👀 I can see your eyes"
        }
        dots.total = max(1, blinkTarget); dots.filled = 0; dots.isHidden = !usingCamera
        eyes.isHidden = !usingCamera; seeLine.isHidden = !usingCamera
        eyes.seen = false; seeLine.stringValue = "Looking for your eyes…"
        let refresh = { [weak self] in
            guard let self = self else { return }
            let elapsed = -started.timeIntervalSinceNow
            if usingCamera && sinceFace < 3 {
                self.countdown.stringValue = "\(max(0, self.blinkTarget - blinks))"; self.unit.stringValue = "BLINKS TO GO"
            } else {
                self.countdown.stringValue = "\(max(0, Int(ceil(Double(seconds) - elapsed))))"; self.unit.stringValue = usingCamera ? "SECONDS · FACE THE SCREEN TO COUNT BLINKS" : "SECONDS"
            }
            if BlinkRule.done(blinks: usingCamera ? blinks : 0, target: max(1, self.blinkTarget), elapsed: elapsed,
                              secondsSinceFace: usingCamera ? sinceFace : 99, timerSeconds: Double(seconds), maxSeconds: self.maxSeconds) {
                self.lastBlinks = usingCamera ? blinks : nil
                self.timer?.invalidate(); self.timer = nil
                if usingCamera { Store.shared.event("eye_camera", "\(blinks) blinks; " + self.counter.summary) }
                self.counter.stop()
                if usingCamera && blinks >= self.blinkTarget {
                    // Gamified: say it saw you, then go.
                    let today = Store.shared.eventDetails(kind: "eye_break", since: Day.today).filter { $0.contains("blinks counted") }.count + 1
                    self.countdown.stringValue = "✓"; self.unit.stringValue = "\(blinks) BLINKS · \(today) EYE BREAK\(today == 1 ? "" : "S") TODAY"
                    Brand.flash(self.countdown)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.close(); done(false) }
                } else { self.close(); done(false) }
            }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in refresh() }
    }

    /// Blinks to count (0 = timer only) and the hard limit; set from config before `show`.
    var blinkTarget = 20
    var maxSeconds = 60.0
    private(set) var lastBlinks: Int?
    private let counter = BlinkCounter()
    private let unit = NSTextField(labelWithString: "")
    private let dots = ProgressDots(total: 20)
    private let eyes = EyesView(frame: .zero)
    private let seeLine = NSTextField(labelWithString: "")

    func previewView(frame: NSRect) -> NSView { let v = content(frame: frame, statement: "I am ignoring this eye break even though it is good for my health", skip: {}); countdown.stringValue = "14"; unit.stringValue = "BLINKS TO GO"; eyes.seen = true; eyes.level = 0.9; seeLine.stringValue = "👀 I can see your eyes"; return v }

    private func close() {
        timer?.invalidate(); timer = nil
        counter.stop(); counter.onUpdate = nil
        NSApp.presentationOptions = []
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll(); handlers.removeAll()
        previousApp?.activate()
    }

    private func content(frame: NSRect, statement: String, skip: @escaping () -> Void) -> NSView {
        let c = Brand.c
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 16
        stack.addArrangedSubview(Brand.tag("20 · 20 · 20"))
        stack.addArrangedSubview(Brand.text("Look at something 20 feet away", Brand.display(40, .semibold), c.ink, align: .center))
        stack.addArrangedSubview(Brand.text("Across the room, past the screen. Blink slowly; each one counts.", Brand.display(17, .regular), c.muted, align: .center))
        countdown.font = Brand.digits(84); countdown.textColor = c.ink; countdown.alignment = .center
        let framed = BracketView(around: countdown, padding: 30)
        stack.setCustomSpacing(30, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(framed)
        unit.font = Brand.mono(11, .medium); unit.textColor = c.faint; unit.alignment = .center
        stack.addArrangedSubview(unit)
        stack.addArrangedSubview(dots)
        stack.setCustomSpacing(28, after: dots)
        stack.addArrangedSubview(eyes)
        seeLine.font = Brand.display(16, .medium); seeLine.textColor = c.ink; seeLine.alignment = .center
        stack.addArrangedSubview(seeLine)
        stack.setCustomSpacing(48, after: seeLine)
        stack.addArrangedSubview(Brand.text("To skip, type \u{201C}\(statement)\u{201D} and press Return", Brand.mono(11.5), c.faint, align: .center))
        let field = Brand.field("only if you really need to", width: 520)
        let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").joined(separator: " ") }
        let h = Card.Handler { if norm(field.stringValue) == norm(statement) { skip() } }
        handlers.append(h)
        field.target = h; field.action = #selector(Card.Handler.fire)
        stack.addArrangedSubview(field)
        return BrandScreen.make(frame: frame, content: stack, tag: "Eyes · 20 s")
    }
}
