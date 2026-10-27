import EventKit
import Foundation

/// Reads meetings from every calendar synced into macOS (Google included) and
/// writes the log (hourly summaries, breaks, corner checks) into the calendar named in
/// profile.json (default "Energy log"). If that's a Google calendar, macOS syncs it in the
/// background; the Calendar app doesn't need to be open. The same data stays in the local
/// database, so nothing is ever only "there".
final class CalendarBridge {
    static let shared = CalendarBridge()
    let store = EKEventStore()
    private(set) var granted = false
    private var logCalendar: EKCalendar?

    func start() {
        store.requestAccess(to: .event) { ok, err in
            self.granted = ok
            Store.shared.event("permission", ok ? "Calendar access granted" : "Calendar access denied: \(err?.localizedDescription ?? "")")
            if ok { DispatchQueue.main.async { self.ensureLogCalendar(); self.logSources() } }
        }
    }

    /// Which accounts the meeting check can see, logged at start (`supervisionctl log`), so a
    /// missing work calendar is visible: meetings on a calendar that isn't here can't protect you.
    private func logSources() {
        let list = store.sources.compactMap { src -> String? in
            let cals = src.calendars(for: .event).map(\.title).sorted()
            return cals.isEmpty ? nil : "\(src.title) [\(cals.joined(separator: ", "))]"
        }.sorted()
        Store.shared.event("calendars", list.joined(separator: "; "))
    }

    private static let meetingMarkers = ["zoom.us", "meet.google", "teams.microsoft", "webex", "whereby", "around.co", "tuple"]
    private func isOurs(_ c: EKCalendar) -> Bool { c.title == Profile.logCalendarName || c.calendarIdentifier == logCalendar?.calendarIdentifier }

    /// Meetings overlapping [from, to): timed events (not our own log) that have a video
    /// link or other attendees, and that the user hasn't declined. In-person meetings with
    /// attendees count; personal blocks on tracking calendars (no attendees) don't.
    private func meetings(from: Date, to: Date) -> [EKEvent] {
        guard granted else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil)).filter { e in
            guard !e.isAllDay, !isOurs(e.calendar) else { return false }
            if e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined { return false }
            return MeetingKind.counts(title: e.title ?? "", minutes: e.endDate.timeIntervalSince(e.startDate) / 60, hasVideo: hasVideo(e), hasAttendees: e.hasAttendees)
        }.sorted { $0.startDate < $1.startDate }
    }
    private func hasVideo(_ e: EKEvent) -> Bool {
        let hay = [e.title, e.location, e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: " ").lowercased()
        return Self.meetingMarkers.contains(where: { hay.contains($0) })
    }
    /// Only video meetings count as computer time (an in-person meeting isn't screen time).
    private func videoMeetings(from: Date, to: Date) -> [EKEvent] { meetings(from: from, to: to).filter(hasVideo) }

    /// The first meeting within `bufferMinutes` of now, if any.
    func meetingNearby(bufferMinutes: Double) -> String? {
        let now = Date()
        return meetings(from: now.addingTimeInterval(-bufferMinutes * 60), to: now.addingTimeInterval(bufferMinutes * 60)).first.map { $0.title ?? "a meeting" }
    }

    /// A meeting that's on now or starts within `minutes`: the lock steps aside for it.
    func meetingSoon(minutes: Double) -> EKEvent? {
        meetings(from: Date(), to: Date().addingTimeInterval(minutes * 60)).first
    }

    /// The next meeting that starts after now and before `before`, if any.
    func nextMeeting(startingBefore before: Date) -> EKEvent? {
        meetings(from: Date(), to: before).first { $0.startDate > Date() }
    }

    /// Video-meeting minutes so far today.
    func meetingMinutesToday() -> Double {
        videoMeetings(from: Day.today, to: Date()).reduce(0) { $0 + max(0, min($1.endDate, Date()).timeIntervalSince($1.startDate)) / 60 }
    }

    /// Video meetings on the calendar for the whole of today: (count, minutes).
    func meetingsScheduledToday() -> (count: Int, minutes: Double) {
        let m = videoMeetings(from: Day.today, to: Day.today.addingTimeInterval(86400))
        return (m.count, m.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) / 60 })
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
        let rests = Store.shared.eventDetails(kind: "break_done", since: from, until: to).map { $0.split(separator: "|").first.map(String.init) ?? "" }
        let answers = Store.shared.eventDetails(kind: "symptoms", since: from, until: to) + Store.shared.eventDetails(kind: "quick_check", since: from, until: to)
        let ev = EKEvent(eventStore: store)
        ev.calendar = cal
        ev.startDate = from; ev.endDate = to
        ev.title = "🧠 \(Int(workSecs / 60))m · " + parts.joined(separator: " · ")
        ev.notes = "\(worked)\n\nBreaks: \(rests.isEmpty ? "none" : rests.joined(separator: ", "))"
            + (answers.isEmpty ? "" : "\nHow you felt (1 worst … 10 best): \(answers.joined(separator: "; "))")
            + "\n\nLogged by Supervision from window titles, kept on this Mac."
        do { try store.save(ev, span: .thisEvent, commit: true) }
        catch { Store.shared.event("calendar", "Hour summary failed: \(error.localizedDescription)") }
    }

    /// Each set of answers becomes a 5-minute event at the moment it was saved.
    func writeQuickCheck(at t: Date, answers: [(String, Int)], note: String, afterBreak: Bool) {
        guard granted else { return }
        if logCalendar == nil { ensureLogCalendar() }
        guard let cal = logCalendar else { return }
        let parts = answers.map { "\($0.0) \($0.1)" } + (note.isEmpty ? [] : ["📝 \(note)"])
        let ev = EKEvent(eventStore: store)
        ev.calendar = cal; ev.startDate = t; ev.endDate = t.addingTimeInterval(300)
        ev.title = "🩺 " + parts.joined(separator: " · ")
        ev.notes = "\(afterBreak ? "After a break" : "Corner check"), \(Scale.label). Logged by Supervision."
        do { try store.save(ev, span: .thisEvent, commit: true) }
        catch { Store.shared.event("calendar", "Quick-check event failed: \(error.localizedDescription)") }
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
