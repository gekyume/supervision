import AppKit

/// A small pill in the top-right corner (user, Oct 5: "sometimes I feel like you are not
/// running"). Hidden until the pointer comes near the top-right corner ("always on would give me
/// anxiety"), then shows where you are, e.g. "🧠 Break in 12 min". Stays while hovered, fades
/// 1.5 s after the pointer leaves. Click it for the quick check (resting in the very corner
/// still opens it too). On every Space and over full-screen apps.
final class StatusPill {
    static let shared = StatusPill()
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var lastNear = Date.distantPast
    private let zone: CGFloat = 90              // how close to the corner (points) before it shows
    private final class ClickView: NSView {
        var onClick: (() -> Void)?
        override func mouseDown(with event: NSEvent) { onClick?() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }

    func start() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 26), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        let v = ClickView(frame: p.contentRect(forFrameRect: p.frame))
        v.wantsLayer = true
        v.layer?.cornerRadius = 13; v.layer?.borderWidth = 1
        v.onClick = { HotCorner.shared.openQuickCheck() }
        label.font = Brand.mono(11.5, .medium)
        label.alignment = .center; label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: v.centerXAnchor), label.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        p.contentView = v
        panel = p
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
    }

    var previewPanel: NSPanel? { panel }
    func previewRefresh() { refresh() }

    private func poll() {
        guard let p = panel, let screen = NSScreen.main else { return }
        let m = NSEvent.mouseLocation, f = screen.frame
        let near = (m.x >= f.maxX - zone && m.y >= f.maxY - zone) || (p.isVisible && p.frame.insetBy(dx: -10, dy: -10).contains(m))
        if near { lastNear = Date() }
        let show = -lastNear.timeIntervalSinceNow < 1.5 && !LockScreen.shared.isShowing && !HotCorner.shared.isOpen
        if show { refresh() } else if p.isVisible { p.orderOut(nil) }
    }

    private func refresh() {
        guard let p = panel, let screen = NSScreen.main else { return }
        // Brand look: paper capsule, hairline, a small ink dot, mono type (inverts at night).
        let c = Brand.c
        p.contentView?.layer?.backgroundColor = c.paper.cgColor
        p.contentView?.layer?.borderColor = c.hairline.cgColor
        label.textColor = c.ink
        let words = Engine.shared.pillText.split(separator: " ", maxSplits: 1)
        label.stringValue = "●  " + (words.count == 2 && !(words[0].first?.isLetter ?? true) ? String(words[1]) : Engine.shared.pillText)
        p.contentView?.toolTip = Engine.shared.pillDetail + "\nClick for a quick check."
        let w = ceil(label.intrinsicContentSize.width) + 30, h: CGFloat = 26
        let vf = screen.visibleFrame
        p.setFrame(NSRect(x: vf.maxX - w - 10, y: vf.maxY - h - 8, width: w, height: h), display: true)
        p.orderFrontRegardless()
    }
}
