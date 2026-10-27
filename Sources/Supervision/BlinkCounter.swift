import AVFoundation
import Vision

/// Counts blinks from the Mac's camera with Apple's on-device face landmarks. Frames are
/// analysed in memory and dropped; nothing is recorded or saved. ~10 analyses a second.
final class BlinkCounter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "blinks")
    private var detector = BlinkRule.Detector()
    private var lastFace = Date.distantPast
    private var lastAnalysis = Date.distantPast
    var onUpdate: ((_ blinks: Int, _ secondsSinceFace: Double) -> Void)?

    /// False if the camera isn't allowed or available (the eye break then uses its timer).
    func start() -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized, let cam = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: cam) else { return false }
        let s = AVCaptureSession(); s.sessionPreset = .medium
        let out = AVCaptureVideoDataOutput(); out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddInput(input), s.canAddOutput(out) else { return false }
        s.addInput(input); s.addOutput(out)
        detector = BlinkRule.Detector(); lastFace = Date()
        session = s
        queue.async { s.startRunning() }
        return true
    }

    func stop() { let s = session; session = nil; queue.async { s?.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard -lastAnalysis.timeIntervalSinceNow > 0.1, let px = CMSampleBufferGetImageBuffer(buffer) else { return }
        lastAnalysis = Date()
        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: px, options: [:]).perform([req])
        if let face = req.results?.first, let l = face.landmarks?.leftEye, let r = face.landmarks?.rightEye {
            lastFace = Date()
            detector.feed((Self.openness(l.normalizedPoints) + Self.openness(r.normalizedPoints)) / 2)
        }
        let b = detector.blinks, since = -lastFace.timeIntervalSinceNow
        DispatchQueue.main.async { self.onUpdate?(b, since) }
    }

    /// Eye height / width from the landmark outline.
    private static func openness(_ p: [CGPoint]) -> Double {
        guard p.count >= 4 else { return 0 }
        let xs = p.map(\.x), ys = p.map(\.y)
        let w = (xs.max()! - xs.min()!), h = (ys.max()! - ys.min()!)
        return w > 0 ? Double(h / w) : 0
    }
}
