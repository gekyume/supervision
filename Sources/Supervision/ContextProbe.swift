import AppKit
import ApplicationServices

/// Some apps (Superhuman, Claude, Slack…) put only their own name in the window
/// title. For those we take a small walk through the accessibility tree to find
/// what's actually open: the email thread subject, the Claude session name, the
/// Slack channel. Bounded (≤ 400 nodes) and cached for 30 s per app, so it stays
/// cheap. Everything stays on this Mac.
enum ContextProbe {
    private static var cache: [pid_t: (Date, String?)] = [:]

    static func contextLine(pid: pid_t, app: String) -> String? {
        if let (t, v) = cache[pid], -t.timeIntervalSinceNow < 30 { return v }
        let v = probe(pid: pid, app: app)
        cache[pid] = (Date(), v)
        return v
    }

    private static let boilerplate = ["what can i help", "find, write, schedule", "add to the knowledge base", "auto labels",
                                      "claude is responding", "use the up and down arrow", "claude responded", "search", "inbox",
                                      "arrow keys move", "press enter", "drag to", "click to"]
    private static let dateHeader = try! NSRegularExpression(pattern: #"^(today|yesterday|[a-z]+ \d{1,2}(st|nd|rd|th)?)$"#, options: .caseInsensitive)

    private static func probe(pid: pid_t, app: String) -> String? {
        let ax = AXUIElementCreateApplication(pid)
        var win: AnyObject?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win else { return nil }
        var queue: [AXUIElement] = [w as! AXUIElement]
        var seen = 0
        var texts: [(role: String, value: String)] = []
        while !queue.isEmpty && seen < 400 {
            let e = queue.removeFirst(); seen += 1
            var r: AnyObject?; var v: AnyObject?
            AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r)
            let role = (r as? String) ?? ""
            if role == "AXHeading" || role == "AXStaticText" {
                AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &v)
                if let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), s.count >= 6, s.count <= 120 {
                    texts.append((role, s))
                }
            }
            var kids: AnyObject?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success, let k = kids as? [AXUIElement] {
                queue.append(contentsOf: k.prefix(60))
            }
        }
        let a = app.lowercased()
        // Headings are the most trustworthy signal wherever they exist.
        if let h = texts.first(where: { $0.role == "AXHeading" && !isBoilerplate($0.value) }) { return h.value }
        if a.contains("claude") { return texts.first(where: { !isBoilerplate($0.value) })?.value }
        if a.contains("superhuman") {
            // Subject = first short line after a date group header ("Yesterday", "September 21st").
            var afterDate = false
            for t in texts {
                if dateHeader.firstMatch(in: t.value, range: NSRange(t.value.startIndex..., in: t.value)) != nil { afterDate = true; continue }
                if afterDate && t.value.count <= 80 && !t.value.contains("@") && !isBoilerplate(t.value) { return t.value }
            }
            return nil
        }
        if a.contains("slack") { return texts.first(where: { $0.value.hasPrefix("#") || $0.value.hasPrefix("@") })?.value }
        return nil
    }

    private static func isBoilerplate(_ s: String) -> Bool {
        let l = s.lowercased()
        return boilerplate.contains(where: { l.hasPrefix($0) }) || l.contains("@") && l.contains("(")
    }
}
