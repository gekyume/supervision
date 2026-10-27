import AVFoundation
import Vision

/// Watches for the break's movement (MoveRule.posed) with Apple's on-device body pose. Frames are
/// analysed in memory and dropped; nothing is recorded. Reports seconds held, ~8 checks a second.
final class MoveCounter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = MoveCounter()
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "move")
    private var last = Date.distantPast
    private var held = 0.0
    var needStand = true
    var onUpdate: ((_ held: Double, _ posed: Bool, _ coach: String) -> Void)?
    /// The joints seen this frame, for the live dot figure (PoseView keys).
    var onJoints: (([String: CGPoint]) -> Void)?

    func start(needStand: Bool) -> Bool {
        guard session == nil, AVCaptureDevice.authorizationStatus(for: .video) == .authorized, let cam = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: cam) else { return false }
        let s = AVCaptureSession(); s.sessionPreset = .medium
        let out = AVCaptureVideoDataOutput(); out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddInput(input), s.canAddOutput(out) else { return false }
        s.addInput(input); s.addOutput(out)
        self.needStand = needStand; held = 0; last = Date()
        session = s
        queue.async { s.startRunning() }
        return true
    }

    func stop() { let s = session; session = nil; onUpdate = nil; onJoints = nil; queue.async { s?.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date(), dt = now.timeIntervalSince(last)
        guard dt > 0.12, let px = CMSampleBufferGetImageBuffer(buffer) else { return }
        last = now
        let req = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(cvPixelBuffer: px, options: [:]).perform([req])
        var posed = false
        var seen: [String: CGPoint] = [:]
        var coach = MoveRule.coach(bodySeen: false, shoulderWidth: nil, centerX: nil, hipsVisible: false, needStand: needStand, leftWristUp: false, rightWristUp: false)
        if let body = req.results?.first, let pts = try? body.recognizedPoints(.all) {
            let p: (VNHumanBodyPoseObservation.JointName) -> CGPoint? = { j in pts[j].flatMap { $0.confidence > 0.3 ? $0.location : nil } }
            let keys: [(String, VNHumanBodyPoseObservation.JointName)] = [("nose", .nose), ("neck", .neck), ("lS", .leftShoulder), ("rS", .rightShoulder),
                ("lE", .leftElbow), ("rE", .rightElbow), ("lW", .leftWrist), ("rW", .rightWrist), ("lH", .leftHip), ("rH", .rightHip),
                ("lK", .leftKnee), ("rK", .rightKnee), ("lA", .leftAnkle), ("rA", .rightAnkle)]
            for (k, j) in keys { if let q = p(j) { seen[k] = q } }
            let hips = p(.leftHip) != nil || p(.rightHip) != nil
            let nose = p(.nose) ?? p(.neck)
            let lw = p(.leftWrist), rw = p(.rightWrist), ls = p(.leftShoulder), rs = p(.rightShoulder)
            posed = MoveRule.posed(leftWristY: lw.map { Double($0.y) }, rightWristY: rw.map { Double($0.y) }, noseY: nose.map { Double($0.y) }, hipsVisible: hips, needStand: needStand)
            let width = (ls != nil && rs != nil) ? Double(hypot(ls!.x - rs!.x, ls!.y - rs!.y)) : nil
            let center = nose.map { Double($0.x) } ?? ls.map { Double($0.x) }
            let up: (CGPoint?) -> Bool = { w in guard let w, let n = nose else { return false }; return w.y > n.y }
            coach = MoveRule.coach(bodySeen: nose != nil || ls != nil || rs != nil, shoulderWidth: width, centerX: center,
                                   hipsVisible: hips, needStand: needStand, leftWristUp: up(lw), rightWristUp: up(rw))
        }
        if posed { held += min(dt, 0.5) }
        let h = held
        DispatchQueue.main.async { self.onUpdate?(h, posed, coach); self.onJoints?(seen) }
    }
}
