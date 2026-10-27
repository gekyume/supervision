import AppKit
import AVFoundation

/// Earn a minute back (user, Oct 18): in a 10-minute break, each of these done = $3 to the
/// Rewards Ledger (nightly sync) and one minute off the wait. The photo is once a day, taken
/// with the Mac's camera and kept only on this Mac (photos/), to see progress over time.
struct RewardTask { let key: String, title: String, emoji: String, oncePerDay: Bool }

enum Rewards {
    static let tasks = [
        RewardTask(key: "photo", title: "Progress photo", emoji: "📸", oncePerDay: true),
        RewardTask(key: "pelvic", title: "Pelvic floor exercises", emoji: "🧘", oncePerDay: false),
        RewardTask(key: "gratitude", title: "Gratitude journal", emoji: "🙏", oncePerDay: false),
    ]
    static let dollars = 3
    static let photosDir = Paths.dir.appendingPathComponent("photos")
    /// Only regular breaks of 10–30 min: not the 2-min night cycle, not an hour off or a day lock.
    static func eligible(breakMinutes: Double) -> Bool { breakMinutes >= 9.5 && breakMinutes <= 30 }
    static var photoTakenToday: Bool {
        FileManager.default.fileExists(atPath: photosDir.appendingPathComponent("\(Day.string(Date())).jpg").path)
    }
    /// Ask for the camera now, while someone's at the keyboard; a permission prompt can't show over a lock.
    static func prepareCamera() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { AVCaptureDevice.requestAccess(for: .video) { _ in } }
    }
}

/// A small camera panel over the lock: live preview, 3-2-1, one photo saved to photos/<date>.jpg.
final class PhotoBooth: NSObject, AVCapturePhotoCaptureDelegate {
    static let shared = PhotoBooth()
    private var session: AVCaptureSession?
    private let output = AVCapturePhotoOutput()
    private var panel: NSPanel?
    private var label = NSTextField(labelWithString: "")
    private var done: ((Bool) -> Void)?

    func take(done: @escaping (Bool) -> Void) {
        guard panel == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized, let cam = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: cam) else {
            Store.shared.event("reward_photo", "camera unavailable or not allowed"); done(false); return
        }
        self.done = done
        let s = AVCaptureSession(); s.sessionPreset = .photo
        if s.canAddInput(input) { s.addInput(input) }
        if s.canAddOutput(output) { s.addOutput(output) }
        session = s
        let size = NSSize(width: 480, height: 360)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
        p.backgroundColor = .black; p.isOpaque = true; p.hasShadow = true
        let v = NSView(frame: NSRect(origin: .zero, size: size)); v.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: s); preview.frame = v.bounds; preview.videoGravity = .resizeAspectFill
        v.layer?.addSublayer(preview); v.layer?.cornerRadius = 14; v.layer?.masksToBounds = true
        label.font = Brand.digits(72); label.textColor = .white; label.alignment = .center
        label.frame = NSRect(x: 0, y: size.height / 2 - 45, width: size.width, height: 90)
        v.addSubview(label)
        p.contentView = v
        if let scr = NSScreen.main { p.setFrameOrigin(NSPoint(x: scr.frame.midX - size.width / 2, y: scr.frame.midY - size.height / 2)) }
        p.orderFrontRegardless(); panel = p
        DispatchQueue.global().async { s.startRunning() }
        var n = 3
        label.stringValue = "\(n)"
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            n -= 1
            guard let self = self else { t.invalidate(); return }
            if n > 0 { self.label.stringValue = "\(n)"; return }
            t.invalidate(); self.label.stringValue = ""
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        var ok = false
        if error == nil, let data = photo.fileDataRepresentation() {
            try? FileManager.default.createDirectory(at: Rewards.photosDir, withIntermediateDirectories: true)
            ok = (try? data.write(to: Rewards.photosDir.appendingPathComponent("\(Day.string(Date())).jpg"))) != nil
        }
        DispatchQueue.main.async {
            self.session?.stopRunning(); self.session = nil
            self.panel?.orderOut(nil); self.panel = nil
            let d = self.done; self.done = nil; d?(ok)
        }
    }
}

/// Gratitude journal (user, Oct 25: "I have to enter in the three things I'm grateful for"):
/// three boxes over the lock; the reward counts only when all three are filled. Saved to
/// gratitude/<date>.md on this Mac (and its text logged, so reviews can see it).
final class GratitudePanel {
    static let shared = GratitudePanel()
    static let dir = Paths.dir.appendingPathComponent("gratitude")
    private var panel: NSPanel?
    private var handlers: [Card.Handler] = []

    func ask(done: @escaping (Bool) -> Void) {
        guard panel == nil else { return }
        let c = Brand.c, width: CGFloat = 520
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 10), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
        p.backgroundColor = c.paper; p.appearance = Brand.appearance
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22); stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(Brand.tag("Gratitude journal · $\(Rewards.dollars) and a minute"))
        stack.addArrangedSubview(Brand.text("Three things you're grateful for today", Brand.display(18, .semibold), c.ink, wrap: width - 44))
        let fields = (1...3).map { Brand.field("\($0).", width: width - 44, size: 14) }
        fields.forEach { stack.addArrangedSubview($0) }
        let hint = NSTextField(labelWithString: ""); hint.font = Brand.mono(11.5); hint.textColor = c.ink
        let save = Card.Handler { [weak self] in
            let items = fields.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard items.allSatisfy({ $0.count >= 2 }) else { hint.stringValue = "All three, please. Small things count."; return }
            try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            let file = Self.dir.appendingPathComponent("\(Day.string(Date())).md")
            let entry = "## \(Day.clock(Date()))\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close() }
            else { try? entry.write(to: file, atomically: true, encoding: .utf8) }
            Store.shared.event("gratitude", items.joined(separator: " · "))
            self?.close(); done(true)
        }
        let cancel = Card.Handler { [weak self] in self?.close(); done(false) }
        handlers = [save, cancel]
        fields.last?.target = save; fields.last?.action = #selector(Card.Handler.fire)
        let row = NSStackView(views: [Brand.button("Save", primary: true, size: 14, target: save, action: #selector(Card.Handler.fire)),
                                      Brand.button("Not now", size: 14, target: cancel, action: #selector(Card.Handler.fire))])
        row.spacing = 8
        stack.addArrangedSubview(hint)
        stack.addArrangedSubview(row)
        let content = DotGridView(); content.spacing = 18; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        p.contentView = content
        p.setContentSize(NSSize(width: width, height: stack.fittingSize.height))
        if let s = NSScreen.main { p.setFrameOrigin(NSPoint(x: s.frame.midX - width / 2, y: s.frame.midY - p.frame.height / 2)) }
        p.orderFrontRegardless(); p.makeKey(); p.makeFirstResponder(fields[0])
        panel = p
    }

    func dismiss() { close() }
    private func close() { panel?.orderOut(nil); panel = nil; handlers = [] }
}
