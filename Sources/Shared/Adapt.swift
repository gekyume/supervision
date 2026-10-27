import Foundation

// The Utah ADaPT exercise track (Autonomic Disorder adaptive Physical Therapy), kept
// separate from work pacing. Stages by body position; a heart-rate zone; 20 minutes;
// at least 3 days a week, never more than 2 days off. Progression is +5 bpm when a zone
// is tolerated, and a new stage after 3 progressions. Supervision adds one ME/CFS
// safeguard the protocol doesn't have: a step up needs the two mornings after the
// week's sessions to look fine too. Changes are proposed, never automatic.
// Source: Utah ADaPT Protocol Provider Manual (10.10.24), docs/private/adapt/.

struct AdaptPlan: Codable {
    var stage = 2                      // 0 = Preconditioning, 1 supine, 2 reclined, 3 seated, 4 walking, 5 intervals
    var zoneLow = 90, zoneHigh = 100   // target heart rate during the session (bpm)
    var hardCap = 100                  // the user's own ceiling; progression never proposes above it without asking
    var minutes = 20
    var daysPerWeek = 3
    var maxDaysOff = 2
    var modes = ["Pilates reformer", "recumbent bike"]
    var progressions = 0               // +5 bpm steps taken in this stage
    var started = ""                   // yyyy-MM-dd
    var history: [String] = []

    static let file = Paths.dir.appendingPathComponent("adapt.json")
    static let stageNames = ["Preconditioning", "Stage 1 · lying down", "Stage 2 · reclined", "Stage 3 · seated", "Stage 4 · walking", "Stage 5 · intervals"]
    var stageName: String { Self.stageNames[max(0, min(stage, Self.stageNames.count - 1))] }
}

/// Today's plan as written by Muse (the user's morning agent) in the Airtable ADaPT Log.
/// Muse owns the plan; the morning task copies today's row here so the Mac can show it.
struct MusePlan: Codable {
    var date = "", status = "", workout = "", why = ""
    static let file = Paths.dir.appendingPathComponent("adapt-today.json")
}

/// One logged session (from Whoop's workout record, or told to Claude).
struct AdaptSession {
    let day: String, minutes: Int, avgHR: Int?, maxHR: Int?, mode: String
}

/// Today's ADaPT plan in words — the same text on the morning card, in Airtable and in
/// the morning text. `days` = session days in the last 7; `daysOff` = days since the last.
struct AdaptToday {
    let status: String      // "Planned" | "Rest day" | "Done"
    let workout: String     // ready-to-send sentence
    let why: String
}

extension AdaptPlan {
    func today(tier: String, dipped: Bool, hour: Int, days: Int, daysOff: Int?, doneToday: Bool) -> AdaptToday {
        let session = "\(stageName): \(minutes) min on the \(modes.joined(separator: " or ")) at \(zoneLow)–\(zoneHigh) bpm, before 5 pm, then lie down for 10."
        let week = "\(days) of \(daysPerWeek) this week"
        if doneToday { return AdaptToday(status: "Done", workout: "Done for today ✅ Rest up.", why: week) }
        if tier == "red" {
            return AdaptToday(status: "Rest day", workout: "Rest day: 10 min of breathing (in 4, out 6), gentle stretching lying down. No cardio today.", why: "red recovery morning; \(week)")
        }
        if dipped {
            return AdaptToday(status: "Rest day", workout: "Rest day: breathing and gentle movement only.", why: "your numbers dipped today; \(week)")
        }
        if hour >= 17 { return AdaptToday(status: "Rest day", workout: "Too late for a session today; tomorrow morning instead.", why: "after 5 pm; \(week)") }
        if let off = daysOff, off >= maxDaysOff {
            return AdaptToday(status: "Planned", workout: session, why: "\(off) days since the last one (keep it to ≤ \(maxDaysOff)); \(week)")
        }
        if days >= daysPerWeek {
            return AdaptToday(status: "Rest day", workout: "Optional today: the week's \(daysPerWeek) are done. If you go: " + session, why: week + ", target met")
        }
        return AdaptToday(status: "Planned", workout: session, why: "\(tier == "unknown" ? "no Whoop yet (yellow)" : tier) morning; \(week)")
    }
}
