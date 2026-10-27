import AppKit

/// Borderless windows can't take typing unless they may become key.
final class LockWindow: NSWindow { override var canBecomeKey: Bool { true } }

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
    /// Earn-a-minute tasks (Rewards): shown when `rewardsOn`; each tap calls `onReward` once per break.
    var rewardsOn = false
    var onReward: ((RewardTask) -> Void)?
    private var rewardedThisBreak = Set<String>()
    private var picking = false
    private var showMore = false       // calm by default; "More" reveals options, earn-a-minute and the numbers
    private let moveCue = NSTextField(labelWithString: "")
    private let pickCount = NSTextField(labelWithString: "")
    private func updatePickCount(_ n: Int) {
        let limit = Engine.shared.config.appPickLimit
        pickCount.stringValue = limit > 0 ? "\(n) OF \(limit) PICKED" + (n >= limit ? " · MORE NEED A TYPED REASON" : "") : ""
    }
    /// The movement step before a break's countdown (nil hides it).
    func setMove(_ cue: String?) { moveCue.stringValue = cue ?? ""; moveCue.isHidden = cue == nil; moveDots.isHidden = cue == nil; if cue == nil { moveFigure.isHidden = true; moveFigure.joints = [:] } }
    /// The live dot figure while the stretch is being looked for (Oct 27); hidden once it's seen.
    let moveFigure = PoseView(frame: .zero)
    private let moveDots = ProgressDots(total: Int(MoveRule.holdSeconds))
    private var wasPosed = false
    /// Live proof the camera sees the stretch: "✓ I see you" while posed, a dot per second held.
    func showMoveProgress(cue: String, held: Double, posed: Bool) {
        moveCue.stringValue = cue + (posed ? "  ·  ✓ I see you" : "")
        moveCue.isHidden = false; moveDots.isHidden = false; moveFigure.isHidden = picking
        let n = min(moveDots.total, Int(held))
        if n > moveDots.filled { Brand.flash(moveDots) }
        moveDots.filled = n
        if posed && !wasPosed { Brand.flash(moveCue) }
        wasPosed = posed
    }
    /// The stretch was seen: a short celebration, then the cue steps aside.
    func showMoveDone(_ text: String) {
        moveDots.filled = moveDots.total; moveFigure.isHidden = true
        moveCue.stringValue = text; moveCue.isHidden = false; moveDots.isHidden = false
        Brand.flash(moveCue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.setMove(nil) }
    }        // the app picker is up: the break's options step aside

    /// `plan` is the planned break (nil = a plain rest / day lock). `extra` is
    /// an optional care line (eat, drink) folded in instead of being its own alert.
    func show(title: String, reason: String, plan: BreakPlan? = nil, extra: String? = nil) {
        guard windows.isEmpty else { return }
        current = (title, reason, plan, extra)
        rewardedThisBreak = []; picking = false; showMore = false
        BreathView.epoch = Date()
        if BreathBell.on { BreathBell.shared.start() }   // every break breathes (Oct 26)
        for screen in NSScreen.screens {
            let w = LockWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.backgroundColor = Brand.c.paper; w.appearance = Brand.appearance
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

    /// The phone asked to unlock (user, Oct 3): type a reason, then type the statement
    /// word for word. Only then does `done(reason)` run. Case and punctuation don't matter.
    func askTyped(question: String, statement: String, done: @escaping (String) -> Void) {
        countdown.stringValue = question
        countdown.font = Brand.display(26, .medium); countdown.textColor = Brand.c.ink
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttonRow.orientation = .vertical; buttonRow.alignment = .centerX; buttonRow.spacing = 12
        let field: (String) -> NSTextField = { Brand.field($0, width: 520, size: 16, noPaste: true) }
        let reason = field("Why do you need the computer right now?")
        let quote = Brand.text("Then type \u{201C}\(statement)\u{201D}", Brand.display(15, .regular), Brand.c.muted, wrap: 520, align: .center)
        let typed = field("Type the sentence above")
        let hint = NSTextField(labelWithString: ""); hint.font = Brand.mono(12); hint.textColor = Brand.c.ink
        let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").joined(separator: " ") }
        let h = Card.Handler {
            let r = reason.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.count < 3 { hint.stringValue = "A few words of why, please."; return }
            if norm(typed.stringValue) != norm(statement) { hint.stringValue = "The sentence doesn't match yet."; return }
            done(r)
        }
        handlers.append(h)
        let b = Brand.button("Unlock", primary: true, size: 15, target: h, action: #selector(Card.Handler.fire)); b.keyEquivalent = "\r"
        [reason, quote, typed, b, hint].forEach { buttonRow.addArrangedSubview($0) }
        buttonRow.isHidden = false
        mainWindow?.makeKey()
        mainWindow?.makeFirstResponder(reason)
    }

    /// The app picker (user, Oct 24): the apps the user uses, faded; tap the ones this block needs,
    /// then "Start the block". The answer goes to `done`.
    func askApps(_ apps: [AppGate.App], done: @escaping (Set<String>) -> Void) {
        // The break is over: redraw without its options so the picker has the screen.
        picking = true
        if let w = mainWindow { w.contentView = makeContent(frame: w.frame) }
        countdown.stringValue = "Which apps does the next block need?"
        countdown.font = Brand.display(26, .medium); countdown.textColor = Brand.c.ink
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttonRow.orientation = .vertical; buttonRow.alignment = .centerX; buttonRow.spacing = 16
        var chosen = Set<String>()
        let perRow = 6
        for start in stride(from: 0, to: apps.count, by: perRow) {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 18
            for a in apps[start..<min(start + perRow, apps.count)] {
                let tile = AppTile(app: a)
                let h = Card.Handler { [weak self] in
                    if chosen.contains(a.bundleID) { chosen.remove(a.bundleID); tile.on = false; self?.updatePickCount(chosen.count); return }
                    // Three free picks (user, Oct 25); a fourth asks for the typed statement first.
                    let limit = Engine.shared.config.appPickLimit
                    if AppPickRule.needsPermission(alreadyPicked: chosen.count, limit: limit) {
                        let st = Statements.pick(Statements.addApp, last: nil, roll: Int.random(in: 0..<1000), app: a.name, time: Day.clock(Date()))
                        TypedPrompt.shared.ask(tag: "Pick \(chosen.count + 1) of \(limit) free", title: "A fourth app for this block?", statement: st.text) { ok in
                            guard ok else { return }
                            chosen.insert(a.bundleID); tile.on = true; self?.updatePickCount(chosen.count)
                            Store.shared.event("app_added", "\(a.name) picked past the limit of \(limit)")
                        }
                        return
                    }
                    chosen.insert(a.bundleID); tile.on = true; self?.updatePickCount(chosen.count)
                }
                handlers.append(h); tile.target = h; tile.action = #selector(Card.Handler.fire)
                row.addArrangedSubview(tile)
            }
            buttonRow.addArrangedSubview(row)
        }
        pickCount.font = Brand.mono(11, .medium); pickCount.textColor = Brand.c.faint; pickCount.alignment = .center
        updatePickCount(0)
        buttonRow.addArrangedSubview(pickCount)
        buttonRow.addArrangedSubview(Brand.tag("Slack is always on · everything else closes until your next break"))
        let go = Card.Handler { done(chosen) }; handlers.append(go)
        buttonRow.addArrangedSubview(Brand.button("Start the block", primary: true, size: 15, target: go, action: #selector(Card.Handler.fire)))
        buttonRow.isHidden = false
    }

    /// Rest is over: one tap to say what happened. The screen stays until tapped,
    /// so if the user walked away it's simply waiting when they come back.
    func askCompletion(question: String, options: [(label: String, value: String)], done: @escaping (String) -> Void) {
        countdown.stringValue = question
        countdown.font = Brand.display(26, .medium); countdown.textColor = Brand.c.ink
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttonRow.orientation = .horizontal; buttonRow.spacing = 12
        for o in options {
            let h = Card.Handler { done(o.value) }; handlers.append(h)
            let b = Brand.button(o.label, primary: o.value == options.first?.value, size: 16, target: h, action: #selector(Card.Handler.fire))
            buttonRow.addArrangedSubview(b)
        }
        buttonRow.isHidden = false
    }

    func hide() {
        BreathBell.shared.stop()
        TypedPrompt.shared.dismiss(); GratitudePanel.shared.dismiss()   // never left floating over the desktop
        reassert?.invalidate(); reassert = nil
        NSApp.presentationOptions = []
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll(); handlers.removeAll()
    }

    /// Design previews (`Supervision --previews <dir>`): the break screen without showing it.
    func previewView(frame: NSRect, title: String, reason: String, plan: BreakPlan?, extra: String?, countdownText: String) -> NSView {
        current = (title, reason, plan, extra)
        let v = makeContent(frame: frame); countdown.stringValue = countdownText; return v
    }

    /// One of the earn-a-minute tasks: once per break (the photo once a day), then redraw.
    private func reward(_ t: RewardTask) {
        guard !rewardedThisBreak.contains(t.key) else { return }
        let finish = { [weak self] in
            guard let self = self else { return }
            self.rewardedThisBreak.insert(t.key)
            self.onReward?(t)
            if let w = self.mainWindow { w.contentView = self.makeContent(frame: w.frame) }
        }
        switch t.key {
        case "photo": PhotoBooth.shared.take { ok in if ok { finish() } }
        case "gratitude": GratitudePanel.shared.ask { ok in if ok { finish() } }
        default: finish()
        }
    }

    /// Design previews: the picker as it appears after "How did that go?".
    func previewPicker(in w: NSWindow, plan: BreakPlan) {
        current = ("", plan.reason, plan, nil); mainWindow = w
        w.contentView = makeContent(frame: w.frame)
        askApps(AppGate.catalog(config: Config.load())) { _ in }
        mainWindow = nil
    }

    /// Rebuild the screen in place (More/Less, bell). The countdown refills on the next tick.
    private func redraw() {
        // Never while a question is up ("How did that go?", the phone unlock, the app picker):
        // a redraw would wipe its buttons and leave the engine waiting (the Sep 30 frozen break).
        guard buttonRow.isHidden, let w = mainWindow else { return }
        w.contentView = makeContent(frame: w.frame)
    }

    /// the user tapped one of the alternatives: swap the activity and redraw.
    private func choose(_ a: Activity) {
        guard buttonRow.isHidden, var p = current.plan else { return }   // never over a question
        p.activity = a
        current.plan = p
        onChoose?(a)
        if let w = mainWindow { w.contentView = makeContent(frame: w.frame) }
    }

    private func makeContent(frame: NSRect) -> NSView {
        let (title, reason, plan, extra) = current
        let activity = plan?.activity
        let restful = activity == nil || activity?.load == "none"
        let c = Brand.c
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 14
        func label(_ s: String, _ font: NSFont, _ color: NSColor, width: CGFloat = 760) -> NSTextField { Brand.text(s, font, color, wrap: width, align: .center) }
        let calm = !showMore && !picking
        stack.addArrangedSubview(Brand.tag(activity.map { "Break · \($0.minutes) min" } ?? "Rest"))
        stack.addArrangedSubview(label(plan?.headline ?? title, Brand.display(calm ? 28 : 40, calm ? .medium : .semibold), c.ink))
        // Calm view: a rest needs no words (the circle says it); an active break keeps its one how-to line.
        if let a = activity, !picking, !(calm && restful) {
            stack.addArrangedSubview(label("\(a.emoji)  \(a.title)", Brand.display(calm ? 18 : 22, .medium), c.ink))
            stack.addArrangedSubview(label(a.instructions, Brand.display(calm ? 15 : 17, .regular), c.muted, width: calm ? 540 : 620))
            if !calm, a.load == "physical", let hr = plan?.hrCeiling {
                stack.addArrangedSubview(label("Heart-rate ceiling today: \(hr) bpm (resting + 15). Over it, sit down.", Brand.mono(13), c.ink))
            }
        }
        // The countdown, framed by the logo's viewfinder brackets.
        moveCue.font = Brand.display(20, .medium); moveCue.textColor = c.ink; moveCue.alignment = .center
        stack.addArrangedSubview(moveCue)
        stack.addArrangedSubview(moveDots)
        stack.addArrangedSubview(moveFigure)
        moveCue.isHidden = moveCue.stringValue.isEmpty || picking; moveDots.isHidden = moveCue.isHidden; moveFigure.isHidden = moveCue.isHidden || moveDots.filled >= moveDots.total
        countdown = NSTextField(labelWithString: "")
        // Every break gets the breathing circle (user, Oct 26: a stretch break had none); only the app
        // picker keeps the bracket frame, since it's a question, not a rest.
        countdown.font = Brand.digits(picking ? 84 : 60); countdown.textColor = c.ink; countdown.alignment = .center
        let frameView: NSView = picking ? BracketView(around: countdown, padding: 30) : BreathView(around: countdown)
        stack.setCustomSpacing(30, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(frameView)
        stack.setCustomSpacing(30, after: frameView)
        buttonRow = NSStackView(); buttonRow.orientation = .horizontal; buttonRow.spacing = 12; buttonRow.isHidden = true
        stack.addArrangedSubview(buttonRow)
        if let e = extra, calm { stack.addArrangedSubview(label(e, Brand.display(15, .regular), c.muted)) }
        // Two quiet controls: the breathing bell, and "More" for everything else.
        if !picking {
            let bell = Card.Handler { [weak self] in
                BreathBell.on.toggle()
                if BreathBell.on { BreathBell.shared.start() } else { BreathBell.shared.stop() }
                self?.redraw()
            }
            let more = Card.Handler { [weak self] in self?.showMore.toggle(); self?.redraw() }
            handlers += [bell, more]
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
            row.addArrangedSubview(Brand.button(BreathBell.on ? "🔔 Bell on" : "🔕 Bell off", primary: BreathBell.on, size: 13, target: bell, action: #selector(Card.Handler.fire)))
            row.addArrangedSubview(Brand.button(showMore ? "Less" : "More", size: 13, target: more, action: #selector(Card.Handler.fire)))
            stack.addArrangedSubview(row)
        }
        // Up to three things that are also okay right now, one tap each.
        if !picking, !calm, let alts = plan?.alternatives.filter({ $0.key != activity?.key }), !alts.isEmpty {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
            row.addArrangedSubview(Brand.tag("Also fine"))
            for a in alts.prefix(3) {
                let h = Card.Handler { [weak self] in self?.choose(a) }; handlers.append(h)
                row.addArrangedSubview(Brand.button("\(a.emoji) \(a.title)", size: 14, target: h, action: #selector(Card.Handler.fire)))
            }
            stack.addArrangedSubview(row)
        }
        // Earn a minute back: $3 and one minute off the wait for each (user, Oct 18).
        if rewardsOn && !picking && !calm {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
            row.addArrangedSubview(Brand.tag("Earn a minute · $\(Rewards.dollars) each"))
            for t in Rewards.tasks {
                let done = rewardedThisBreak.contains(t.key) || (t.oncePerDay && Rewards.photoTakenToday)
                let h = Card.Handler { [weak self] in self?.reward(t) }; handlers.append(h)
                let b = Brand.button(done ? "✓ \(t.title)" : "\(t.emoji) \(t.title)", primary: false, size: 14, target: done ? nil : h, action: done ? nil : #selector(Card.Handler.fire))
                b.alphaValue = done ? 0.45 : 1
                row.addArrangedSubview(b)
            }
            stack.addArrangedSubview(row)
        }
        if let e = extra, !picking, !calm { stack.addArrangedSubview(label(e, Brand.display(18, .medium), c.ink)) }
        // The honest part: what the user wanted, why not, and what would change it.
        if let ack = plan?.acknowledgement, !picking, !calm { stack.addArrangedSubview(label(ack, Brand.display(15, .regular), c.muted, width: 640)) }
        if let u = plan?.unlock, !picking, !calm { stack.addArrangedSubview(label(u, Brand.display(14, .regular), c.muted, width: 640)) }
        if !calm { stack.addArrangedSubview(label(reason, Brand.mono(11.5), c.faint, width: 640)) }
        // Breaks stay calm even with More open: no corner cluster or tagline to read.
        return BrandScreen.make(frame: frame, content: stack, tag: "To end early, ask Claude", calm: true)
    }
}

/// Small floating card in the top-right: nudges and the morning briefing.
final class Card {
    static let shared = Card()
    private var window: NSPanel?
    private var dismissTimer: Timer?

    func showNudge(_ text: String, reason: String, seconds: Double = 25) {
        show(title: text, body: reason, buttons: [], seconds: seconds)
    }

    /// A question with buttons (the first is the recommended one). If nobody answers within
    /// `seconds`, `onTimeout` runs: an unanswered card must never decide something drastic.
    func ask(_ title: String, body: String, buttons: [(String, () -> Void)], seconds: Double, tag: String? = nil, onTimeout: @escaping () -> Void) {
        show(title: title, body: body, buttons: buttons, seconds: seconds, width: 420, tag: tag)
        timeoutAction = onTimeout
    }
    private var timeoutAction: (() -> Void)?

    /// The morning briefing: bigger, stays until dismissed (or 15 min). The title carries
    /// today's date. While there's no Whoop reading for today, a button fetches one and
    /// the card comes back with the plan rebuilt from it.
    func showBrief(title: String, body: @escaping () -> String) {
        var buttons: [(String, () -> Void)] = [("Got it", {})]
        if !Baseline.load().isToday {
            buttons.insert(("Get Whoop reading", { [weak self] in
                self?.showNudge("Getting your Whoop reading… ⏳", reason: "Asking Claude for today's recovery and sleep. About 15 seconds.", seconds: 180)
                WhoopFetch.run { result in
                    switch result {
                    case .ok(let r):
                        Store.shared.event("whoop_fetch", "recovery \(r), fetched from the morning card")
                        self?.showBrief(title: "Here's today, with Whoop \(r) 📈", body: body)
                    case .notScoredYet:
                        self?.showNudge("Whoop hasn't scored today yet", reason: "Your recovery usually appears a little after you wake. Try again in a bit; until then today counts as yellow.", seconds: 40)
                    case .failed(let why):
                        self?.showNudge("Couldn't get Whoop 😕", reason: why, seconds: 60)
                    }
                }
            }), at: 0)
        }
        show(title: title, body: body(), buttons: buttons, seconds: 900, width: 460, tag: Self.dateLine.string(from: Date()))
    }
    private static let dateLine: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE · MMM d"; return f }()

    private func show(title: String, body: String, buttons: [(String, () -> Void)], seconds: Double, width: CGFloat = 360, tag: String? = nil) {
        hide()
        let c = Brand.c
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 10), styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true; p.isMovableByWindowBackground = true
        p.level = .floating; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = c.paper; p.appearance = Brand.appearance
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let head = NSStackView(views: [Brand.wordmark(height: 13), NSView(), Brand.tag(tag ?? Day.clock(Date()))])
        head.orientation = .horizontal; head.widthAnchor.constraint(equalToConstant: width - 36).isActive = true
        stack.addArrangedSubview(head)
        stack.setCustomSpacing(14, after: head)
        stack.addArrangedSubview(Brand.text(title, Brand.display(16, .semibold), c.ink, wrap: width - 36))
        stack.addArrangedSubview(Brand.text(body, Brand.display(13, .regular), c.muted, wrap: width - 36))
        if !buttons.isEmpty {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
            for (i, (label, action)) in buttons.enumerated() {
                let h = Handler { action(); self.hide() }; handlers.append(h)
                row.addArrangedSubview(Brand.button(label, primary: i == 0, size: 13, target: h, action: #selector(Handler.fire)))
            }
            stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(row)
        }
        let content = DotGridView(); content.spacing = 18; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        p.contentView = content
        p.setContentSize(NSSize(width: width, height: stack.fittingSize.height))
        if let s = NSScreen.main {
            // Sit below the how-are-you card if it's open, so the two never overlap.
            let top = HotCorner.shared.openFrame.map { $0.minY - 8 } ?? s.visibleFrame.maxY - 12
            p.setFrameTopLeftPoint(NSPoint(x: s.visibleFrame.maxX - width - 16, y: top))
        }
        p.orderFrontRegardless()
        window = p
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            let t = self.timeoutAction; self.hide(); t?()
        }
    }

    var previewWindow: NSPanel? { window }
    func previewShow(title: String, body: String, buttons: [String], tag: String?, width: CGFloat) {
        show(title: title, body: body, buttons: buttons.map { ($0, {}) }, seconds: 30, width: width, tag: tag)
    }

    func hide() { dismissTimer?.invalidate(); timeoutAction = nil; window?.orderOut(nil); window = nil; handlers.removeAll() }

    private var handlers: [Handler] = []
    final class Handler: NSObject { let f: () -> Void; init(_ f: @escaping () -> Void) { self.f = f }; @objc func fire() { f() } }
}

// MARK: - The 1–10 questions (the corner card and after every break)

enum Questions {
    /// Display order. Every label is phrased so 10 is the good end and 1 is really bad
    /// ("Brain fog: 1" was once read as "no fog" and locked a good day). The keys keep
    /// their original names because they're the database columns.
    static let all = [("overall", "Overall"), ("headache", "How's my head"), ("fog", "Clear (no brain fog)"), ("tired", "Energy"), ("crashy", "Not crashing")]
    /// Column order in the `symptoms` and `quickchecks` tables.
    static let columns = ["fog", "tired", "headache", "crashy", "overall"]
}

/// Rows of 1…10 buttons, one row per question. Grayscale-safe: the chosen button stays
/// pressed, the others fade, and the chosen number is spelled out at the end of the row.
final class ScaleGrid {
    let view = NSStackView()
    private(set) var answers: [String: Int] = [:]
    var onChange: (() -> Void)?
    var complete: Bool { answers.count == questions.count }
    private let questions: [(String, String)]
    private var buttons: [String: [NSButton]] = [:], values: [String: NSTextField] = [:], handlers: [Card.Handler] = []

    init(_ questions: [(String, String)], labelWidth: CGFloat, buttonWidth: CGFloat, fontSize: CGFloat) {
        self.questions = questions
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 8
        for (key, title) in questions {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 4
            let l = Brand.text(title, Brand.display(fontSize, .medium), Brand.c.ink)
            l.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
            row.addArrangedSubview(l)
            for i in 1...10 {
                let h = Card.Handler { [weak self] in self?.choose(key, i) }; handlers.append(h)
                let b = ScaleButton(n: i, size: fontSize - 1, target: h)
                b.widthAnchor.constraint(equalToConstant: buttonWidth).isActive = true
                b.heightAnchor.constraint(equalToConstant: buttonWidth).isActive = true
                row.addArrangedSubview(b); buttons[key, default: []].append(b)
            }
            let v = NSTextField(labelWithString: "—"); v.font = Brand.mono(fontSize, .semibold); v.textColor = Brand.c.ink; v.alignment = .right
            v.widthAnchor.constraint(equalToConstant: buttonWidth).isActive = true
            row.addArrangedSubview(v); values[key] = v
            view.addArrangedSubview(row)
        }
    }

    private func choose(_ key: String, _ n: Int) {
        answers[key] = n
        buttons[key]?.enumerated().forEach { ($0.element as? ScaleButton)?.selected = $0.offset + 1 == n; $0.element.alphaValue = $0.offset + 1 == n ? 1 : 0.55 }
        values[key]?.stringValue = "\(n)"
        onChange?()
    }
}

/// One 1–10 square: hairline outline, mono digit; chosen = solid ink.
final class ScaleButton: NSButton {
    private let n: Int, size: CGFloat
    var selected = false { didSet { restyle() } }
    init(n: Int, size: CGFloat, target: Card.Handler) {
        self.n = n; self.size = size
        super.init(frame: .zero)
        self.target = target; action = #selector(Card.Handler.fire)
        isBordered = false; wantsLayer = true; focusRingType = .none
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func restyle() {
        let c = Brand.c
        layer?.cornerRadius = 6; layer?.borderWidth = 1
        layer?.borderColor = (selected ? c.ink : c.ink.withAlphaComponent(0.16)).cgColor
        layer?.backgroundColor = (selected ? c.ink : c.paper).cgColor
        attributedTitle = NSAttributedString(string: "\(n)", attributes: [.font: Brand.mono(size, .medium), .foregroundColor: selected ? c.paper : c.ink])
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// One app on the picker: its icon and name, faded until chosen.
final class AppTile: NSButton {
    var on = false { didSet { restyle() } }
    init(app: AppGate.App) {
        super.init(frame: NSRect(x: 0, y: 0, width: 92, height: 96))
        isBordered = false; wantsLayer = true; focusRingType = .none
        image = app.icon; image?.size = NSSize(width: 56, height: 56)
        imagePosition = .imageAbove
        attributedTitle = NSAttributedString(string: app.name, attributes: [.font: Brand.display(11.5, .medium), .foregroundColor: Brand.c.ink])
        widthAnchor.constraint(equalToConstant: 92).isActive = true; heightAnchor.constraint(equalToConstant: 96).isActive = true
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func restyle() {
        alphaValue = on ? 1 : 0.32
        layer?.cornerRadius = 14; layer?.borderWidth = on ? 1.5 : 0
        layer?.borderColor = Brand.c.ink.cgColor
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A small typed-statement prompt over the lock screen (statements rotate and can't be pasted).
final class TypedPrompt {
    static let shared = TypedPrompt()
    private var panel: NSPanel?
    private var handlers: [Card.Handler] = []

    func ask(tag: String, title: String, statement: String, done: @escaping (Bool) -> Void) {
        guard panel == nil else { return }
        let c = Brand.c, width: CGFloat = 480
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 10), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
        p.backgroundColor = c.paper; p.appearance = Brand.appearance
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22); stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(Brand.tag(tag))
        stack.addArrangedSubview(Brand.text(title, Brand.display(18, .semibold), c.ink, wrap: width - 44))
        stack.addArrangedSubview(Brand.text("Type \u{201C}\(statement)\u{201D} and press Return.", Brand.display(13, .regular), c.muted, wrap: width - 44))
        let field = Brand.field("type it out, no pasting", width: width - 44, size: 14, noPaste: true)
        let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").joined(separator: " ") }
        let ok = Card.Handler { [weak self] in
            guard norm(field.stringValue) == norm(statement) else { NSSound.beep(); return }
            self?.close(); done(true)
        }
        let cancel = Card.Handler { [weak self] in self?.close(); done(false) }
        handlers = [ok, cancel]
        field.target = ok; field.action = #selector(Card.Handler.fire)
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(Brand.button("Never mind", size: 13, target: cancel, action: #selector(Card.Handler.fire)))
        let content = DotGridView(); content.spacing = 18; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        p.contentView = content
        p.setContentSize(NSSize(width: width, height: stack.fittingSize.height))
        if let s = NSScreen.main { p.setFrameOrigin(NSPoint(x: s.frame.midX - width / 2, y: s.frame.midY - p.frame.height / 2)) }
        p.orderFrontRegardless(); p.makeKey(); p.makeFirstResponder(field)
        panel = p
    }

    func dismiss() { close() }
    private func close() { panel?.orderOut(nil); panel = nil; handlers = [] }
}
