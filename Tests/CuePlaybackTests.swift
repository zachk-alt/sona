import AVFoundation
import Foundation

// Compile the production Cue with an offline-only seam. These tests never
// enable hardware rendering, access a microphone, or write the app log.
enum Log {
    static var lines: [String] = []
    static func write(_ message: String) { lines.append(message) }
}
enum CleanupError: Error { case unavailable(String) }

@main struct CuePlaybackTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        func peak(_ samples: [Float]) -> Float { samples.map(abs).max() ?? 0 }
        func sameSound(_ a: [Float], _ b: [Float]) -> Bool {
            guard a.count == b.count,
                  let onsetA = a.firstIndex(where: { abs($0) > 0.001 }),
                  let onsetB = b.firstIndex(where: { abs($0) > 0.001 }),
                  abs(onsetA-onsetB) <= 1024 else { return false }
            // Reinitializing Apple's offline graph can prepend one render
            // quantum. Match the entire audible cue, not that priming silence.
            let count = min(a.count-onsetA, b.count-onsetB)
            let error = (0..<count).reduce(0.0) { $0 + pow(Double(a[onsetA+$1]-b[onsetB+$1]),2) }
            return sqrt(error/Double(count)) < 0.0001
                && peak(Array(a.suffix(from: onsetA+count))) < 0.001
                && peak(Array(b.suffix(from: onsetB+count))) < 0.001
        }
        func drainNotification() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }

        let cue = try Cue.testingOffline()
        cue.testingStartFailures = 1
        cue.prepare(choice: "sona-portable", reverbMix: 0)
        let attached = cue.testingAttachedCount
        check(!cue.testingEngineRunning && Log.lines.contains("cue: start_failed"), "Initial start failure is observable")
        cue.start()
        check(cue.testingEngineRunning && cue.testingPlayerRunning, "First requested cue retries a failed startup")
        let start = try cue.testingRender(seconds: 0.7)
        check(peak(start) > 0.1, "Recovered real graph renders the start cue")
        cue.stop()
        let stop = try cue.testingRender(seconds: 0.7)
        check(peak(stop) > 0.1, "Real graph renders the end cue")
        check(!sameSound(start, stop), "Start and end retain their distinct samples")

        cue.start() // This unrendered start must never return after recovery.
        cue.testingStopEngine()
        check(!cue.testingEngineRunning, "Regression setup stops the permanently warmed engine")
        cue.stop()
        let restarted = try cue.testingRender(seconds: 0.7)
        check(sameSound(stop, restarted), "Stopped engine recovers only the newly requested stop cue")
        check(cue.testingAttachedCount == attached, "Recovery never attaches nodes twice")

        cue.start(); cue.testingPausePlayer(); cue.stop()
        check(cue.testingPlayerRunning, "Paused player restarts before scheduling")
        check(sameSound(stop, try cue.testingRender(seconds: 0.7)), "Player recovery discards its old queued start")

        cue.testingOutputUnavailable = true; cue.start()
        check(!cue.testingEngineRunning, "Unavailable output stops rendering without scheduling")
        let warnings = Log.lines.count
        cue.stop()
        check(Log.lines.count == warnings, "Repeated unavailable strikes do not spam diagnostics")
        cue.testingOutputUnavailable = false; cue.stop()
        check(sameSound(stop, try cue.testingRender(seconds: 0.7)), "Returning output plays only the fresh cue")

        cue.start(); cue.testingStopEngine(); cue.testingPostConfigurationChange(); drainNotification()
        check(!cue.testingEngineRunning, "Configuration notification never starts or replays a cue")
        cue.stop()
        check(sameSound(stop, try cue.testingRender(seconds: 0.7)), "Notification recovery clears stale queued sound")

        cue.testingStopEngine(); cue.testingPostConfigurationChange(); cue.start(); drainNotification()
        check(cue.testingEngineRunning && cue.testingPlayerRunning, "Late configuration callback preserves a recovered current cue")
        check(sameSound(start, try cue.testingRender(seconds: 0.7)), "Late callback does not cut the new sound")

        try cue.testingSetOutputRate(48000)
        cue.testingPostConfigurationChange(); drainNotification(); cue.start()
        let changed = try cue.testingRender(seconds: 0.7)
        check(changed.count == 33600 && peak(changed) > 0.1, "Hardware-format change rewires graph and renders at new rate")
        check(cue.testingWetDryMix == 0 && cue.testingAttachedCount == attached, "Recovery preserves dry effect and graph ownership")
        try cue.testingSetOutputRate(24000, channels: 1); cue.start()
        let mono = try cue.testingRender(seconds: 0.7)
        check(mono.count == 16800 && peak(mono) > 0.1, "Mono headset format renders through the same reverb graph")
        try cue.testingSetOutputRate(44100, channels: 2); cue.stop()
        check(peak(try cue.testingRender(seconds: 0.7)) > 0.1, "Stereo playback returns after a mono route")
        let normalLogs = Log.lines.count
        cue.stop(); _ = try cue.testingRender(seconds: 0.7)
        check(Log.lines.count == normalLogs, "Healthy strikes do not log recovery")

        // Idle release: a warm engine holds the speaker hardware and
        // coreaudiod awake, so it pauses once the warm window closes.
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        cue.stop(); let stopNow = try cue.testingRender(seconds: 0.7)
        cue.testingIdleDelay = 0.05
        cue.start(); _ = try cue.testingRender(seconds: 0.7)
        check(cue.testingEngineRunning, "Engine stays warm right after a cue")
        wait(0.2)
        check(!cue.testingEngineRunning && !cue.testingPlayerRunning, "Engine releases the hardware after the warm window")
        cue.start() // Wakes and queues a start cue that idles out before it is ever rendered.
        wait(0.2)
        check(!cue.testingEngineRunning, "Each wake opens a window that closes when nothing follows")
        let idleLogs = Log.lines.count
        cue.stop()
        check(cue.testingEngineRunning && cue.testingPlayerRunning, "A cue after idle wakes the engine")
        check(sameSound(stopNow, try cue.testingRender(seconds: 0.7)), "Waking from idle plays only the new cue")
        check(Log.lines.count == idleLogs + 1 && Log.lines.last!.hasPrefix("cue: woke after idle in "),
              "An idle wake logs its cost once and is not reported as a recovery")
        cue.stop(); _ = try cue.testingRender(seconds: 0.7)
        check(Log.lines.count == idleLogs + 1, "Warm strikes after a wake log nothing")

        cue.testingIdleDelay = 0.3
        cue.start(); wait(0.2); cue.stop(); wait(0.2)
        check(cue.testingEngineRunning, "Each cue restarts the warm window")
        wait(0.3)
        check(!cue.testingEngineRunning, "The window closes after the last cue")

        cue.testingIdleDelay = 0.05; cue.testingStartFailures = 1
        cue.stop()
        check(!cue.testingEngineRunning && Log.lines.last == "cue: start_failed", "A failed wake is reported as a failure")
        cue.stop()
        check(cue.testingEngineRunning && Log.lines.last == "cue: playback_recovered", "A wake after a failure is reported as a recovery")
        check(sameSound(stopNow, try cue.testingRender(seconds: 0.7)), "Recovery after a failed wake plays only the new cue")

        wait(0.2)
        check(!cue.testingEngineRunning, "Idle again before a device change")
        cue.testingPostConfigurationChange(); drainNotification(); cue.stop()
        check(cue.testingEngineRunning && Log.lines.last == "cue: playback_recovered",
              "A device change during idle is reported as a recovery")
        check(sameSound(stopNow, try cue.testingRender(seconds: 0.7)), "A device change during idle plays only the new cue")

        wait(0.2)
        cue.testingOutputUnavailable = true; cue.start()
        check(!cue.testingEngineRunning && Log.lines.last == "cue: output_unavailable", "Output lost during idle is reported")
        cue.testingOutputUnavailable = false; cue.stop()
        check(cue.testingEngineRunning && Log.lines.last == "cue: playback_recovered",
              "Output returning after idle is reported as a recovery")
        check(sameSound(stopNow, try cue.testingRender(seconds: 0.7)), "Output returning after idle plays only the new cue")

        cue.testingOutputIsBuiltIn = false
        cue.stop(); _ = try cue.testingRender(seconds: 0.7); wait(0.2)
        check(cue.testingEngineRunning, "Bluetooth, display and AirPlay outputs stay warm as before")
        cue.testingOutputIsBuiltIn = true; wait(0.2)
        check(!cue.testingEngineRunning, "Moving back to the built-in output releases it at the next window")
        cue.testingOutputIsBuiltIn = nil

        // AVFAudio raises NSException for some graph states. A raise inside a
        // cue must be contained: uncaught on the main thread, AppKit swallows
        // it and the main queue (every later key press) never runs again.
        cue.start(); _ = try cue.testingRender(seconds: 0.7)
        cue.testingStrikeMismatchedBuffer()
        check(Log.lines.last?.hasPrefix("cue: playback raised com.apple.coreaudio.avfaudio") == true,
              "A raised AVFAudio exception during a cue is contained and logged")
        cue.stop()
        check(cue.testingEngineRunning && Log.lines.last == "cue: playback_recovered",
              "The next cue after a raised exception recovers")
        check(sameSound(stopNow, try cue.testingRender(seconds: 0.7)), "Recovery after a raised exception plays only the new cue")

        let fresh = try Cue.testingOffline()
        fresh.testingIdleDelay = 0.05
        fresh.prepare(choice: "sona-portable", reverbMix: 0)
        check(fresh.testingEngineRunning, "Launch warms the engine for the first cue")
        wait(0.2)
        check(!fresh.testingEngineRunning, "An unused launch warm-up still releases the hardware")
        print("Cue playback: \(checks) checks passed; real offline AVAudioEngine, no speaker or microphone access.")
    }
}
