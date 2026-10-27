import Foundation

/// The phone unlock (user, Oct 3: "too many times I've been shut out"). An iPhone Shortcut
/// publishes one short message to a private ntfy.sh topic; the Mac polls that topic and
/// applies it. Works from anywhere with internet; nothing leaves the Mac.
///
/// Messages: "<minutes>|<reason>" → pause 1–120 min (ends any lock now), "end…" → resume.
/// Anything else unlocks for 30 min (a tap on the phone must never silently fail). Every unlock is logged with its reason, like a pause from Claude.
/// The topic name is the secret; it lives in phone.json (never in the repo).
final class PhoneRelay {
    static let shared = PhoneRelay()
    struct Settings: Codable { var topic = ""; var lastId = "" }
    static let file = Paths.dir.appendingPathComponent("phone.json")
    private var settings = Settings()
    private var timer: Timer?
    private var inFlight = false
    private var lastPoll = Date.distantPast
    /// Poll every 2 s instead of 10 while the workout screen is up, so phone reps show quickly.
    var fast = false
    /// The phone workout page link (Oct 27): opening it once teaches the phone the Mac's address.
    var workoutLink: String { "https://raw.githack.com/gekyume/supervision/main/docs/workout.html?t=\(settings.topic)" }

    /// What the Mac's workout screen shows, for the phone page to follow. A separate "-state" topic,
    /// so the Mac's own poller never reads it as an unlock.
    func publishState(_ json: String) {
        guard !settings.topic.isEmpty, let url = URL(string: "https://ntfy.sh/\(settings.topic)-state") else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.httpBody = Data(json.utf8); req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req).resume()
    }

    func start() {
        settings = lenientLoad(Self.file, defaults: Settings()) ?? Settings()
        if settings.topic.isEmpty {
            settings.topic = "sv-" + (0..<4).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max)) }.joined()
            saveJSON(settings, to: Self.file)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, self.fast || -self.lastPoll.timeIntervalSinceNow >= 10 else { return }
            self.poll()
        }
    }

    private func poll() {
        guard !inFlight else { return }
        lastPoll = Date()
        let since = settings.lastId.isEmpty ? "5m" : settings.lastId
        guard let url = URL(string: "https://ntfy.sh/\(settings.topic)/json?poll=1&since=\(since)") else { return }
        inFlight = true
        var req = URLRequest(url: url); req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                self?.inFlight = false
                guard let self = self, let data = data, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(separator: "\n") {
                    guard let d = line.data(using: .utf8),
                          let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          m["event"] as? String == "message", let id = m["id"] as? String else { continue }
                    self.settings.lastId = id
                    saveJSON(self.settings, to: Self.file)
                    if let t = m["time"] as? Double, PhoneMessage.isFresh(sentAt: t, now: Date().timeIntervalSince1970) {
                        self.apply((m["message"] as? String) ?? "")
                    }
                }
            }
        }.resume()
    }

    private func apply(_ message: String) {
        var c = Control.load()
        switch PhoneMessage.parse(message) {
        case .rep(let step, let reps):
            WorkoutSession.shared.phoneRep(step: step, reps: reps)
        case .workout(let done, let summary):
            Engine.shared.phoneWorkout(done: done, summary: summary)
        case .end:
            c.pauseUntil = nil; c.reason = ""
            saveJSON(c, to: Control.file)
            Store.shared.event("override", "iPhone: pause ended, back to normal")
        case .pause(let mins, let why):
            // Friction (user, Oct 3): if a lock is showing, it opens only after a reason is typed on the Mac.
            if Engine.shared.askPhoneUnlockReason(minutes: mins) { return }
            let reason = "iPhone unlock (no lock showing): " + (why ?? "phone link")
            c.pauseUntil = Date().addingTimeInterval(Double(mins) * 60); c.reason = reason
            saveJSON(c, to: Control.file)
            Store.shared.event("override", "\(reason) (\(mins) min)")
        }
    }
}
