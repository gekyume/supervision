import AppKit

/// What the camera sees, without showing video (user, Oct 27: "I don't want to see a video of myself
/// … some sort of live thing that's showing me what I can see and what I cannot see"). Drawn in
/// the brand's ink: two eyes that open and close with yours, and a dot figure of your body.

/// Two eyes that follow your own: `level` 0 (shut) … 1 (open as usual). Faint when no face is seen.
final class EyesView: NSView {
    var level = 1.0 { didSet { if abs(level - oldValue) > 0.02 { needsDisplay = true } } }
    var seen = false { didSet { if seen != oldValue { needsDisplay = true } } }
    override init(frame: NSRect) { super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 70) }

    override func draw(_ dirtyRect: NSRect) {
        let c = Brand.c, ink = seen ? c.ink : c.ink.withAlphaComponent(0.2)
        let w: CGFloat = 86, gap: CGFloat = 40, midY = bounds.midY
        let open = CGFloat(seen ? min(1, max(0.04, level)) : 0.6)
        for i in 0..<2 {
            let x0 = bounds.midX + (i == 0 ? -gap / 2 - w : gap / 2), x1 = x0 + w, cx = (x0 + x1) / 2
            let h: CGFloat = 30 * open
            let lid = NSBezierPath()
            lid.move(to: NSPoint(x: x0, y: midY))
            lid.curve(to: NSPoint(x: x1, y: midY), controlPoint1: NSPoint(x: x0 + w * 0.25, y: midY + h), controlPoint2: NSPoint(x: x1 - w * 0.25, y: midY + h))
            lid.curve(to: NSPoint(x: x0, y: midY), controlPoint1: NSPoint(x: x1 - w * 0.25, y: midY - h), controlPoint2: NSPoint(x: x0 + w * 0.25, y: midY - h))
            lid.lineWidth = 2.5; ink.setStroke(); lid.stroke()
            if open > 0.35 {
                NSGraphicsContext.saveGraphicsState(); lid.addClip()
                let r: CGFloat = 13
                ink.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - r, y: midY - r, width: 2 * r, height: 2 * r)).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}

/// A dot figure of what the body-pose camera sees, mirrored like a mirror, inside viewfinder
/// brackets, with a line of checks under it (what's seen in ink, what isn't faint).
final class PoseView: NSView {
    /// Normalized camera points (0–1, y up), keyed: nose neck lS rS lE rE lW rW lH rH lK rK lA rA.
    var joints: [String: CGPoint] = [:] { didSet { needsDisplay = true } }
    var needStand = true
    override init(frame: NSRect) { super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 420, height: 250) }

    private static let bones = [("nose", "neck"), ("neck", "lS"), ("neck", "rS"), ("lS", "lE"), ("lE", "lW"), ("rS", "rE"), ("rE", "rW"),
                                ("lS", "lH"), ("rS", "rH"), ("lH", "rH"), ("lH", "lK"), ("lK", "lA"), ("rH", "rK"), ("rK", "rA")]

    /// The checks under the figure: label and whether it's seen.
    var checks: [(String, Bool)] {
        let j = joints, head = j["nose"] ?? j["neck"]
        let up: (String) -> Bool = { k in guard let w = j[k], let h = head else { return false }; return w.y > h.y }
        var out = [("Head", head != nil), ("Shoulders", j["lS"] != nil && j["rS"] != nil)]
        if needStand { out.append(("Hips", j["lH"] != nil || j["rH"] != nil)) }
        out.append(("Hands up", up("lW") && up("rW")))
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = Brand.c
        let box = NSRect(x: bounds.midX - 110, y: 40, width: 220, height: bounds.height - 48)
        // Viewfinder corners = the camera's frame.
        let corner: CGFloat = 16, frame = NSBezierPath(); frame.lineWidth = 1.5
        for (x, y, dx, dy) in [(box.minX, box.minY, 1.0, 1.0), (box.maxX, box.minY, -1.0, 1.0), (box.minX, box.maxY, 1.0, -1.0), (box.maxX, box.maxY, -1.0, -1.0)] {
            frame.move(to: NSPoint(x: x + corner * dx, y: y)); frame.line(to: NSPoint(x: x, y: y)); frame.line(to: NSPoint(x: x, y: y + corner * dy))
        }
        c.faint.setStroke(); frame.stroke()
        let pt: (CGPoint) -> NSPoint = { p in NSPoint(x: box.minX + (1 - p.x) * box.width, y: box.minY + p.y * box.height) }   // mirrored
        if joints.isEmpty {
            let s = NSAttributedString(string: "no one in view yet", attributes: [.font: Brand.mono(11), .foregroundColor: c.faint])
            s.draw(at: NSPoint(x: box.midX - s.size().width / 2, y: box.midY))
        }
        let bone = NSBezierPath(); bone.lineWidth = 3; bone.lineCapStyle = .round
        for (a, b) in Self.bones { if let p = joints[a], let q = joints[b] { bone.move(to: pt(p)); bone.line(to: pt(q)) } }
        c.ink.withAlphaComponent(0.55).setStroke(); bone.stroke()
        c.ink.setFill()
        for (k, p) in joints {
            let r: CGFloat = k == "nose" ? 9 : 5, q = pt(p)
            NSBezierPath(ovalIn: NSRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)).fill()
        }
        // The checks.
        let line = NSMutableAttributedString()
        for (i, (label, ok)) in checks.enumerated() {
            if i > 0 { line.append(NSAttributedString(string: "   ", attributes: [.font: Brand.mono(12)])) }
            line.append(NSAttributedString(string: (ok ? "✓ " : "○ ") + label.uppercased(),
                                           attributes: [.font: Brand.mono(12, .medium), .foregroundColor: ok ? c.ink : c.faint]))
        }
        line.draw(at: NSPoint(x: bounds.midX - line.size().width / 2, y: 8))
    }
}
