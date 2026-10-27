import AppKit

/// The Supervision look (Oct 5, from the brand page): off-white paper with a faint dot grid,
/// a black geometric wordmark with viewfinder brackets, small mono labels ("S—01"),
/// monochrome, hairlines, capsule buttons. After 8 pm and before 7 am everything inverts
/// (ink paper, light type) so a rest screen never floods tired eyes with white.
enum Brand {
    struct Palette {
        let paper, ink, muted, faint, hairline, dot: NSColor
    }
    static var forceDark: Bool?   // previews only
    static var dark: Bool { if let f = forceDark { return f }; let h = Calendar.current.component(.hour, from: Date()); return h >= 20 || h < 7 }
    static var c: Palette {
        dark ? Palette(paper: NSColor(srgbRed: 0.04, green: 0.04, blue: 0.045, alpha: 1), ink: NSColor(white: 0.95, alpha: 1),
                       muted: NSColor(white: 0.62, alpha: 1), faint: NSColor(white: 0.40, alpha: 1),
                       hairline: NSColor(white: 1, alpha: 0.12), dot: NSColor(white: 1, alpha: 0.10))
             : Palette(paper: NSColor(srgbRed: 0.98, green: 0.98, blue: 0.976, alpha: 1), ink: NSColor(srgbRed: 0.04, green: 0.04, blue: 0.04, alpha: 1),
                       muted: NSColor(white: 0.42, alpha: 1), faint: NSColor(white: 0.62, alpha: 1),
                       hairline: NSColor(white: 0, alpha: 0.09), dot: NSColor(white: 0, alpha: 0.09))
    }
    static var appearance: NSAppearance? { NSAppearance(named: dark ? .darkAqua : .aqua) }

    // MARK: Type (Geist + Geist Mono, bundled in Resources/Fonts under the SIL OFL; system fonts as fallback)
    private static func geist(_ family: String, _ weight: NSFont.Weight) -> String {
        let w: String
        switch weight {
        case .bold, .heavy, .black: w = family == "GeistMono" ? "SemiBold" : "Bold"
        case .semibold: w = "SemiBold"
        case .medium: w = "Medium"
        case .light, .thin, .ultraLight: w = family == "GeistMono" ? "Regular" : "Light"
        default: w = "Regular"
        }
        return "\(family)-\(w)"
    }
    static func display(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        NSFont(name: geist("Geist", weight), size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont(name: geist("GeistMono", weight), size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }
    /// Big countdown digits: Geist Light with tabular figures, so the numbers don't jiggle.
    static func digits(_ size: CGFloat) -> NSFont {
        let base = display(size, .light)
        let d = base.fontDescriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                                                         NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: d, size: size) ?? .monospacedDigitSystemFont(ofSize: size, weight: .light)
    }

    static func text(_ s: String, _ font: NSFont, _ color: NSColor, wrap: CGFloat? = nil, align: NSTextAlignment = .left, tracking: CGFloat = 0) -> NSTextField {
        let t = wrap != nil ? NSTextField(wrappingLabelWithString: s) : NSTextField(labelWithString: s)
        t.attributedStringValue = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: tracking,
                                                                             .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = align; p.lineSpacing = 2; return p }()])
        if let w = wrap { t.preferredMaxLayoutWidth = w; t.widthAnchor.constraint(lessThanOrEqualToConstant: w).isActive = true }
        return t
    }
    /// The little uppercase mono tag, like "S—01" on the site.
    static func tag(_ s: String) -> NSTextField { text(s.uppercased(), mono(10.5, .medium), c.faint, tracking: 1.2) }

    // MARK: Wordmark
    private static let wordmarkImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "wordmark", withExtension: "png"), let i = NSImage(contentsOf: url) else { return nil }
        i.isTemplate = true; return i
    }()
    static func wordmark(height: CGFloat) -> NSView {
        guard let img = wordmarkImage else { return text("supervision", display(height, .bold), c.ink) }
        let v = NSImageView(image: img); v.imageScaling = .scaleProportionallyUpOrDown; v.contentTintColor = c.ink
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        v.widthAnchor.constraint(equalToConstant: height * img.size.width / img.size.height).isActive = true
        return v
    }

    // MARK: Fields
    /// A text field in the brand: paper fill, hairline outline, rounded, no stock bezel.
    static func field(_ placeholder: String, width: CGFloat, size: CGFloat = 14, noPaste: Bool = false) -> NSTextField {
        let f = PaddedField(); f.noPaste = noPaste; f.isBordered = false; f.drawsBackground = true; f.backgroundColor = c.paper
        f.focusRingType = .none; f.font = display(size, .regular); f.textColor = c.ink
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: display(size, .regular), .foregroundColor: c.faint])
        f.wantsLayer = true; f.layer?.cornerRadius = 8; f.layer?.borderWidth = 1; f.layer?.borderColor = c.ink.withAlphaComponent(0.18).cgColor
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        f.heightAnchor.constraint(equalToConstant: size + 18).isActive = true
        return f
    }

    // MARK: Buttons
    /// Capsule button: `primary` is solid ink, otherwise a hairline outline.
    static func button(_ title: String, primary: Bool = false, size: CGFloat = 14, target: AnyObject?, action: Selector?) -> NSButton {
        let b = CapsuleButton(title: title, target: target, action: action)
        b.primary = primary; b.fontSize = size; b.restyle()
        return b
    }
}

/// Text field with inner padding, vertically centered.
final class PaddedField: NSTextField {
    override class var cellClass: AnyClass? { get { PaddedCell.self } set {} }
    /// Statements must be typed, not pasted (user, Oct 25).
    var noPaste = false
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if noPaste, e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "v" { NSSound.beep(); return true }
        return super.performKeyEquivalent(with: e)
    }
}
final class PaddedCell: NSTextFieldCell {
    private func inset(_ r: NSRect) -> NSRect {
        let h = cellSize(forBounds: r).height
        return NSRect(x: r.minX + 10, y: r.minY + max(0, (r.height - h) / 2), width: r.width - 20, height: h)
    }
    override func drawingRect(forBounds r: NSRect) -> NSRect { inset(super.drawingRect(forBounds: r)) }
    override func edit(withFrame r: NSRect, in v: NSView, editor e: NSText, delegate d: Any?, event: NSEvent?) { super.edit(withFrame: inset(r), in: v, editor: e, delegate: d, event: event) }
    override func select(withFrame r: NSRect, in v: NSView, editor e: NSText, delegate d: Any?, start s: Int, length l: Int) { super.select(withFrame: inset(r), in: v, editor: e, delegate: d, start: s, length: l) }
}

final class CapsuleButton: NSButton {
    var primary = false, fontSize: CGFloat = 14
    func restyle() {
        isBordered = false; wantsLayer = true; focusRingType = .none
        let c = Brand.c
        layer?.backgroundColor = (primary ? c.ink : .clear).cgColor
        layer?.borderColor = (primary ? c.ink : c.ink.withAlphaComponent(0.22)).cgColor
        layer?.borderWidth = 1
        attributedTitle = NSAttributedString(string: title, attributes: [.font: Brand.display(fontSize, .medium), .foregroundColor: primary ? c.paper : c.ink])
        invalidateIntrinsicContentSize()
    }
    override var intrinsicContentSize: NSSize {
        let s = attributedTitle.size(); return NSSize(width: ceil(s.width) + fontSize * 2.2, height: ceil(s.height) + fontSize * 1.1)
    }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Paper with a faint dot grid, and optionally the site's radial dot cluster. On full-screen
/// surfaces the cluster sits right on the pointer (user, Oct 6: "it should be on the mouse"):
/// the center dot and hairline circle are pinned to it, the dot rings follow on springs (inner
/// tight, outer a touch looser) and fan out a little with speed, then settle and keep turning.
final class DotGridView: NSView {
    var spacing: CGFloat = 22
    var cluster = false { didSet { if cluster { startFollowing() } } }
    /// Rest breaks (user, Oct 25): the cluster breathes at a coherent pace, 5.5 s out and 5.5 s in.
    var breathing = false
    var followsPointer = false
    private let born = Date()
    override var isFlipped: Bool { true }
    private static let radii: [CGFloat] = [70, 100, 130, 160, 190]
    private static let stiffness: [CGFloat] = [0.62, 0.5, 0.4, 0.32, 0.26]   // per frame; 1 = locked to the pointer
    private var cursor: NSPoint?
    private var rings: [NSPoint] = []
    private var spread: CGFloat = 0           // eased 0…0.3: rings open up while the pointer moves
    private var spin = 0.0
    private var anim: Timer?
    private var gridCache: NSImage?
    private var lastDirty = NSRect.zero

    private func startFollowing() {
        anim?.invalidate()
        let t = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)       // keeps animating during drags and menus too
        anim = t
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if window == nil { anim?.invalidate(); anim = nil }
    }

    /// Where the pointer is, read every frame (so it tracks moves and drags alike, even
    /// before the window gets any mouse event).
    private func pointer() -> NSPoint? {
        guard let w = window else { return nil }
        let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(p) ? p : nil
    }

    private func step() {
        let home = NSPoint(x: bounds.width * 0.19, y: bounds.height * 0.135)
        // Pinned in place (user, Oct 25: "get rid of the weird thing that follows the mouse").
        let prev = cursor ?? home
        let now = followsPointer ? (pointer() ?? prev) : home
        cursor = now
        if rings.count != Self.radii.count { rings = Array(repeating: now, count: Self.radii.count) }
        for i in rings.indices {
            let k = Self.stiffness[i]
            rings[i].x += (now.x - rings[i].x) * k; rings[i].y += (now.y - rings[i].y) * k
        }
        let speed = hypot(now.x - prev.x, now.y - prev.y)
        spread += (min(speed / 45, 0.3) - spread) * 0.18
        spin += 0.002
        // Repaint only around the cluster: where it was and where it is.
        let pad = Self.radii.last! * 1.35 + 6
        let xs = rings.map(\.x) + [now.x], ys = rings.map(\.y) + [now.y]
        let box = NSRect(x: xs.min()! - pad, y: ys.min()! - pad, width: xs.max()! - xs.min()! + 2 * pad, height: ys.max()! - ys.min()! + 2 * pad)
        setNeedsDisplay(box.union(lastDirty))
        lastDirty = box
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = Brand.c
        if gridCache?.size != bounds.size || cacheDark != Brand.dark { gridCache = makeGrid(); cacheDark = Brand.dark }
        gridCache?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        guard cluster else { return }
        let center = cursor ?? NSPoint(x: bounds.width * 0.19, y: bounds.height * 0.135)
        let breath = breathing ? Breath.phase(seconds: -born.timeIntervalSinceNow) : 0.5   // 0 = empty, 1 = full
        let open = (1 + spread) * (breathing ? 0.72 + 0.5 * breath : 1)
        // Pinned to the pointer: the hairline circle and the center dot.
        c.ink.withAlphaComponent(Brand.dark ? 0.22 : 0.16).setStroke()
        let rr = 54 * (1 + spread * 0.5) * (breathing ? 0.7 + 0.6 * breath : 1)
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2)); ring.lineWidth = 0.8; ring.stroke()
        c.ink.withAlphaComponent(0.8).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
        // On springs: the dot rings.
        for (i, r) in Self.radii.enumerated() {
            let rc = i < rings.count ? rings[i] : center
            let n = 14 + i * 5
            c.ink.withAlphaComponent(0.45 - Double(i) * 0.07).setFill()
            let d: CGFloat = 2.6 - CGFloat(i) * 0.3
            for k in 0..<n {
                let a = Double(k) / Double(n) * 2 * .pi + Double(i) * 0.3 + spin * (i % 2 == 0 ? 1 : -1)
                let p = NSPoint(x: rc.x + CGFloat(cos(a)) * r * open, y: rc.y + CGFloat(sin(a)) * r * open)
                NSBezierPath(ovalIn: NSRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)).fill()
            }
        }
    }
    private var cacheDark = false

    private func makeGrid() -> NSImage {
        NSImage(size: bounds.size, flipped: true) { r in
            let c = Brand.c
            c.paper.setFill(); r.fill()
            c.dot.setFill()
            var y = self.spacing / 2
            while y < r.height { var x = self.spacing / 2; while x < r.width { NSBezierPath(ovalIn: NSRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4)).fill(); x += self.spacing }; y += self.spacing }
            return true
        }
    }
}

/// The viewfinder brackets from the logo (top-left, top-right, bottom-right), drawn around
/// whatever sits inside. Used to frame countdowns.
final class BracketView: NSView {
    var arm: CGFloat = 22, weight: CGFloat = 3
    init(around inner: NSView, padding: CGFloat = 28) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)
        NSLayoutConstraint.activate([inner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding * 1.4),
                                     inner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding * 1.4),
                                     inner.topAnchor.constraint(equalTo: topAnchor, constant: padding * 0.6),
                                     inner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding * 0.6)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        Brand.c.ink.setStroke()
        let b = bounds.insetBy(dx: weight / 2, dy: weight / 2), p = NSBezierPath(); p.lineWidth = weight; p.lineCapStyle = .square
        // AppKit is bottom-up: maxY is the top.
        p.move(to: NSPoint(x: b.minX, y: b.maxY - arm)); p.line(to: NSPoint(x: b.minX, y: b.maxY)); p.line(to: NSPoint(x: b.minX + arm, y: b.maxY))
        p.move(to: NSPoint(x: b.maxX - arm, y: b.maxY)); p.line(to: NSPoint(x: b.maxX, y: b.maxY)); p.line(to: NSPoint(x: b.maxX, y: b.maxY - arm))
        p.move(to: NSPoint(x: b.maxX, y: b.minY + arm)); p.line(to: NSPoint(x: b.maxX, y: b.minY)); p.line(to: NSPoint(x: b.maxX - arm, y: b.minY))
        p.stroke()
    }
}

/// A full-screen brand surface: dot grid, wordmark top-left, tagline bottom-left, a tag
/// bottom-right, and `content` centered. Used by the break lock and the eye break.
enum BrandScreen {
    static func make(frame: NSRect, content: NSView, tag: String, footer: String = "Adults need supervision.", breathing: Bool = false, calm: Bool = false) -> NSView {
        // Calm (rest breaks, the user Oct 25): no corner cluster, no tagline: nothing to read but the circle.
        let v = DotGridView(frame: NSRect(origin: .zero, size: frame.size)); v.cluster = !calm; v.breathing = breathing
        let mark = Brand.wordmark(height: 30)
        let tagline = Brand.text(calm ? "" : footer, Brand.display(17, .medium), Brand.c.ink)
        let t = Brand.tag(tag)
        content.translatesAutoresizingMaskIntoConstraints = false
        [mark, tagline, t, content].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; v.addSubview($0) }
        NSLayoutConstraint.activate([
            mark.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -56), mark.topAnchor.constraint(equalTo: v.topAnchor, constant: 52),
            tagline.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 48), tagline.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -44),
            t.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -56), t.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -48),
            content.centerXAnchor.constraint(equalTo: v.centerXAnchor), content.centerYAnchor.constraint(equalTo: v.centerYAnchor, constant: 10),
        ])
        return v
    }
}

/// The breathing circle (user, Oct 25: "a circle in the middle of the screen"): grows on the
/// inhale and shrinks on the exhale at 5.5 s each (Breath), with the countdown inside it.
final class BreathView: NSView {
    /// One clock for the circle and the bell, reset when a break starts.
    static var epoch = Date()
    private var timer: Timer?
    private let cue = NSTextField(labelWithString: "")
    init(around inner: NSView, size: CGFloat = 340) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        inner.translatesAutoresizingMaskIntoConstraints = false
        cue.font = Brand.mono(11, .medium); cue.textColor = Brand.c.faint; cue.translatesAutoresizingMaskIntoConstraints = false
        cue.stringValue = "BREATHE IN"
        addSubview(inner); addSubview(cue)
        NSLayoutConstraint.activate([inner.centerXAnchor.constraint(equalTo: centerXAnchor), inner.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     cue.centerXAnchor.constraint(equalTo: centerXAnchor), cue.topAnchor.constraint(equalTo: inner.bottomAnchor, constant: 2)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.needsDisplay = true }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    override func draw(_ dirtyRect: NSRect) {
        // Brand-style breathing (Oct 25: "make it look cooler"): a soft glow, a ring of dots on the
        // breath, an inner ring turning the other way, and a faint dotted guide at full breath.
        let c = Brand.c, t = -Self.epoch.timeIntervalSinceNow, b = Breath.phase(seconds: t)
        cue.stringValue = Breath.inhaling(seconds: t) ? "BREATHE IN" : "BREATHE OUT"
        let maxR = bounds.width / 2 - 6, r = maxR * (0.56 + 0.44 * b), mid = NSPoint(x: bounds.midX, y: bounds.midY)
        // Glow.
        if let g = NSGradient(colors: [c.ink.withAlphaComponent(Brand.dark ? 0.14 : 0.07), c.ink.withAlphaComponent(0)]) {
            g.draw(in: NSBezierPath(ovalIn: NSRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2)), relativeCenterPosition: .zero)
        }
        func ring(radius: CGFloat, count: Int, size: CGFloat, alpha: CGFloat, turn: Double) {
            c.ink.withAlphaComponent(alpha).setFill()
            for k in 0..<count {
                let a = Double(k) / Double(count) * 2 * .pi + turn
                let p = NSPoint(x: mid.x + CGFloat(cos(a)) * radius, y: mid.y + CGFloat(sin(a)) * radius)
                NSBezierPath(ovalIn: NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)).fill()
            }
        }
        ring(radius: maxR, count: 90, size: 1.4, alpha: 0.16, turn: 0)                              // guide: full breath
        ring(radius: r, count: 56, size: 3.2 + CGFloat(b) * 1.2, alpha: 0.75, turn: t * 0.05)       // the breath
        ring(radius: r * 0.78, count: 40, size: 2.2, alpha: 0.32, turn: -t * 0.08)                  // inner, counter-turning
    }
}

/// Little dots that fill as progress is made (blinks, seconds of stretch): visible proof it saw you.
final class ProgressDots: NSView {
    var total: Int { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var filled = 0 { didSet { if filled != oldValue { needsDisplay = true } } }
    init(total: Int) { self.total = total; super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: CGFloat(total) * 16, height: 14) }
    override func draw(_ dirtyRect: NSRect) {
        let c = Brand.c
        for i in 0..<total {
            let r = NSRect(x: CGFloat(i) * 16 + 3, y: 2, width: 10, height: 10)
            let p = NSBezierPath(ovalIn: r)
            if i < filled { c.ink.setFill(); p.fill() } else { c.ink.withAlphaComponent(0.18).setStroke(); p.lineWidth = 1; p.stroke() }
        }
    }
}

extension Brand {
    /// A quick flash so a counted blink or rep is felt, not just shown.
    static func flash(_ v: NSView) {
        v.alphaValue = 0.25
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.35; v.animator().alphaValue = 1 }
    }
}
