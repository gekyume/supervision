import Foundation

// MARK: - Contexts: where the user is, and what's available there

/// A place the user works from. Activities listed here are the only ones the
/// planner may suggest while this context is active. Switched automatically by
/// Wi-Fi network name, or by `supervisionctl context <name>`.
struct WorkContext: Codable {
    var name: String
    var ssids: [String] = []
    var activities: [String] = []   // keys into Activity.catalog
    var workout: String? = nil      // "lying" | "standing" | nil (none): the daily workout this place allows
    var label: String? = nil        // how the "Where are you?" card names it ("Office", "Parents")
}

struct Contexts: Codable {
    var current: String = "home"
    var manualUntil: Date? = nil    // a manual switch wins over Wi-Fi until this time
    var askedSSIDs: [String] = []   // networks already asked about ("Somewhere else" ones stay unmatched)
    var contexts: [WorkContext] = [
        // Defaults for a new install. Add Wi-Fi names with `supervisionctl context add-wifi home "<ssid>"`.
        WorkContext(name: "home", activities: ["rest", "music", "stretch", "footpt", "walk", "pilates", "journal", "plan", "rap", "poetry"]),
        WorkContext(name: "office", activities: ["rest", "music", "stretch", "walk", "journal", "plan"]),
    ]
    static let file = Config.dir.appendingPathComponent("contexts.json")
    static func load() -> Contexts {
        if let c = lenientLoad(file, defaults: Contexts()) { return c }
        let c = Contexts(); c.save(); return c
    }
    func save() { saveJSON(self, to: Contexts.file) }
    var active: WorkContext { contexts.first { $0.name == current } ?? contexts[0] }

    /// Current Wi-Fi name via `ipconfig` (CoreWLAN needs Location permission on modern macOS).
    static func currentSSID() -> String? {
        let p = Process(); p.launchPath = "/usr/sbin/ipconfig"; p.arguments = ["getsummary", "en0"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in s.split(separator: "\n") where line.trimmingCharacters(in: .whitespaces).hasPrefix("SSID") {
            return line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

// MARK: - Baseline: the morning numbers (written by a scheduled Claude task from Whoop)

struct Baseline: Codable {
    var date: String = ""              // yyyy-MM-dd the numbers belong to
    var recovery: Int? = nil           // Whoop recovery 0–100
    var restingHR: Int? = nil
    var hrv: Double? = nil
    var sleepHours: Double? = nil
    var note: String = ""
    static let file = Config.dir.appendingPathComponent("baseline.json")
    static func load() -> Baseline {
        lenientLoad(file, defaults: Baseline()) ?? Baseline()
    }
    var isToday: Bool { date == Day.string(Date()) }
    /// Today's tier; a stale or missing reading is "unknown" (treated as yellow).
    var tier: String { Tier.from(recovery: isToday ? recovery : nil) }
    var hrCeiling: Int? { restingHR.map { $0 + 15 } }
}

// MARK: - Activities

struct Activity {
    let key: String, title: String, emoji: String
    let minutes: Int          // total break length when chosen
    let load: String          // "none" (true rest), "physical", "cognitive"
    let instructions: String
    let minTier: String       // lowest recovery tier that allows it: "red" < "yellow" < "green"

    static let catalog: [String: Activity] = [
        "rest": Activity(key: "rest", title: "Up, look far, then eyes closed", emoji: "🌙", minutes: 10, load: "none",
                         instructions: "Stand up and stretch your legs. Look out a window at something far away for 20 seconds (20-20-20). Then lie back, eyes closed, breathing with the circle: 5.5 seconds in, 5.5 out. No screens, no podcasts. Good moment to plan what's next.", minTier: "red"),
        "music": Activity(key: "music", title: "Music, eyes closed", emoji: "🎧", minutes: 10, load: "none",
                          instructions: "Headphones on, eyes closed, lying down. Something you don't have to think about.", minTier: "red"),
        "stretch": Activity(key: "stretch", title: "Gentle stretch, then rest", emoji: "🧘", minutes: 10, load: "physical",
                            instructions: "1–2 minutes of slow stretching, then lie down for the rest. If your breathing speeds up, stop.", minTier: "yellow"),
        "footpt": Activity(key: "footpt", title: "Foot PT", emoji: "🦶", minutes: 12, load: "physical",
                           instructions: "Your PT routine, seated or lying, slow. Then 2 minutes flat with eyes closed.", minTier: "yellow"),
        "walk": Activity(key: "walk", title: "Slow walk outside", emoji: "🚶", minutes: 12, load: "physical",
                         instructions: "Stroll, don't march. If talking would be hard, slow down. Lie down 2 minutes after.", minTier: "green"),
        "pilates": Activity(key: "pilates", title: "Pilates, the short one", emoji: "🤸", minutes: 20, load: "physical",
                            instructions: "The 10-minute version, then flat on your back for the rest. Keep heart rate under the ceiling.", minTier: "green"),
        "journal": Activity(key: "journal", title: "Journal, on paper", emoji: "📓", minutes: 10, load: "cognitive",
                            instructions: "Pen and paper, 5 minutes, then eyes closed for the rest. No screen.", minTier: "yellow"),
        "plan": Activity(key: "plan", title: "Plan the next thing, on paper", emoji: "🗒️", minutes: 10, load: "cognitive",
                         instructions: "Three lines max: what's next, what can wait, what's done. Then eyes closed.", minTier: "yellow"),
        "rap": Activity(key: "rap", title: "Freestyle", emoji: "🎤", minutes: 10, load: "cognitive",
                        instructions: "A few minutes of freestyle, then lie down and let it settle.", minTier: "green"),
        "poetry": Activity(key: "poetry", title: "Write a poem, on paper", emoji: "✒️", minutes: 10, load: "cognitive",
                           instructions: "Pen and paper, 5 minutes, then eyes closed.", minTier: "green"),
    ]
}

// MARK: - Voice: the same message should never read the same way twice in a row

enum Voice {
    static let restHeadlines = [
        "Time to rest 🌙", "Eyes closed for a bit 🌙", "Ten minutes of nothing 🌙", "Pause here 🌙",
        "Let it settle 🌙", "Lie back, you've earned it 🌙", "Quiet time 🌙", "Rest before it's needed 🌙",
    ]
    static let activeHeadlines = [
        "A different kind of break", "Change of state", "Something other than a screen", "Move a little, then rest",
        "Break, with options", "Not just breathing this time", "Your turn to pick", "A little variety",
    ]
    static let restOnlyIntros = [
        "I know you'd rather be %@. Not this time, and here's the exact reason: %@.",
        "You'd probably pick %@ if I let you. I'm not, because %@.",
        "%@ sounds better than lying still, I get it. Today the reason is specific: %@.",
        "Plain rest again, and I owe you a reason: %@. Otherwise %@ would be on the table.",
    ]
    static func pick(_ list: [String], _ n: Int) -> String { list[n % list.count] }
}

// MARK: - Planner

struct BreakPlan {
    var activity: Activity
    let headline: String
    let reason: String              // the numbers behind the choice
    let acknowledgement: String?    // "I know you'd rather…" — only when restricting
    let unlock: String?             // what would bring the other options back
    let alternatives: [Activity]    // up to 3 things that are also okay right now
    let hrCeiling: Int?
}

/// Picks the break. Rule-based on purpose: every choice comes with a reason
/// that reads like a sentence, and the same inputs always give the same answer.
enum Planner {
    struct Inputs {
        var baseline: Baseline
        var context: WorkContext
        var loadPercent: Double          // share of today's computer-time cap used
        var usedMinutes: Double          // computer minutes so far today
        var capMinutes: Double
        var meetingMinutes: Double
        var lastOverall: Int?            // latest "overall" answer today, 1 worst … 10 best
        var hour: Int
        var breaksToday: [String]        // activity keys, in order, completed or not
        var activeBreaksToday: Int       // physical+cognitive breaks done today
        var lastBreakLoad: String        // load of the most recent break, "none" if none
    }

    static func plan(_ i: Inputs) -> BreakPlan {
        let tier = i.baseline.tier
        let n = i.breaksToday.count
        var facts: [String] = []
        if let r = i.baseline.recovery, i.baseline.isToday { facts.append("Whoop recovery \(r) (\(tier))") } else { facts.append("no Whoop reading today, so I treat it as yellow") }
        facts.append("\(Int(i.usedMinutes)) of \(Int(i.capMinutes)) computer minutes used")
        if i.meetingMinutes > 0 { facts.append("\(Int(i.meetingMinutes)) min of meetings") }
        if let o = i.lastOverall { facts.append("overall \(o)/10 last time you told me") }

        // The things the user actually wants, in this context, named back to them.
        let wishes = i.context.activities.compactMap { Activity.catalog[$0] }.filter { $0.load != "none" }
        let wishText = wishes.prefix(3).map { $0.title.lowercased().split(separator: ",").first.map(String.init) ?? $0.title.lowercased() }.joined(separator: ", ")

        // Hard gates → true rest, with the specific gate and what would unlock the rest.
        var gate: (why: String, unlock: String)? = nil
        if tier == "red" { gate = ("your Whoop recovery is \(i.baseline.recovery ?? 0), a red day, and movement on red days is what turns a bad day into a bad week", "a yellow morning brings stretching, foot PT and journaling back; green brings walks and Pilates") }
        else if let o = i.lastOverall, o <= 4 { gate = ("you told me overall is \(o)/10, and I believe you over the schedule", "a 5 or better next time you answer reopens the gentle options") }
        else if i.meetingMinutes >= 60 { gate = ("you've had \(Int(i.meetingMinutes)) minutes of meetings today, and after that much talking and looking, eyes and ears need the break more than legs do", "a lighter meeting day, or tomorrow morning") }
        else if i.loadPercent >= 70 { gate = ("you're at \(Int(i.usedMinutes)) of \(Int(i.capMinutes)) computer minutes today, and anything active now is paid for tomorrow", "earlier in the day, with less of the day spent, is when the active breaks live") }
        else if i.lastBreakLoad != "none" { gate = ("your last break was active, and the rule is movement, then rest, then movement", "the break after this one") }
        else if i.activeBreaksToday >= 3 { gate = ("that's three active breaks already today, which is the daily cap while we learn your limits", "tomorrow") }
        else if i.hour >= 17 { gate = ("it's after 5, and evenings are for winding down, not spending", "tomorrow morning") }

        let rest = Activity.catalog["rest"]!
        let music = i.context.activities.contains("music") ? Activity.catalog["music"] : nil
        if let g = gate {
            let ack = String(format: Voice.pick(Voice.restOnlyIntros, n), wishText, g.why)
            return BreakPlan(activity: rest, headline: Voice.pick(Voice.restHeadlines, n), reason: facts.joined(separator: ", ") + ".",
                             acknowledgement: ack, unlock: "What brings the other options back: \(g.unlock).",
                             alternatives: [music].compactMap { $0 }, hrCeiling: i.baseline.hrCeiling)
        }

        // Candidates: allowed in this context, allowed at this tier, not the same as last time.
        let last = i.breaksToday.last
        var candidates = i.context.activities.compactMap { Activity.catalog[$0] }
            .filter { Tier.rank[$0.minTier]! <= Tier.rank[tier]! && $0.load != "none" && $0.key != last }
        var trimmed: [String] = []
        if i.loadPercent >= 40 || tier != "green" {
            if candidates.contains(where: { $0.load == "cognitive" }) { trimmed.append(tier != "green" ? "the writing and planning ones wait for a green day" : "the writing and planning ones wait for a lighter day") }
            candidates.removeAll { $0.load == "cognitive" }
        }
        if i.breaksToday.contains("pilates") || i.hour >= 15 {
            if candidates.contains(where: { $0.key == "pilates" }) { trimmed.append(i.hour >= 15 ? "Pilates is a before-3pm thing" : "Pilates once a day") }
            candidates.removeAll { $0.key == "pilates" }
        }
        let order = ["stretch", "footpt", "walk", "journal", "plan", "pilates", "poetry", "rap"]
        candidates.sort { a, b in
            let da = i.breaksToday.contains(a.key), db = i.breaksToday.contains(b.key)
            if da != db { return !da }
            return order.firstIndex(of: a.key)! < order.firstIndex(of: b.key)!
        }
        guard let pick = candidates.first else {
            return BreakPlan(activity: rest, headline: Voice.pick(Voice.restHeadlines, n), reason: facts.joined(separator: ", ") + ".",
                             acknowledgement: "Nothing active fits this exact moment, so it's a plain rest.", unlock: nil,
                             alternatives: [music].compactMap { $0 }, hrCeiling: i.baseline.hrCeiling)
        }
        var reason = facts.joined(separator: ", ") + ". "
        reason += pick.load == "physical" ? "A gentle change of state is fine today" : "A light, different kind of thinking is fine today"
        reason += trimmed.isEmpty ? "." : "; " + trimmed.joined(separator: "; ") + "."
        var alts = Array(candidates.dropFirst().prefix(2))
        alts.append(rest)
        return BreakPlan(activity: pick, headline: Voice.pick(Voice.activeHeadlines, n), reason: reason, acknowledgement: nil, unlock: nil,
                         alternatives: alts, hrCeiling: i.baseline.hrCeiling)
    }
}
