import AVFoundation

/// A soft bell for eyes-closed breathing (user, Oct 25): a higher tone to breathe in, a lower
/// one to breathe out, every 5.5 s, in step with the circle. Off by default; the break screen's
/// 🔔 turns it on and the choice is remembered. Tones are generated here: no sound files.
final class BreathBell {
    static let shared = BreathBell()
    static var on: Bool {
        get { UserDefaults.standard.bool(forKey: "breathBell") }
        set { UserDefaults.standard.set(newValue, forKey: "breathBell") }
    }
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var timer: Timer?
    private var lastIn: Bool?
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private lazy var inTone = bell(hz: 528)
    private lazy var outTone = bell(hz: 396)

    func start() {
        guard timer == nil else { return }
        if engine.attachedNodes.contains(player) == false { engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format) }
        engine.mainMixerNode.outputVolume = 0.35
        do { try engine.start() } catch { return }
        player.play(); lastIn = nil
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    func stop() { timer?.invalidate(); timer = nil; player.stop(); engine.stop() }

    private func tick() {
        let inhaling = Breath.inhaling(seconds: -BreathView.epoch.timeIntervalSinceNow)
        guard inhaling != lastIn else { return }
        lastIn = inhaling
        player.scheduleBuffer(inhaling ? inTone : outTone, at: nil, options: [], completionHandler: nil)
    }

    /// A struck-bell sound: a sine plus a soft overtone, quick attack, long fade.
    private func bell(hz: Double) -> AVAudioPCMBuffer {
        let seconds = 2.2, n = AVAudioFrameCount(44100 * seconds)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        b.frameLength = n
        let d = b.floatChannelData![0]
        for i in 0..<Int(n) {
            let t = Double(i) / 44100
            let env = min(1, t / 0.008) * exp(-t * 2.2)
            d[i] = Float(env * (0.8 * sin(2 * .pi * hz * t) + 0.2 * sin(2 * .pi * hz * 2.76 * t)) * 0.5)
        }
        return b
    }
}
