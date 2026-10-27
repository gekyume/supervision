import AVFoundation
import Vision

/// Counts blinks from the Mac's camera with Apple's on-device face landmarks. Frames are
/// analysed in memory and dropped; nothing is recorded or saved. Every frame is analysed (Oct 27:
/// at ~8 a second a quick blink fell between frames).
final class BlinkCounter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "blinks")
    private var detector = BlinkRule.Detector()
    private var lastFace = Date.distantPast
    private var ratios: [Double] = []
    private var level = 1.0
    var onUpdate: ((_ blinks: Int, _ secondsSinceFace: Double, _ level: Double) -> Void)?

    /// False if the camera isn't allowed or available (the eye break then uses its timer).
    func start() -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized, let cam = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: cam) else { return false }
        let s = AVCaptureSession(); s.sessionPreset = .medium
        let out = AVCaptureVideoDataOutput(); out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddInput(input), s.canAddOutput(out) else { return false }
        s.addInput(input); s.addOutput(out)
        detector = BlinkRule.Detector(); lastFace = Date(); ratios = []
        session = s
        queue.async { s.startRunning() }
        return true
    }

    func stop() { let s = session; session = nil; queue.async { s?.stopRunning() } }

    /// For tuning the thresholds from real breaks: frames seen, open level, lowest dip.
    var summary: String {
        queue.sync {
            guard !ratios.isEmpty else { return "no face frames" }
            let sorted = ratios.sorted()
            return String(format: "%d face frames, open %.3f, lowest %.3f, median %.3f", ratios.count, detector.open ?? 0, sorted.first!, sorted[sorted.count / 2])
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(buffer) else { return }
        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: px, options: [:]).perform([req])
        if let face = req.results?.first, let l = face.landmarks?.leftEye, let r = face.landmarks?.rightEye {
            lastFace = Date()
            let ratio = (Self.openness(l.normalizedPoints) + Self.openness(r.normalizedPoints)) / 2
            detector.feed(ratio)
            if ratio > 0 { ratios.append(ratio); level = detector.level(ratio) }
        }
        let b = detector.blinks, since = -lastFace.timeIntervalSinceNow, lv = level
        DispatchQueue.main.async { self.onUpdate?(b, since, lv) }
    }

    /// Eye height / width from the landmark outline.
    private static func openness(_ p: [CGPoint]) -> Double {
        guard p.count >= 4 else { return 0 }
        let xs = p.map(\.x), ys = p.map(\.y)
        let w = (xs.max()! - xs.min()!), h = (ys.max()! - ys.min()!)
        return w > 0 ? Double(h / w) : 0
    }
}
