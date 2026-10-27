import AppKit

/// The "how are you" card: five optional 1–10 questions (1 = really bad, 10 = the best)
/// and a one-line note for what you did ("drank water", "ate"). It opens when the pointer rests in the top-right corner, and on its
/// own after every break. It never blocks anything: answer any, all or none, keep
/// working. Answers are saved when it closes and run through the symptom gate. Polls the
/// pointer position (no extra permission), and stays out of the way during a
/// break lock.
/// A panel that can take typing (for the note) without activating the whole app.
final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

final class HotCorner {
    static let shared = HotCorner()
    private var timer: Timer?
    private var dwellStart: Date?
    private var cooldownUntil = Date.distantPast
    private var panel: NSPanel?
    private var grid: ScaleGrid?
    private var noteField: NSTextField?
    /// Where the card is, so other cards can sit below it instead of on top.
    var openFrame: NSRect? { panel?.frame }
    private var handlers: [Card.Handler] = []
    private var afterBreak = false            // opened by the engine after a break (vs the corner)
    private var openedAt = Date()
    private var touched = false               // answered anything yet
    private var lastInside = Date()

    private let cornerSize: CGFloat = 4       // pixels from the very corner
    private let dwell: TimeInterval = 0.5     // how long to rest there before it opens

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        if let p = panel {
            if p.frame.insetBy(dx: -30, dy: -30).contains(NSEvent.mouseLocation) { lastInside = Date() }
            // Corner card: close once the pointer has left it for a moment. After-break card:
            // stays up to 3 minutes untouched (you may be busy); once answered, same as corner.
            // Never while a note is being typed.
            if p.isKeyWindow, !(noteField?.stringValue.isEmpty ?? true) { lastInside = Date() }
            let away = -lastInside.timeIntervalSinceNow > 2.5
            if afterBreak && !touched { if -openedAt.timeIntervalSinceNow > 180 { close() } }
            else if away { close() }
            return
        }
        guard !LockScreen.shared.isShowing, Date() > cooldownUntil, let screen = NSScreen.main else { dwellStart = nil; return }
        let m = NSEvent.mouseLocation, f = screen.frame
        if m.x >= f.maxX - cornerSize && m.y >= f.maxY - cornerSize {
            if dwellStart == nil { dwellStart = Date() }
            else if -dwellStart!.timeIntervalSinceNow >= dwell { open(on: screen, afterBreak: false, title: "Quick check 🙂  How are you, right now?") }
        } else { dwellStart = nil }
    }

    var isOpen: Bool { panel != nil }
    var previewPanel: NSPanel? { panel }
    func previewClose() { panel?.orderOut(nil); panel = nil }

    /// From the status pill: the same quick check as the corner.
    func openQuickCheck() {
        guard panel == nil, !LockScreen.shared.isShowing, let screen = NSScreen.main else { return }
        open(on: screen, afterBreak: false, title: "Quick check 🙂  How are you, right now?")
    }

    /// Called by the engine when a break ends.
    func presentAfterBreak(title: String) {
        guard panel == nil, let screen = NSScreen.main else { return }
        open(on: screen, afterBreak: true, title: title)
    }

    private func open(on screen: NSScreen, afterBreak: Bool, title: String) {
        dwellStart = nil; handlers = []; self.afterBreak = afterBreak; openedAt = Date(); touched = false
        let width: CGFloat = 530
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 10), styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
        p.level = .statusBar; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = Brand.c.paper; p.appearance = Brand.appearance
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let head = NSStackView(views: [Brand.wordmark(height: 13), NSView(), Brand.tag(afterBreak ? "After the break" : "Check-in")])
        head.orientation = .horizontal; head.widthAnchor.constraint(equalToConstant: width - 36).isActive = true
        stack.addArrangedSubview(head)
        stack.setCustomSpacing(14, after: head)
        stack.addArrangedSubview(Brand.text(title, Brand.display(16, .semibold), Brand.c.ink))
        stack.addArrangedSubview(Brand.tag(Scale.label + " · skip any"))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)
        let grid = ScaleGrid(Questions.all, labelWidth: 132, buttonWidth: 28, fontSize: 13)
        grid.onChange = { [weak self] in
            self?.lastInside = Date(); self?.touched = true
        }
        self.grid = grid
        stack.addArrangedSubview(grid.view)
        // One line for what you did: water, food, a lie-down. Optional; Return saves.
        let note = Brand.field("What did you do? e.g. drank water, ate, lay down (optional)", width: width - 36, size: 13)
        let enterH = Card.Handler { [weak self] in self?.close() }; handlers.append(enterH)
        note.target = enterH; note.action = #selector(Card.Handler.fire)
        noteField = note
        stack.addArrangedSubview(note)
        let doneH = Card.Handler { [weak self] in self?.close() }; handlers.append(doneH)
        let done = Brand.button("Done", primary: true, size: 13, target: doneH, action: #selector(Card.Handler.fire))
        let skipH = Card.Handler { [weak self] in self?.grid = nil; self?.noteField = nil; self?.close() }; handlers.append(skipH)
        let skip = Brand.button("Not now", size: 13, target: skipH, action: #selector(Card.Handler.fire))
        let actions = NSStackView(views: [done, skip]); actions.spacing = 8
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(actions)
        let content = DotGridView(); content.spacing = 18; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        p.contentView = content
        p.setContentSize(NSSize(width: width, height: stack.fittingSize.height))
        p.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - p.frame.width - 8, y: screen.visibleFrame.maxY - 6))
        p.orderFrontRegardless()
        p.makeKey()                         // so the note field can be typed into straight away
        panel = p; lastInside = Date()
    }

    private func close() {
        guard let p = panel else { return }
        p.orderOut(nil); panel = nil; handlers = []
        cooldownUntil = Date().addingTimeInterval(3)
        let answers = grid?.answers ?? [:]; grid = nil
        let note = noteField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; noteField = nil
        guard !answers.isEmpty || !note.isEmpty else {
            if afterBreak { Store.shared.event("symptoms_skipped", "after break") }
            return
        }
        Store.shared.saveAnswers(answers, note: note, afterBreak: afterBreak, context: afterBreak ? Engine.shared.loadContext() : "")
        let pairs = Questions.all.compactMap { k, t in answers[k].map { (t.lowercased(), $0) } }
        let summary = pairs.map { "\($0.0) \($0.1)" }.joined(separator: ", ") + (pairs.isEmpty ? "" : " (1 worst … 10 best)")
        Store.shared.event(afterBreak ? "symptoms" : "quick_check", summary + (note.isEmpty ? "" : (pairs.isEmpty ? "" : " · ") + "note: \(note)"))
        if !answers.isEmpty { Engine.shared.applyGate(answers) }
        CalendarBridge.shared.writeQuickCheck(at: Date(), answers: pairs, note: note, afterBreak: afterBreak)
    }
}
