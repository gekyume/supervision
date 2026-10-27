import AppKit

/// `Supervision --previews <dir>` renders each screen (light and dark) to PNGs and exits,
/// so the design can be checked without a lock appearing. Never part of normal running.
enum Previews {
    static func run(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for dark in [false, true] {
            Brand.forceDark = dark
            let mode = dark ? "dark" : "light"
            let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
            let a = Activity.catalog["rest"]!
            let plan = BreakPlan(activity: a, headline: "Rest your head for a moment 💛", reason: "35 min of focused writing. Whoop recovery 50 (yellow), 212 of 480 computer minutes used.",
                                 acknowledgement: nil, unlock: nil, alternatives: Array(Activity.catalog.values.filter { $0.key != "rest" }.prefix(3)), hrCeiling: 74)
            LockScreen.shared.rewardsOn = true
            save(LockScreen.shared.previewView(frame: frame, title: "", reason: plan.reason, plan: plan, extra: "Drink some water on the way back 💧", countdownText: "6:42"), frame, "\(dir)/lock-\(mode).png")
            save(EyeBreak.shared.previewView(frame: frame), frame, "\(dir)/eye-\(mode).png")
            save(WorkoutSession.shared.previewView(frame: frame), frame, "\(dir)/workout-\(mode).png")
            let fig = PoseView(frame: NSRect(x: 0, y: 0, width: 420, height: 250)); fig.wantsLayer = true; fig.layer?.backgroundColor = Brand.c.paper.cgColor
            fig.joints = ["nose": CGPoint(x: 0.5, y: 0.72), "neck": CGPoint(x: 0.5, y: 0.62), "lS": CGPoint(x: 0.6, y: 0.6), "rS": CGPoint(x: 0.4, y: 0.6),
                          "lE": CGPoint(x: 0.64, y: 0.78), "rE": CGPoint(x: 0.36, y: 0.78), "lW": CGPoint(x: 0.6, y: 0.95), "rW": CGPoint(x: 0.4, y: 0.95),
                          "lH": CGPoint(x: 0.56, y: 0.3), "rH": CGPoint(x: 0.44, y: 0.3)]
            save(fig, fig.frame, "\(dir)/pose-\(mode).png")
            let pickerWin = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false); pickerWin.appearance = Brand.appearance
            LockScreen.shared.previewPicker(in: pickerWin, plan: plan)
            if let v = pickerWin.contentView { save(v, frame, "\(dir)/picker-\(mode).png") }
            Card.shared.previewShow(title: "Yellow today: 30-min blocks, 8 h cap 💛", body: "Whoop 50, slept 7.1 h. First block 30 min, breaks 7 min, a lie-down every 2 h.\nWhat are the two things that deserve today's minutes?", buttons: ["Got it", "Get Whoop reading"], tag: "Mon · Oct 5", width: 460)
            if let p = Card.shared.previewWindow, let v = p.contentView { save(v, v.bounds, "\(dir)/card-\(mode).png") }
            Card.shared.hide()
            HotCorner.shared.openQuickCheck()
            if let p = HotCorner.shared.previewPanel, let v = p.contentView { save(v, v.bounds, "\(dir)/check-\(mode).png") }
            HotCorner.shared.previewClose()
            StatusPill.shared.start(); StatusPill.shared.previewRefresh()
            if let p = StatusPill.shared.previewPanel, let v = p.contentView { save(v, v.bounds, "\(dir)/pill-\(mode).png"); p.orderOut(nil) }
        }
    }

    private static func save(_ v: NSView, _ frame: NSRect, _ path: String) {
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false); w.appearance = Brand.appearance
        if v.window == nil { w.contentView = v }
        v.frame = frame; v.layoutSubtreeIfNeeded(); v.display()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
