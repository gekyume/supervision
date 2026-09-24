import EventKit
import Foundation

/// Reads meetings from every calendar synced into macOS (Google included) and
/// writes an hourly log into a calendar you choose (profile.json, default "Energy log").
/// If it's a Google calendar, macOS syncs it in the background; the Calendar app doesn't need to be open. Every
/// summary is also kept in the local database, so nothing is ever only "there".
final class CalendarBridge {
    static let shared = CalendarBridge()
    let store = EKEventStore()
    private(set) var granted = false
    private var logCalendar: EKCalendar?

    func start() {
        store.requestAccess(to: .event) { ok, err in
            self.granted = ok
            Store.shared.event("permission", ok ? "Calendar access granted" : "Calendar access denied: \(err?.localizedDescription ?? "")")
            if ok { DispatchQueue.main.async { self.ensureLogCalendar() } }
        }
    }

    private static let meetingMarkers = ["zoom.us", "meet.google", "teams.microsoft", "webex", "whereby", "around.co", "tuple"]
    private func isOurs(_ c: EKCalendar) -> Bool { c.title == Profile.logCalendarName || c.calendarIdentifier == logCalendar?.calendarIdentifier }

    /// True if any calendar event with a video link overlaps [now-buffer, now+buffer].
    func meetingNearby(bufferMinutes: Double) -> String? {
        guard granted else { return nil }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-bufferMinutes * 60),
                                            end: now.addingTimeInterval(bufferMinutes * 60), calendars: nil)
        for e in store.events(matching: pred) where !e.isAllDay && !isOurs(e.calendar) {
            let hay = [e.title, e.location, e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: " ").lowercased()
            if Self.meetingMarkers.contains(where: { hay.contains($0) }) { return e.title ?? "a meeting" }
        }
        return nil
    }

    /// Meeting minutes today (video-link events), so a heavy meeting day lowers the work budget.
    func meetingMinutesToday() -> Double {
        guard granted else { return 0 }
        let start = Calendar.current.startOfDay(for: Date())
        let pred = store.predicateForEvents(withStart: start, end: Date(), calendars: nil)
        var total = 0.0
        for e in store.events(matching: pred) where !e.isAllDay && !isOurs(e.calendar) {
            let hay = [e.title, e.location, e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: " ").lowercased()
            if Self.meetingMarkers.contains(where: { hay.contains($0) }) {
                total += min(e.endDate, Date()).timeIntervalSince(e.startDate) / 60
            }
        }
        return max(0, total)
    }

    /// Prefer a synced (e.g. Google) calendar with the name from profile.json, so the
    /// log shows up on every device. Google calendars can't be created from macOS, so
    /// if it's missing we fall back to a local calendar and say so.
    private func ensureLogCalendar() {
        let name = Profile.logCalendarName
        let cals = store.calendars(for: .event).filter { $0.allowsContentModifications }
        if let c = cals.first(where: { $0.title == name && $0.source.sourceType == .calDAV && !$0.source.title.lowercased().contains("icloud") })
            ?? cals.first(where: { $0.title == name }) {
            logCalendar = c; return
        }
        let c = EKCalendar(for: .event, eventStore: store)
        c.title = name
        c.source = store.sources.first(where: { $0.sourceType == .local })
        do { try store.saveCalendar(c, commit: true); logCalendar = c
             Store.shared.event("calendar", "No calendar named '\(name)' found; created a local one. For phone sync, create '\(name)' in Google Calendar and restart.") }
        catch { Store.shared.event("calendar", "Could not create a log calendar: \(error.localizedDescription)") }
    }

    /// Called at the top of every hour with the previous hour's activity.
    func writeHourSummary(from: Date, to: Date) {
        guard granted else { return }
        if logCalendar == nil { ensureLogCalendar() }
        guard let cal = logCalendar else { return }
        let secs = Store.shared.activeSeconds(from: from, to: to)
        let workSecs = secs.filter { $0.key != "leisure" }.values.reduce(0, +)
        guard workSecs >= 120 else { return } // skip empty hours
        let parts = secs.sorted { $0.value > $1.value }.prefix(4).map { "\(Int($0.value / 60))m \($0.key)" }
        let ledger = Store.shared.titleLedger(from: from, to: to, limit: 15)
        var byCat: [String: [String]] = [:]
        for l in ledger { byCat[l.category, default: []].append("\(l.minutes)m  \(l.title)  (\(l.app))") }
        let worked = byCat.sorted { ($0.value.count, $0.key) > ($1.value.count, $1.key) }
            .map { "\($0.key.uppercased())\n" + $0.value.map { "  • " + $0 }.joined(separator: "\n") }.joined(separator: "\n")
        let rests = Store.shared.eventDetails(kind: "break_done", since: from).map { $0.split(separator: "|").first.map(String.init) ?? "" }
        let checkins = Store.shared.eventDetails(kind: "checkin", since: from)
        let ev = EKEvent(eventStore: store)
        ev.calendar = cal
        ev.startDate = from; ev.endDate = to
        ev.title = "🧠 \(Int(workSecs / 60))m · " + parts.joined(separator: " · ")
        ev.notes = "\(worked)\n\nBreaks: \(rests.isEmpty ? "none" : rests.joined(separator: ", "))"
            + (checkins.isEmpty ? "" : "\nCheck-in: \(checkins.joined(separator: "; "))")
            + "\n\nLogged by Supervision from window titles, kept on this Mac."
        do { try store.save(ev, span: .thisEvent, commit: true) }
        catch { Store.shared.event("calendar", "Hour summary failed: \(error.localizedDescription)") }
    }

    /// Each break becomes its own short event, so the calendar shows the day's rhythm.
    func writeBreakEvent(from: Date, to: Date, activity: Activity?, outcome: String) {
        guard granted, let cal = logCalendar, to.timeIntervalSince(from) >= 120 else { return }
        let a = activity ?? Activity.catalog["rest"]!
        let ev = EKEvent(eventStore: store)
        ev.calendar = cal; ev.startDate = from; ev.endDate = to
        ev.title = outcome == "skipped" ? "⏭️ Break (not really rested)" : "\(a.emoji) \(a.title)"
        ev.notes = "Outcome: \(outcome). Logged by Supervision."
        do { try store.save(ev, span: .thisEvent, commit: true) }
        catch { Store.shared.event("calendar", "Break event failed: \(error.localizedDescription)") }
    }
}

/// Zoom in-meeting detection: Zoom spawns a `CptHost` process only while in a call.
enum ZoomGuard {
    static func inMeeting() -> Bool {
        let p = Process(); p.launchPath = "/usr/bin/pgrep"; p.arguments = ["-x", "CptHost"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }
}
