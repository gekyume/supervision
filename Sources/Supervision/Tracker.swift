import AppKit
import ApplicationServices

/// Samples the front app + window title every 5 s and whether the user is idle.
/// Needs the Accessibility permission (macOS asks once).
final class Tracker {
    static let shared = Tracker()
    private var timer: Timer?
    private(set) var lastApp = ""
    private(set) var lastTitle = ""
    private(set) var lastCategory = "other"

    func start() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            Store.shared.event("permission", "Accessibility not yet granted — window titles unavailable until it is")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
    }

    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func tick() {
        let idle = Tracker.idleSeconds > 60
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let name = app.localizedName ?? "unknown"
        var title = ""
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var win: AnyObject?
        if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win {
            var t: AnyObject?
            if AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success {
                title = (t as? String) ?? ""
            }
        }
        // Skip our own break screen so rest never counts as work.
        if name == "Supervision" { return }
        // Uninformative title (just the app name)? Ask the accessibility tree what's open.
        if title.isEmpty || title == name, let ctx = ContextProbe.contextLine(pid: app.processIdentifier, app: name) {
            title = ctx
        }
        let cat = Categorizer.category(app: name, title: title)
        lastApp = name; lastTitle = title; lastCategory = cat
        Store.shared.sample(app: name, title: title, category: cat, idle: idle)
    }
}
