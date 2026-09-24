import AppKit

/// The full-screen break takeover. Covers every screen, sits above everything,
/// and turns on macOS kiosk options so app-switching and Force Quit are off.
final class LockScreen {
    static let shared = LockScreen()
    private var windows: [NSWindow] = []
    private var countdown = NSTextField(labelWithString: "")
    private var buttonRow = NSStackView()
    private var reassert: Timer?
    private var handlers: [Card.Handler] = []
    var isShowing: Bool { !windows.isEmpty }

    private var mainWindow: NSWindow?
    private var current: (title: String, reason: String, plan: BreakPlan?, extra: String?) = ("", "", nil, nil)
    var onChoose: ((Activity) -> Void)?

    /// `plan` is the planned break (nil = a plain rest / day lock). `extra` is
    /// an optional care line (eat, drink) folded in instead of being its own alert.
    func show(title: String, reason: String, plan: BreakPlan? = nil, extra: String? = nil) {
        guard windows.isEmpty else { return }
        current = (title, reason, plan, extra)
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.14, alpha: 1)
            w.isOpaque = true; w.hasShadow = false; w.ignoresMouseEvents = false
            if screen == NSScreen.main {
                w.contentView = makeContent(frame: screen.frame)
                mainWindow = w
            }
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableAppleMenu, .disableProcessSwitching,
                                     .disableForceQuit, .disableSessionTermination, .disableHideApplication]
        NSApp.activate(ignoringOtherApps: true)
        reassert = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            NSApp.activate(ignoringOtherApps: true)
            self.windows.forEach { $0.orderFrontRegardless() }
        }
    }

    func update(countdownText: String) { countdown.stringValue = countdownText }

    /// Rest is over: one tap to say what happened. The screen stays until tapped,
    /// so if the user walked away it's simply waiting when they come back.
    func askCompletion(question: String, options: [(label: String, value: String)], done: @escaping (String) -> Void) {
        countdown.stringValue = question
        countdown.font = .systemFont(ofSize: 26, weight: .medium)
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for o in options {
            let h = Card.Handler { done(o.value) }; handlers.append(h)
            let b = NSButton(title: o.label, target: h, action: #selector(Card.Handler.fire))
            b.bezelStyle = .rounded; b.controlSize = .large; b.font = .systemFont(ofSize: 18)
            buttonRow.addArrangedSubview(b)
        }
        buttonRow.isHidden = false
    }

    /// Three quick faces: brain fog, headache, crashiness. One tap per row; the
    /// screen releases when all three are in (or on Skip). 1 = great … 5 = worst.
    func askSymptoms(intro: String, done: @escaping ((fog: Int, headache: Int, crashy: Int)?) -> Void) {
        countdown.stringValue = intro
        countdown.font = .systemFont(ofSize: 24, weight: .medium)
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttonRow.orientation = .vertical; buttonRow.alignment = .leading; buttonRow.spacing = 10
        var answers: [String: Int] = [:]
        let faces = ["😄", "🙂", "😐", "😕", "😣"]
        var rowButtons: [String: [NSButton]] = [:]
        for (key, title) in [("fog", "Brain fog"), ("headache", "Headache / neck"), ("crashy", "How crashy")] {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 6
            let l = NSTextField(labelWithString: title); l.font = .systemFont(ofSize: 17); l.textColor = NSColor(white: 0.85, alpha: 1)
            l.widthAnchor.constraint(equalToConstant: 170).isActive = true
            row.addArrangedSubview(l)
            var btns: [NSButton] = []
            for (i, f) in faces.enumerated() {
                let h = Card.Handler { [weak self] in
                    answers[key] = i + 1
                    rowButtons[key]?.enumerated().forEach { $0.element.alphaValue = $0.offset == i ? 1 : 0.35 }
                    if answers.count == 3 { self?.hide(); done((answers["fog"]!, answers["headache"]!, answers["crashy"]!)) }
                }
                self.handlers.append(h)
                let b = NSButton(title: f, target: h, action: #selector(Card.Handler.fire)); b.font = .systemFont(ofSize: 26); b.bezelStyle = .texturedRounded
                row.addArrangedSubview(b); btns.append(b)
            }
            rowButtons[key] = btns
            buttonRow.addArrangedSubview(row)
        }
        let skipH = Card.Handler { [weak self] in self?.hide(); done(nil) }; handlers.append(skipH)
        let skip = NSButton(title: "Skip this time", target: skipH, action: #selector(Card.Handler.fire)); skip.bezelStyle = .inline; skip.font = .systemFont(ofSize: 13)
        buttonRow.addArrangedSubview(skip)
        buttonRow.isHidden = false
    }

    func hide() {
        reassert?.invalidate(); reassert = nil
        NSApp.presentationOptions = []
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll(); handlers.removeAll()
    }

    /// the user tapped one of the alternatives: swap the activity and redraw.
    private func choose(_ a: Activity) {
        guard var p = current.plan else { return }
        p.activity = a
        current.plan = p
        onChoose?(a)
        if let w = mainWindow { w.contentView = makeContent(frame: w.frame) }
    }

    private func makeContent(frame: NSRect) -> NSView {
        let (title, reason, plan, extra) = current
        let activity = plan?.activity
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s); l.font = .systemFont(ofSize: size, weight: weight); l.textColor = color; l.alignment = .center
            l.widthAnchor.constraint(lessThanOrEqualToConstant: 780).isActive = true; return l
        }
        let emoji = NSTextField(labelWithString: activity?.emoji ?? "🌙"); emoji.font = .systemFont(ofSize: 96)
        stack.addArrangedSubview(emoji)
        stack.addArrangedSubview(label(plan?.headline ?? title, size: 34, weight: .semibold))
        if let a = activity {
            stack.addArrangedSubview(label("\(a.title) · \(a.minutes) min", size: 24, weight: .medium, color: NSColor(white: 0.95, alpha: 1)))
            stack.addArrangedSubview(label(a.instructions, size: 18, color: NSColor(white: 0.85, alpha: 1)))
            if a.load == "physical", let hr = plan?.hrCeiling {
                stack.addArrangedSubview(label("Heart-rate ceiling today: \(hr) bpm (resting + 15). Over it, sit down.", size: 15, color: NSColor(calibratedRed: 1, green: 0.75, blue: 0.6, alpha: 1)))
            }
        }
        // The honest part: what the user wanted, why not, and what would change it.
        if let ack = plan?.acknowledgement {
            stack.addArrangedSubview(label(ack, size: 17, color: NSColor(calibratedRed: 1, green: 0.85, blue: 0.55, alpha: 1)))
        }
        if let u = plan?.unlock { stack.addArrangedSubview(label(u, size: 15, color: NSColor(white: 0.7, alpha: 1))) }
        stack.addArrangedSubview(label("Numbers: " + reason, size: 14, color: NSColor(white: 0.55, alpha: 1)))
        countdown = NSTextField(labelWithString: "")
        countdown.font = .monospacedDigitSystemFont(ofSize: 56, weight: .light); countdown.textColor = NSColor(white: 0.9, alpha: 1); countdown.alignment = .center
        stack.addArrangedSubview(countdown)
        // Up to three things that are also okay right now, one tap each.
        if let alts = plan?.alternatives.filter({ $0.key != activity?.key }), !alts.isEmpty {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
            row.addArrangedSubview(label("Also fine right now:", size: 14, color: NSColor(white: 0.6, alpha: 1)))
            for a in alts.prefix(3) {
                let h = Card.Handler { [weak self] in self?.choose(a) }; handlers.append(h)
                let b = NSButton(title: "\(a.emoji) \(a.title)", target: h, action: #selector(Card.Handler.fire))
                b.bezelStyle = .rounded; b.controlSize = .large; b.font = .systemFont(ofSize: 15)
                row.addArrangedSubview(b)
            }
            stack.addArrangedSubview(row)
        }
        buttonRow = NSStackView(); buttonRow.orientation = .horizontal; buttonRow.spacing = 12; buttonRow.isHidden = true
        stack.addArrangedSubview(buttonRow)
        if let e = extra { stack.addArrangedSubview(label(e, size: 20, weight: .medium, color: NSColor(calibratedRed: 1, green: 0.85, blue: 0.55, alpha: 1))) }
        stack.addArrangedSubview(label("To end this early, ask Claude in your chat. 💛", size: 13, color: NSColor(white: 0.45, alpha: 1)))
        v.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: v.centerXAnchor), stack.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        return v
    }
}

/// Small floating card in the top-right: the gentle nudge, and the one-tap check-in.
final class Card {
    static let shared = Card()
    private var window: NSPanel?
    private var dismissTimer: Timer?

    func showNudge(_ text: String, reason: String, seconds: Double = 25) {
        show(title: text, body: reason, buttons: [], seconds: seconds)
    }

    /// Five faces, one tap, never typing. Scores 1–5 go to the local log.
    func showCheckin(context: String) {
        let faces = ["😣", "😕", "😐", "🙂", "😄"]
        show(title: "How's your head right now?", body: "One tap. This helps me learn what today cost you.", buttons: faces.enumerated().map { i, f in
            (f, { Store.shared.checkin(score: i + 1, context: context); Store.shared.event("checkin", "\(i + 1)/5 \(f) (\(context))") })
        }, seconds: 180)
    }

    private func show(title: String, body: String, buttons: [(String, () -> Void)], seconds: Double) {
        hide()
        let width: CGFloat = 360
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 10), styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true; p.isMovableByWindowBackground = true
        p.level = .floating; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.19, alpha: 1)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let t = NSTextField(wrappingLabelWithString: title); t.font = .systemFont(ofSize: 15, weight: .semibold); t.textColor = .white
        let b = NSTextField(wrappingLabelWithString: body); b.font = .systemFont(ofSize: 13); b.textColor = NSColor(white: 0.75, alpha: 1)
        [t, b].forEach { $0.preferredMaxLayoutWidth = width - 32; stack.addArrangedSubview($0) }
        if !buttons.isEmpty {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 6
            for (label, action) in buttons {
                let btn = NSButton(title: label, target: nil, action: nil); btn.font = .systemFont(ofSize: 22); btn.bezelStyle = .texturedRounded
                let h = Handler { action(); self.hide() }; btn.target = h; btn.action = #selector(Handler.fire); handlers.append(h)
                row.addArrangedSubview(btn)
            }
            stack.addArrangedSubview(row)
        }
        let content = NSView(); content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        p.contentView = content
        p.setContentSize(stack.fittingSize)
        if let s = NSScreen.main {
            p.setFrameTopLeftPoint(NSPoint(x: s.visibleFrame.maxX - width - 16, y: s.visibleFrame.maxY - 12))
        }
        p.orderFrontRegardless()
        window = p
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in self.hide() }
    }

    func hide() { dismissTimer?.invalidate(); window?.orderOut(nil); window = nil; handlers.removeAll() }

    private var handlers: [Handler] = []
    final class Handler: NSObject { let f: () -> Void; init(_ f: @escaping () -> Void) { self.f = f }; @objc func fire() { f() } }
}
