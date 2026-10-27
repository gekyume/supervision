import AppKit
import ApplicationServices

/// The "proactstinating" call-out (user, Oct 25): avoiding texts, email and the to-do list usually
/// means tired. Every 5 min the Dock's unread badges on the watched apps are read (Accessibility);
/// if they've climbed while none of those apps was opened for 90 min and you were busy elsewhere
/// (AvoidRule), one card says so and offers rest first. Never a lock.
final class Avoidance {
    static let shared = Avoidance()
    private var history: [(Date, Int)] = []
    private var lastRead = Date.distantPast

    /// Unread per watched app, from the Dock's red badges.
    static func badges(watch: [String]) -> [String: Int] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let ax = AXUIElementCreateApplication(dock.processIdentifier)
        var kids: AnyObject?
        guard AXUIElementCopyAttributeValue(ax, kAXChildrenAttribute as CFString, &kids) == .success, let lists = kids as? [AXUIElement] else { return [:] }
        var out: [String: Int] = [:]
        for list in lists {
            var items: AnyObject?
            guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &items) == .success, let arr = items as? [AXUIElement] else { continue }
            for item in arr {
                var t: AnyObject?, b: AnyObject?
                guard AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &t) == .success, let title = t as? String,
                      watch.contains(where: { title.localizedCaseInsensitiveContains($0) }) else { continue }
                if AXUIElementCopyAttributeValue(item, "AXStatusLabel" as CFString, &b) == .success, let s = b as? String {
                    out[title] = Int(s.filter(\.isNumber)) ?? (s.isEmpty ? 0 : 1)   // "•" counts as 1
                } else { out[title] = 0 }
            }
        }
        return out
    }

    /// Called from the engine's work tick. `onCallOut` gets the card text when it's time.
    func check(config: Config, blocked: Bool, onCallOut: (_ text: String, _ topApp: String?) -> Void) {
        guard config.avoidWatch.count > 0, -lastRead.timeIntervalSinceNow >= 300 else { return }
        lastRead = Date()
        let b = Self.badges(watch: config.avoidWatch), total = b.values.reduce(0, +)
        history.append((Date(), total)); history.removeAll { -$0.0.timeIntervalSinceNow > 3 * 3600 }
        guard let then = history.first(where: { -$0.0.timeIntervalSinceNow <= 95 * 60 }) else { return }
        let window = Date().addingTimeInterval(-90 * 60)
        let opened = Store.shared.lastAppUse(names: config.avoidWatch)
        let sinceOpened = opened.map { -$0.timeIntervalSinceNow / 60 } ?? 999
        let active = Store.shared.activeSeconds(from: window, to: Date()).values.reduce(0, +) / 60
        let calls = Store.shared.countEvents(kind: "avoid_callout", since: Day.today)
        let last = Store.shared.lastEvent(kind: "avoid_callout", since: Day.today)?.0
        guard AvoidRule.shouldCallOut(unreadNow: total, unreadThen: then.1, minutesSinceOpened: sinceOpened, activeMinutes: active,
                                      callsToday: calls, hoursSinceLast: last.map { -$0.timeIntervalSinceNow / 3600 } ?? 99, blocked: blocked) else { return }
        let parts = b.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
        let top = b.max { $0.value < $1.value }?.key
        let text = "\(parts.joined(separator: ", ")) unread (up from \(then.1) to \(total)), and none of them opened in \(Int(min(sinceOpened, 600))) min while you worked on other things. For you, that pattern usually means tired."
        Store.shared.event("avoid_callout", text)
        onCallOut(text, top)
    }
}
