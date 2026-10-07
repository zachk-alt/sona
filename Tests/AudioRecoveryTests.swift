import AppKit
import AVFoundation
import CoreAudio

// The production AudioCapture against the real default microphone, inside an
// AppKit run loop like the app (scripts/test-audio-recovery.sh). A child copy
// of this program takes the microphone exclusively (hog mode) for a moment,
// which makes AVFAudio raise "Failed to create tap due to format mismatch".
// Before the fix that raise left the main queue dead: every later key press
// did nothing until Sona was quit and reopened. Hog mode ends when the child
// exits. Records about seven seconds in total and transcribes nothing.
// Skips on machines with no input device or no microphone permission.

func defaultInputDevice() -> AudioObjectID {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status == noErr ? device : 0
}

/// Child mode: hold the device exclusively, say so on stdout, then release it.
func hog(_ device: AudioObjectID, seconds: Double) -> Never {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyHogMode,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var owner = getpid()
    let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<pid_t>.size), &owner)
    var holder = pid_t(0)
    var size = UInt32(MemoryLayout<pid_t>.size)
    _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &holder)
    print(status == noErr && holder == getpid() ? "held" : "unsupported")
    fflush(stdout)
    Thread.sleep(forTimeInterval: seconds)
    var none = pid_t(-1)
    _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<pid_t>.size), &none)
    exit(0)
}

@MainActor
final class AudioRecoveryTests: NSObject, NSApplicationDelegate {
    let device: AudioObjectID
    let capture = AudioCapture()
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let lock = NSLock()
    nonisolated(unsafe) var frames = 0
    var checks = 0

    init(device: AudioObjectID) {
        self.device = device
        super.init()
        capture.onBuffer = { [weak self] buffer in
            guard let self else { return }
            self.lock.withLock { self.frames += Int(buffer.frameLength) }
        }
    }

    func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { print("FAILED: \(message)"); exit(1) }
    }
    var delivered: Int { lock.withLock { frames } }
    func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    /// Starts a child that takes the microphone exclusively for `seconds`,
    /// and returns once it actually holds it (a fixed wait flaked under load).
    func grabMicrophone(for seconds: Double) async throws -> Process {
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--hog", String(device), String(seconds)]
        child.standardOutput = pipe
        try child.run()
        let reply = await Task.detached { () -> String in
            String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
        }.value
        if !reply.contains("held") { print("Audio recovery: skipped, this microphone does not support exclusive access."); exit(0) }
        return child
    }

    /// True when the main queue still runs blocks: the property the bug destroyed.
    func mainQueueRuns() async -> Bool {
        await withCheckedContinuation { continuation in
            let answered = NSLock(); var done = false
            func answer(_ value: Bool) {
                let first = answered.withLock { () -> Bool in defer { done = true }; return !done }
                if first { continuation.resume(returning: value) }
            }
            DispatchQueue.main.async { answer(true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { answer(false) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await run()
            print("Audio recovery: \(checks) checks passed; real microphone, no transcription.")
            exit(0)
        }
    }

    func run() async {
        // Baseline.
        try? capture.start(convertingTo: target)
        await wait(0.6)
        capture.stop()
        check(delivered > 0, "Baseline dictation hears the microphone")

        // Busy microphone at the press: a clean thrown error, the main queue alive.
        let child = try! await grabMicrophone(for: 1.6)
        // Held exclusively, the microphone usually makes installTap raise
        // (now a thrown error); sometimes the engine starts and hears nothing,
        // which the stall watch covers. Either is fine. What must hold is that
        // nothing raises into AppKit: reaching the next line at all, with the
        // main queue alive, is the regression check (the old code wedged here).
        do { try capture.start(convertingTo: target); print("busy microphone: opened silent") }
        catch { print("busy microphone: \(error)") }
        capture.stop()
        check(await mainQueueRuns(), "The main queue keeps running after a busy-microphone press")
        child.waitUntilExit()
        await wait(0.3)

        // The press after it works.
        var before = delivered
        do { try capture.start(convertingTo: target) } catch { check(false, "The next press opens the microphone: \(error)") }
        await wait(0.6)
        capture.stop()
        check(delivered > before, "The press after a busy microphone hears the microphone")

        // Taken away mid-dictation, then returned: the stall watch reopens it.
        try? capture.start(convertingTo: target)
        await wait(0.6)
        let grab = try! await grabMicrophone(for: 1.0)
        grab.waitUntilExit()
        before = delivered
        await wait(2.5)
        let reopened = capture.reopenCount
        capture.stop()
        let resumed = delivered - before
        print("mid-dictation grab: \(reopened) reopen(s), \(resumed) frames in the 2.5 s after release")
        // 2.5 s at 16 kHz is 40,000 frames. The stall check runs every 1.2 s and
        // a reopen takes about 0.3 s, so hearing resumes within about 1.5 s of
        // the microphone coming back: at least 16,000 frames here.
        check(resumed > 14000, "A dictation resumes hearing once the microphone is returned")
        // A reopen judged too early used to tear the working engine down again.
        check(reopened == 1, "The returned microphone is reopened once, not torn down again")
        check(await mainQueueRuns(), "The main queue still runs at the end")
    }
}

@main
struct AudioRecoveryMain {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 4, arguments[1] == "--hog", let device = UInt32(arguments[2]), let seconds = Double(arguments[3]) {
            hog(AudioObjectID(device), seconds: seconds)
        }
        let device = defaultInputDevice()
        guard device != 0 else { print("Audio recovery: skipped, no input device."); exit(0) }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("Audio recovery: skipped, this terminal has no microphone permission."); exit(0)
        }
        let app = NSApplication.shared
        let tests = MainActor.assumeIsolated { AudioRecoveryTests(device: device) }
        app.delegate = tests
        app.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            print("FAILED: timed out (a dead main queue looks exactly like this)"); exit(1)
        }
        app.run()
    }
}
