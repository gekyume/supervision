import AppKit
import ApplicationServices
import CoreAudio
import CoreMediaIO

/// Context awareness for the break lock. A takeover in the middle of a call is the
/// fastest way to lose trust in the app. Zoom's own in-meeting process (`ZoomGuard`)
/// is trusted fully; the softer signals below (camera, meeting windows) can defer a
/// break for `Config.maxDeferralMinutes`. `microphoneInUse` is kept for diagnostics only.
enum MeetingDetector {
    /// Returns a human-readable reason if a call seems to be in progress, else nil.
    static func activeCall() -> String? {
        if cameraInUse() { return "Your camera is on" }
        if let w = meetingWindow() { return "'\(w)' looks like a live call" }
        // The microphone alone is not a call: recorders (screenpipe), dictation and Loom keep
        // it open all day, which once deferred every break for an hour (Sep 25).
        return nil
    }

    // MARK: Camera (CoreMediaIO) — no permission needed to ask "is any camera running?"

    static func cameraInUse() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0, size > 0 else { return false }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &devices) == 0 else { return false }
        for d in devices {
            var running = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var value: UInt32 = 0
            var vsize = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(d, &running, 0, nil, vsize, &vsize, &value) == 0, value != 0 { return true }
        }
        return false
    }

    // MARK: Microphone (CoreAudio) — is the default input device running somewhere?

    static func microphoneInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr, device != 0 else { return false }
        var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var vsize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &running, 0, nil, &vsize, &value) == noErr && value != 0
    }

    // MARK: Meeting windows — titles of every window in call-capable apps (Accessibility)

    private static let callApps = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
                                   "com.microsoft.edgemac", "com.brave.Browser", "ai.perplexity.comet", "com.microsoft.teams2", "com.microsoft.teams",
                                   "com.tinyspeck.slackmacgap", "us.zoom.xos", "com.webex.meetingmanager", "com.apple.FaceTime"]
    private static let markers = ["meet - ", "meet – ", "google meet", "meet.google", "microsoft teams", "zoom meeting", "zoom webinar", "huddle", "webex", "whereby", "facetime", "around.co"]

    static func meetingWindow() -> String? {
        for app in NSWorkspace.shared.runningApplications where callApps.contains(app.bundleIdentifier ?? "") {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            var wins: AnyObject?
            guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &wins) == .success,
                  let list = wins as? [AXUIElement] else { continue }
            for w in list {
                var t: AnyObject?
                guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success, let title = t as? String else { continue }
                let lower = title.lowercased()
                if markers.contains(where: { lower.contains($0) }) { return String(title.prefix(60)) }
            }
        }
        return nil
    }
}

/// Zoom in-meeting detection: Zoom spawns a `CptHost` process only while in a call.
enum ZoomGuard {
    static func inMeeting() -> Bool {
        let p = Process(); p.launchPath = "/usr/bin/pgrep"; p.arguments = ["-x", "CptHost"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }
}
