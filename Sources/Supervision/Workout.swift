import AppKit
import AVFoundation
import Vision

/// Workout breaks (user, Oct 26: "I have to do my clamshells and my push-ups in order to continue doing
/// work"). The camera counts reps with Apple's on-device body pose: push-ups by the elbow angle,
/// clamshells by how far the knees open (Rep.Counter). It prefers the iPhone as a Continuity Camera
/// (propped on the floor, near the Mac), else the Mac's own camera. Frames are analysed and dropped.
struct WorkoutStep { let title: String, kind: String, target: Int, hint: String }

enum CameraPick {
    /// The iPhone (Continuity Camera) when it's around, else the built-in camera.
    static func device(preferPhone: Bool) -> AVCaptureDevice? {
        // On this SDK an iPhone shows up as an "external" camera with isContinuityCamera set.
        let devs = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: .video, position: .unspecified).devices
        if preferPhone, let phone = devs.first(where: isPhone) { return phone }
        return devs.first { !isPhone($0) } ?? devs.first
    }
    /// Is an iPhone (Continuity Camera) available right now?
    static var phoneAvailable: Bool {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown], mediaType: .video, position: .unspecified).devices.contains(where: isPhone)
    }
    static func isPhone(_ d: AVCaptureDevice) -> Bool {
        d.isContinuityCamera || d.localizedName.localizedCaseInsensitiveContains("iphone")
    }
}

final class WorkoutCounter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "workout")
    private var counter = Rep.Counter.pushUp()
    private var kind = "pushups"
    private var last = Date.distantPast
    private(set) var usingPhone = false
    var onUpdate: ((_ reps: Int, _ coach: String) -> Void)?

    func start() -> Bool {
        guard session == nil, AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let cam = CameraPick.device(preferPhone: true), let input = try? AVCaptureDeviceInput(device: cam) else { return false }
        usingPhone = CameraPick.isPhone(cam)
        let s = AVCaptureSession(); s.sessionPreset = .high
        let out = AVCaptureVideoDataOutput(); out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddInput(input), s.canAddOutput(out) else { return false }
        s.addInput(input); s.addOutput(out); session = s
        queue.async { s.startRunning() }
        return true
    }
    func stop() { let s = session; session = nil; onUpdate = nil; queue.async { s?.stopRunning() } }
    /// Look for the iPhone again and switch to it (keeps the current count and callback).
    @discardableResult func reconnect() -> Bool {
        let keep = onUpdate
        let s = session; session = nil
        queue.sync { s?.stopRunning() }
        let ok = start()
        onUpdate = keep
        return ok && usingPhone
    }
    /// Start counting a new exercise from zero.
    func begin(_ k: String) { queue.async { self.kind = k; self.counter = k == "pushups" ? .pushUp() : k == "bridges" ? .bridge() : k == "legs" ? .legSpread() : .clamshell() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard -last.timeIntervalSinceNow > 0.08, let px = CMSampleBufferGetImageBuffer(buffer) else { return }
        last = Date()
        let aspect = Double(CVPixelBufferGetWidth(px)) / Double(max(1, CVPixelBufferGetHeight(px)))
        let req = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(cvPixelBuffer: px, options: [:]).perform([req])
        var coach = kind == "pushups" ? "Turn side-on to the camera so it can see your arm" : kind == "bridges" ? "Lie on your back, side-on to the camera" : "Lie on your side facing the camera, knees bent"
        if let body = req.results?.first, let pts = try? body.recognizedPoints(.all) {
            // Aspect-corrected points, so angles are true angles.
            let p: (VNHumanBodyPoseObservation.JointName) -> (Double, Double)? = { j in
                pts[j].flatMap { $0.confidence > 0.3 ? (Double($0.location.x) * aspect, Double($0.location.y)) : nil }
            }
            if kind == "bridges" {
                let sides: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] =
                    [(.leftShoulder, .leftHip, .leftKnee), (.rightShoulder, .rightHip, .rightKnee)]
                if let (s, h, k) = sides.lazy.compactMap({ (a, b, c) -> ((Double, Double), (Double, Double), (Double, Double))? in
                    guard let x = p(a), let y = p(b), let z = p(c) else { return nil }; return (x, y, z) }).first {
                    let angle = Rep.angle(s, h, k)
                    counter.feed(angle)
                    coach = angle > 155 ? "Hold at the top… then lower slowly" : "Lift your hips, slowly"
                } else { coach = "Back up so I can see your shoulder, hip and knee" }
            } else if kind == "pushups" {
                let sides: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] =
                    [(.leftShoulder, .leftElbow, .leftWrist), (.rightShoulder, .rightElbow, .rightWrist)]
                if let (s, e, w) = sides.lazy.compactMap({ (a, b, c) -> ((Double, Double), (Double, Double), (Double, Double))? in
                    guard let x = p(a), let y = p(b), let z = p(c) else { return nil }; return (x, y, z) }).first {
                    let angle = Rep.angle(s, e, w)
                    counter.feed(angle)
                    coach = angle < 110 ? "Down… and push up" : "Lower until your elbows bend"
                } else { coach = "Back up a little so I can see your shoulder, elbow and wrist" }
            } else {
                if let lk = p(.leftKnee), let rk = p(.rightKnee), let lh = p(.leftHip) ?? p(.rightHip) {
                    let hip = p(.rightHip).map { ((lh.0 + $0.0) / 2, (lh.1 + $0.1) / 2) } ?? lh
                    let angle = Rep.angle(lk, hip, rk)
                    counter.feed(angle)
                    coach = kind == "legs" ? (angle > 20 ? "Hold… and bring it back slowly" : "Lift the leg, slowly")
                                           : (angle > 25 ? "Open… and close slowly" : "Feet together, lift the top knee")
                } else { coach = "Back up so I can see your hips and both knees" }
            }
        }
        let r = counter.reps, c = coach
        DispatchQueue.main.async { self.onUpdate?(r, c) }
    }
}

/// The workout screen: one exercise at a time, live count and coaching, over the break.
final class WorkoutSession {
    static let shared = WorkoutSession()
    private var window: NSWindow?
    private let counter = WorkoutCounter()
    private let title = NSTextField(labelWithString: ""), count = NSTextField(labelWithString: ""), coachLine = NSTextField(labelWithString: "")
    private let tag = NSTextField(labelWithString: "")
    private let phoneStatus = NSTextField(labelWithString: "")
    private var handlers: [Card.Handler] = []
    private var deviceObserver: NSObjectProtocol?
    var isShowing: Bool { window != nil }

    /// ME/CFS- and POTS-friendly (user, Oct 26): everything lying down, slow, no position changes mid-set,
    /// and a timed sit-and-pause before standing so blood pressure can catch up.
    /// Standing set for places without room to lie down (the office): hand on the desk, slow.
    static func standing(reps: Int) -> [WorkoutStep] {
        [WorkoutStep(title: "Leg kickbacks · first leg", kind: "legs", target: reps, hint: "Hand on the desk, side-on to the camera. Slow kick back."),
         WorkoutStep(title: "Leg kickbacks · other leg", kind: "legs", target: reps, hint: "Same, other leg."),
         WorkoutStep(title: "Side leg raises · first leg", kind: "legs", target: reps, hint: "Face the camera, hand on the desk, lift out to the side."),
         WorkoutStep(title: "Side leg raises · other leg", kind: "legs", target: reps, hint: "Same, other leg.")]
    }

    static func steps(bridges: Int, clamshells: Int, pauseSeconds: Int = 30) -> [WorkoutStep] {
        [WorkoutStep(title: "Glute bridges", kind: "bridges", target: bridges, hint: "On your back, knees bent. Lift slowly, lower slowly."),
         WorkoutStep(title: "Clamshells · first side", kind: "clamshells", target: clamshells, hint: "Roll onto your side, knees bent, feet together."),
         WorkoutStep(title: "Clamshells · other side", kind: "clamshells", target: clamshells, hint: "Roll over slowly, same again."),
         WorkoutStep(title: "Sit up, then pause", kind: "pause", target: pauseSeconds, hint: "Sit before you stand. Let your heart rate settle.")]
    }

    /// `done(finished, summary)`. False if there's no camera to count with.
    func show(steps: [WorkoutStep], statement: String, promise: Bool = true, done: @escaping (_ finished: Bool, _ summary: String) -> Void) -> Bool {
        guard window == nil, !steps.isEmpty, counter.start() else { return false }
        var i = 0, reps = 0, coach = "", log: [String] = []
        let finish: (Bool) -> Void = { [weak self] ok in
            self?.close()
            done(ok, (log + (ok ? [] : ["stopped at \(steps[min(i, steps.count - 1)].title) \(reps)/\(steps[min(i, steps.count - 1)].target)"])).joined(separator: ", "))
        }
        counter.begin(steps[0].kind)
        counter.onUpdate = { r, c in reps = r; coach = c }
        let screen = NSScreen.main?.frame ?? .zero, size = NSSize(width: 760, height: 560)
        let w = LockWindow(contentRect: NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height),
                           styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
        w.backgroundColor = Brand.c.paper; w.appearance = Brand.appearance; w.hasShadow = true
        w.contentView = content(size: size, statement: statement, promise: promise ? {
            // Honour system (Oct 26) for what the camera can't see; logged as promised, reviewed weekly.
            log = ["promised: " + steps.filter { $0.kind != "pause" }.map { "\($0.title.components(separatedBy: " ·").first ?? $0.title) \($0.target)" }.joined(separator: ", ")]
            i = steps.count - 1; finish(true)
        } : nil) { finish(false) }
        w.makeKeyAndOrderFront(nil); window = w
        // The phone connecting mid-workout: switch to it on its own.
        deviceObserver = NotificationCenter.default.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main) { [weak self] note in
            guard let self = self, let d = note.object as? AVCaptureDevice, CameraPick.isPhone(d), !self.counter.usingPhone else { return }
            self.counter.reconnect()
        }
        var stepStarted = Date()
        let tick = Timer(timeInterval: 0.2, repeats: true) { [weak self] t in
            guard let self = self, self.window != nil else { t.invalidate(); return }
            let s = steps[i]
            if s.kind == "pause" { reps = Int(-stepStarted.timeIntervalSinceNow); coach = "Sitting. \(max(0, s.target - reps)) s, then stand slowly" }
            self.tag.stringValue = "WORKOUT · STEP \(i + 1) OF \(steps.count)"
            self.phoneStatus.stringValue = self.counter.usingPhone ? "📱 iPhone camera: connected ✓"
                : (CameraPick.phoneAvailable ? "📱 iPhone found: tap Use iPhone camera" : "📱 iPhone camera: not found · using the Mac's camera")
            self.title.stringValue = s.title
            let shown = s.kind == "pause" ? "\(max(0, s.target - reps))" : "\(min(reps, s.target)) / \(s.target)"
            if self.count.stringValue != shown { if !self.count.stringValue.isEmpty { Brand.flash(self.count) }; self.count.stringValue = shown }
            self.coachLine.stringValue = coach.isEmpty ? s.hint : coach
            if reps >= s.target {
                if s.kind != "pause" { log.append("\(s.title.components(separatedBy: " ·").first ?? s.title) \(s.target)") }
                i += 1; reps = 0; coach = ""; stepStarted = Date()
                if i >= steps.count {
                    t.invalidate(); self.counter.stop()
                    self.title.stringValue = "✓ Done"; self.coachLine.stringValue = "Nice work. Back to your break."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(true) }
                } else {
                    if steps[i].kind != "pause" { self.counter.begin(steps[i].kind) }
                    self.coachLine.stringValue = steps[i].kind == steps[i - 1].kind ? "Switch sides" : "Next: \(steps[i].title)"
                }
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        return true
    }

    func dismiss() { close() }
    private func close() {
        if let o = deviceObserver { NotificationCenter.default.removeObserver(o); deviceObserver = nil }
        counter.stop(); window?.orderOut(nil); window = nil; handlers = []
    }

    private func content(size: NSSize, statement: String, promise: (() -> Void)?, skip: @escaping () -> Void) -> NSView {
        let c = Brand.c
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 14
        tag.font = Brand.mono(10.5, .medium); tag.textColor = c.faint
        title.font = Brand.display(30, .semibold); title.textColor = c.ink
        count.font = Brand.digits(96); count.textColor = c.ink
        coachLine.font = Brand.display(19, .medium); coachLine.textColor = c.ink
        [tag, title].forEach { stack.addArrangedSubview($0) }
        stack.addArrangedSubview(BracketView(around: count, padding: 26))
        stack.addArrangedSubview(coachLine)
        // iPhone camera status and a reconnect button (user, Oct 26).
        phoneStatus.font = Brand.mono(11.5, .medium); phoneStatus.textColor = c.muted
        let use = Card.Handler { [weak self] in
            guard let self = self else { return }
            self.phoneStatus.stringValue = "📱 Looking for your iPhone…"
            if !self.counter.reconnect() {
                self.phoneStatus.stringValue = "📱 Not found. Lock the phone, set it still in landscape near the Mac, then try again"
            }
        }
        handlers.append(use)
        var rowViews: [NSView] = [phoneStatus, Brand.button("Use iPhone camera", size: 12, target: use, action: #selector(Card.Handler.fire))]
        if let promise {
            let h = Card.Handler { promise() }; handlers.append(h)
            rowViews.append(Brand.button("🤞 I promise I did it", size: 12, target: h, action: #selector(Card.Handler.fire)))
        }
        let row = NSStackView(views: rowViews)
        row.spacing = 10
        stack.addArrangedSubview(row)
        stack.setCustomSpacing(28, after: row)
        stack.addArrangedSubview(Brand.text("To stop, type \u{201C}\(statement)\u{201D} and press Return", Brand.mono(11), c.faint, align: .center))
        let field = Brand.field("only if you really need to", width: 480, noPaste: true)
        let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").joined(separator: " ") }
        let h = Card.Handler { if norm(field.stringValue) == norm(statement) { skip() } }
        handlers.append(h); field.target = h; field.action = #selector(Card.Handler.fire)
        stack.addArrangedSubview(field)
        let v = DotGridView(frame: NSRect(origin: .zero, size: size)); v.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: v.centerXAnchor), stack.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        return v
    }
}
