import AppKit

/// The app picker (user, Oct 24): after each break, the apps the user uses appear faded on the
/// lock screen; the ones tapped are this block's apps. Everything else gets a normal Quit
/// (unsaved work asks first) and, if opened mid-block, is closed with a card offering to add it
/// by typing a short statement. Always allowed: Supervision, Finder and `config.appGateAlways`.
/// Nothing is blocked while paused or during a live call / calendar meeting. Decisions: AppGateRule.
final class AppGate {
    static let shared = AppGate()
    private(set) var picked: Set<String>?          // nil = no picker in force (before the first break, paused, after a lock)
    private var observers: [NSObjectProtocol] = []
    private var addPanel: NSPanel?
    private var handlers: [Card.Handler] = []
    private var lastAddStatement: Int?

    struct App { let name: String, bundleID: String, icon: NSImage }

    /// The apps the user actually uses: the most-used regular apps of the last 14 days (≥ 10 min).
    static func catalog(config: Config) -> [App] {
        let skip = always(config)
        var seen = Set<String>(), out: [App] = []
        let installed = installedApps()
        for raw in Store.shared.topApps(days: 14, minMinutes: 10, limit: 30) {
            let name = raw.filter { !$0.unicodeScalars.allSatisfy { $0.properties.isDefaultIgnorableCodePoint } }   // "\u{200E}WhatsApp"
            guard let path = installed[name.lowercased()], let id = Bundle(path: path)?.bundleIdentifier,
                  !skip.contains(id), !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(App(name: name, bundleID: id, icon: NSWorkspace.shared.icon(forFile: path)))
            if out.count == 18 { break }
        }
        return out
    }
    /// Real apps only (no loginwindow or other system processes), by every name they go by:
    /// file name, bundle name, display name ("zoom.us" is "Zoom").
    private static func installedApps() -> [String: String] {
        var map: [String: String] = [:]
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for root in roots {
            for f in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where f.hasSuffix(".app") {
                let path = root + "/" + f
                var names = [String(f.dropLast(4))]
                if let b = Bundle(path: path) {
                    for k in ["CFBundleDisplayName", "CFBundleName"] { if let n = b.localizedInfoDictionary?[k] as? String ?? b.infoDictionary?[k] as? String { names.append(n) } }
                }
                for n in names where map[n.lowercased()] == nil { map[n.lowercased()] = path }
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let n = app.localizedName, let p = app.bundleURL?.path, map[n.lowercased()] == nil { map[n.lowercased()] = p }
        }
        return map
    }

    static func always(_ config: Config) -> Set<String> {
        Set(config.appGateAlways + ["com.apple.finder", Bundle.main.bundleIdentifier ?? ""])
    }

    /// The picker's answer: in force until the next break, a pause or a lock.
    func begin(_ ids: Set<String>, config: Config) {
        picked = ids
        Store.shared.event("apps_picked", ids.isEmpty ? "none (only always-allowed apps)" : ids.sorted().joined(separator: ", "))
        if observers.isEmpty {
            let nc = NSWorkspace.shared.notificationCenter
            for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
                observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] note in
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                    self?.check(app, config: Engine.shared.config, opened: true)
                })
            }
        }
        NSWorkspace.shared.runningApplications.forEach { check($0, config: config, opened: false) }
    }

    /// Let one app into this block (e.g. "just one reply" from the avoidance card).
    func allow(_ id: String) { picked?.insert(id) }

    func end() { picked = nil; addPanel?.orderOut(nil); addPanel = nil }

    private func blocks(_ app: NSRunningApplication, config: Config) -> Bool {
        guard app.activationPolicy == .regular, let id = app.bundleIdentifier, picked != nil else { return false }
        return AppGateRule.blocks(bundleID: id, picked: picked, always: Self.always(config), paused: Control.load().isPaused,
                                  inCall: Engine.shared.liveCall(calendarBuffer: 5) != nil)
    }

    private func check(_ app: NSRunningApplication, config: Config, opened: Bool) {
        guard blocks(app, config: config), let id = app.bundleIdentifier else { return }
        let name = app.localizedName ?? id
        app.terminate()
        Store.shared.event("app_blocked", "\(name)\(opened ? " (opened mid-block)" : " (open at block start)")")
        if opened { offerAdd(name: name, bundleID: id, app: app) }
    }

    /// "Not on this block's list. Add it?" Adding means typing the statement; then it reopens.
    private func offerAdd(name: String, bundleID: String, app: NSRunningApplication) {
        addPanel?.orderOut(nil); handlers = []
        let c = Brand.c, width: CGFloat = 400
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 10), styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
        p.level = .statusBar; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = c.paper; p.appearance = Brand.appearance
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18); stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(Brand.tag("Not on this block's list"))
        stack.addArrangedSubview(Brand.text("\(name) is closed for this block.", Brand.display(16, .semibold), c.ink, wrap: width - 36))
        let st = Statements.pick(Statements.addApp, last: lastAddStatement, roll: Int.random(in: 0..<1000), app: name, time: Day.clock(Date()))
        lastAddStatement = st.index
        let statement = st.text
        stack.addArrangedSubview(Brand.text("To add it, type \u{201C}\(statement)\u{201D} and press Return.", Brand.display(13, .regular), c.muted, wrap: width - 36))
        let field = Brand.field("type it out, no pasting", width: width - 36, size: 13, noPaste: true)
        let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").joined(separator: " ") }
        let add = Card.Handler { [weak self] in
            guard let self = self, norm(field.stringValue) == norm(statement) else { return }
            self.picked?.insert(bundleID)
            Store.shared.event("app_added", "\(name) added to this block")
            p.orderOut(nil); self.addPanel = nil
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
        }
        let dismiss = Card.Handler { [weak self] in p.orderOut(nil); self?.addPanel = nil }
        handlers = [add, dismiss]
        field.target = add; field.action = #selector(Card.Handler.fire)
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(Brand.button("Not now", size: 13, target: dismiss, action: #selector(Card.Handler.fire)))
        let content = DotGridView(); content.spacing = 18; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        p.contentView = content
        p.setContentSize(NSSize(width: width, height: stack.fittingSize.height))
        if let s = NSScreen.main { p.setFrameTopLeftPoint(NSPoint(x: s.visibleFrame.maxX - width - 16, y: s.visibleFrame.maxY - 12)) }
        p.orderFrontRegardless(); p.makeKey(); p.makeFirstResponder(field)
        addPanel = p
    }
}
