import Foundation

/// The phone unlock (user, Oct 3: "too many times I've been shut out"). An iPhone Shortcut
/// publishes one short message to a private ntfy.sh topic; the Mac polls that topic and
/// applies it. Works from anywhere with internet; nothing leaves the Mac.
///
/// Messages: "<minutes>|<reason>" → pause 1–120 min (ends any lock now), "end…" → resume.
/// Anything else unlocks for 30 min (a tap on the phone must never silently fail). Every unlock is logged with its reason, like a pause from Claude.
/// The topic name is the secret; it lives in phone.json (never in the repo).
final class PhoneRelay: NSObject, URLSessionDataDelegate {
    static let shared = PhoneRelay()
    struct Settings: Codable { var topic = ""; var lastId = ""; var seen: [String]? = nil }
    static let file = Paths.dir.appendingPathComponent("phone.json")
    private var settings = Settings()
    private var timer: Timer?
    private var inFlight = false
    private var lastPoll = Date.distantPast
    /// While the workout screen is up, one open stream instead of polling (Oct 27: polling every 2 s
    /// got throttled by ntfy and phone reps were lost).
    var fast = false { didSet { if fast != oldValue { fast ? openStream() : closeStream() } } }
    private var stream: URLSessionDataTask?
    private var streamBuffer = Data()
    private lazy var streamSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
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
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self = self, self.stream == nil else { return }
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
                for line in text.split(separator: "\n") { self.handle(line: String(line)) }
            }
        }.resume()
    }

    /// One ntfy JSON line. Each message is applied once, ever (Oct 27: several sent in the same second
    /// came back on every poll, and one 🤞 tap was applied ~170 times).
    private func handle(line: String) {
        guard let d = line.data(using: .utf8),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              m["event"] as? String == "message", let id = m["id"] as? String else { return }
        var seen = settings.seen ?? []
        guard !seen.contains(id) else { return }
        seen.append(id); settings.seen = Array(seen.suffix(200)); settings.lastId = id
        saveJSON(settings, to: Self.file)
        if let t = m["time"] as? Double, PhoneMessage.isFresh(sentAt: t, now: Date().timeIntervalSince1970) {
            apply((m["message"] as? String) ?? "")
        }
    }

    private func openStream() {
        guard stream == nil, !settings.topic.isEmpty, let url = URL(string: "https://ntfy.sh/\(settings.topic)/json") else { return }
        poll()   // anything sent just before
        streamBuffer = Data()
        let t = streamSession.dataTask(with: URLRequest(url: url, timeoutInterval: 3600)); stream = t; t.resume()
    }
    private func closeStream() { stream?.cancel(); stream = nil }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask == stream else { return }
        streamBuffer.append(data)
        while let nl = streamBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: streamBuffer[streamBuffer.startIndex..<nl], as: UTF8.self)
            streamBuffer.removeSubrange(streamBuffer.startIndex...nl)
            handle(line: line)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task == stream else { return }
        stream = nil
        if fast { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.fast == true { self?.openStream() } } }
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
