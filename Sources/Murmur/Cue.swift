import AVFoundation
import CoreAudio
import Foundation

/// A selectable start/stop sound.
struct SoundChoice {
    let id: String
    let title: String
    /// nil means the synthesized struck note.
    let path: String?
    /// Playback rate for the start cue (2.0 = an octave up).
    var rate: Double = 1.0
    /// Stop cue: a separate recorded note when available...
    var stopPath: String? = nil
    /// ...otherwise the start sample at this rate. Below 1 is lower and
    /// longer, so start and stop are one instrument, up then down.
    var stopRate: Double = 0.75
    /// Layer the sample with itself an octave and a fifth down. Right for
    /// thin UI blips; wrong for real instrument notes, which are full already.
    var body: Bool = false
}

/// The start and stop cues.
///
/// Recorded samples that ship with macOS, selectable from the menu bar, with a
/// synthesized note as the last resort. Six rounds of synthesis all read as
/// "techy" to the person who has to hear it forty times a day; a real
/// recording and a menu to pick from ends that loop.
///
/// Playback uses an output-only AVAudioEngine kept warm between cues, with
/// recovery after audio-device changes. Measured
/// alternatives, and why they lose:
///   NSSound        first play 312-2208 ms, and warm plays still BLOCK the
///                  calling thread 10.9-22.9 ms EVERY time.
///   AVAudioPlayer  first play 49.6-256.6 ms even after prepareToPlay plus a
///                  silent warmup play.
///   this           0.014-1.13 ms per trigger while the engine stays running.
///
/// Warm is not free: a running engine keeps the speaker hardware and
/// coreaudiod busy around the clock (2026-10-01: coreaudiod at about 9% of a
/// core, constant, with Sona the only audio client, on a Mac that never
/// sleeps). So the engine pauses `warmSeconds` after the last cue. In the
/// recorded history 65% of dictations follow the previous one within five
/// minutes, and those stay instant; the first cue after a quiet stretch
/// wakes the engine and logs what the wake cost.
final class Cue {

    private static let ax = "/System/Library/PrivateFrameworks/AXMediaUtilities.framework/Versions/A/Resources/sounds/"
    private static let alchemy = "/Library/Application Support/Logic/Alchemy Samples/"
    private static let exsKits = "/Library/Application Support/Logic/EXS Factory Samples/03 Drums & Percussion/02 Electronic Drum Kits/"

    /// Real instruments first (these ship with Logic and GarageBand and are
    /// present only where those are installed), then macOS UI sounds, then the
    /// synthesized fallback that is always there.
    static let choices: [SoundChoice] = [
        SoundChoice(id: "sona-blend", title: "Sona + Bottle + Purr", path: nil, stopRate: 1.0),
        SoundChoice(id: "sona-portable", title: "Sona (portable blend)", path: nil, stopRate: 1.0),
        SoundChoice(id: "note4rise", title: "Sona (original)", path: nil, stopRate: 1.0),
        SoundChoice(id: "note4", title: "Struck note (iteration 4)", path: nil, stopRate: 1.0),
        SoundChoice(id: "note4x2", title: "Struck note x2 (iteration 4)", path: nil, stopRate: 1.0),
        SoundChoice(id: "synth2", title: "Struck note x2 (iteration 5)", path: nil, stopRate: 1.0),
        SoundChoice(id: "clunk", title: "Clunk (iteration 3)", path: nil, stopRate: 1.0),
        SoundChoice(id: "clunknote", title: "Clunk + note", path: nil, stopRate: 1.0),
        SoundChoice(id: "chime", title: "Chime (warm chord)", path: nil, stopRate: 1.0),
        SoundChoice(id: "rhodes", title: "Electric piano (Rhodes)",
                    path: alchemy + "Keys/Electric Pianos/EPiano Mrk II/EPiano Mrk II C3.wav", stopRate: 0.75),
        SoundChoice(id: "vibes", title: "Vibraphone",
                    path: exsKits + "Thick Heat Kit/Vibraphone 01 - Thick Heat.aif", stopRate: 0.75),
        SoundChoice(id: "piano", title: "Piano (low)",
                    path: alchemy + "Keys/Acoustic Pianos/Christmas Piano/Christmas Piano A1.wav",
                    rate: 2.0, stopRate: 1.5),
        SoundChoice(id: "bell", title: "Bell",
                    path: alchemy + "Mallets/Metal Mallets/Bell Attack Pad/Bell Attack Pad C4.wav",
                    stopPath: alchemy + "Mallets/Metal Mallets/Bell Attack Pad/Bell Attack Pad G3.wav"),
        SoundChoice(id: "wood", title: "Woodblock",
                    path: exsKits + "Agogo Funk Kit/Woodblock - Agogo Funk.aif", stopRate: 0.8),
        SoundChoice(id: "pluck2", title: "Pluck", path: ax + "pluck2.aiff", body: true),
        SoundChoice(id: "bottle", title: "Bottle", path: "/System/Library/Sounds/Bottle.aiff", body: true),
        SoundChoice(id: "pop", title: "Pop", path: "/System/Library/Sounds/Pop.aiff", stopRate: 0.8, body: true),
        SoundChoice(id: "purr", title: "Purr", path: "/System/Library/Sounds/Purr.aiff", body: true),
        SoundChoice(id: "boop", title: "Boop",
                    path: "/System/Library/PrivateFrameworks/CallIntelligence.framework/Versions/A/Resources/boop.caf",
                    body: true),
        SoundChoice(id: "synth", title: "Struck note (iteration 5)", path: nil, stopRate: 1.0),
    ]
    /// Any folder under ~/.config/murmur/sounds/ holding a start.wav (and
    /// optionally stop.wav) shows up in the Sound menu under the folder's name.
    /// This is how the user brings a sound they actually like, from anywhere,
    /// without touching code. User sounds list first and the first one is the
    /// default, so dropping a folder in is enough.
    static var userSoundsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/murmur/sounds", isDirectory: true)
    }

    static var userChoices: [SoundChoice] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: userSoundsDirectory.path) else { return [] }
        return names.sorted().compactMap { name in
            let dir = userSoundsDirectory.appendingPathComponent(name)
            let start = ["start.wav", "start.aiff", "start.aif", "start.caf", "start.mp3", "start.m4a"]
                .map { dir.appendingPathComponent($0).path }.first { fm.fileExists(atPath: $0) }
            guard let start else { return nil }
            let stop = ["stop.wav", "stop.aiff", "stop.aif", "stop.caf", "stop.mp3", "stop.m4a"]
                .map { dir.appendingPathComponent($0).path }.first { fm.fileExists(atPath: $0) }
            return SoundChoice(id: "user:\(name)", title: name, path: start,
                               stopPath: stop, stopRate: 0.75)
        }
    }

    /// User folders first, then the built-ins actually present on this Mac.
    static var available: [SoundChoice] {
        userChoices + choices.filter { $0.path == nil || FileManager.default.fileExists(atPath: $0.path!) }
    }

    static let defaultChoice = "sona-blend"

    private lazy var engine = AVAudioEngine()
    private lazy var node = AVAudioPlayerNode()
    /// Body and room. A dry sample reads as thin and electronic no matter
    /// what the sample is; a low shelf, a gentle high cut and a short room
    /// are what make a cue feel full and finished.
    private lazy var eq = AVAudioUnitEQ(numberOfBands: 2)
    private lazy var reverb = AVAudioUnitReverb()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var sampleRate: Double { format.sampleRate }
    private var startBuffer: AVAudioPCMBuffer?
    private var stopBuffer: AVAudioPCMBuffer?
    // Graph ownership and playback readiness are different: a device change
    // can stop the engine without detaching any of its nodes.
    private var graphAttached = false
    private var connectedOutputFormat: AVAudioFormat?
    private var outputNeedsReconnect = true
    private var configurationObserver: NSObjectProtocol?
    private var hasStarted = false
    private var lastFailure: String?
    /// How long the engine stays running after the last cue.
    static let warmSeconds: TimeInterval = 300
    private var idleWork: DispatchWorkItem?
    /// Set when the warm window closed, so the next start is an expected
    /// wake rather than a recovery.
    private var idlePaused = false

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    /// Explicit file overrides beat the named choice.
    func prepare(choice: String?, startFile: String? = nil, stopFile: String? = nil, reverbMix: Double = 0.4) {
        if !graphAttached {
            do { try catchingFrameworkException { attachGraph() } }
            catch { Log.write("cue: graph setup raised \(error)") }
        }
        reverb.wetDryMix = Float(max(0, min(1, reverbMix)) * 100)
        apply(choice: choice, startFile: startFile, stopFile: stopFile)
        _ = ensurePlayback()
        scheduleIdlePause()
    }

    private func attachGraph() {
        engine.attach(node)
        engine.attach(eq)
        engine.attach(reverb)
        // Player and EQ run mono, matching the buffers. The reverb is a
        // stereo effect, so it sits AFTER the main mixer, where the signal
        // is already stereo, and feeds the output directly.
        engine.connect(node, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)

        let low = eq.bands[0]
        low.filterType = .lowShelf; low.frequency = 140; low.gain = 4; low.bypass = true
        let top = eq.bands[1]
        top.filterType = .lowPass; top.frequency = 9000; top.bandwidth = 0.9; top.bypass = true
        reverb.loadFactoryPreset(.mediumRoom)
        graphAttached = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // The engine posts on an internal queue. Never rewire or tear
            // it down there. A notification never replays an earlier cue.
            DispatchQueue.main.async { [weak self] in self?.configurationChanged() }
        }
    }

    private func outputFormat() -> AVAudioFormat? {
        #if CUE_PLAYBACK_TESTS
        if testingOutputUnavailable { return nil }
        #endif
        let hardware = engine.isInManualRenderingMode ? engine.manualRenderingFormat
            : engine.outputNode.outputFormat(forBus: 0)
        guard hardware.sampleRate.isFinite, hardware.sampleRate > 0, hardware.channelCount > 0 else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount)
    }

    private func configurationChanged() {
        guard graphAttached else { return }
        // A strike may already have recovered before this queued notification
        // arrives. Do not stop its newly scheduled sound a second time.
        if engine.isRunning, let current = outputFormat(), current == connectedOutputFormat { return }
        // A device change is a recovery, not a wake, even mid-idle.
        haltAfterFailure(nil)
    }

    /// Stops playback after a device change or a raised framework exception.
    /// The next strike reconnects and restarts the graph from scratch.
    private func haltAfterFailure(_ exception: Error?) {
        if let exception { Log.write("cue: playback raised \(exception)") }
        do { try catchingFrameworkException { node.stop(); engine.stop() } }
        catch { Log.write("cue: stop raised \(error)") }
        outputNeedsReconnect = true; idlePaused = false
        if exception != nil { lastFailure = "exception" }
    }

    /// A cue plays on every key press, from the main thread. AVFAudio raises
    /// (rather than throws) for some graph states, such as a player started
    /// on an engine a device change just stopped; uncaught, that would leave
    /// the main queue dead. Any raise is contained, logged and recovered on
    /// the next strike.
    @discardableResult
    private func ensurePlayback() -> Bool {
        do { return try catchingFrameworkException { ensurePlaybackUnguarded() } }
        catch { haltAfterFailure(error); return false }
    }

    private func ensurePlaybackUnguarded() -> Bool {
        guard graphAttached else { return false }
        let began = DispatchTime.now().uptimeNanoseconds
        guard let output = outputFormat() else {
            node.stop(); engine.stop(); outputNeedsReconnect = true; idlePaused = false
            reportFailure("output_unavailable"); return false
        }
        if outputNeedsReconnect || output != connectedOutputFormat {
            idlePaused = false
            node.stop(); engine.stop()
            engine.disconnectNodeOutput(engine.mainMixerNode)
            engine.disconnectNodeOutput(reverb)
            // Apple's reverb requires stereo even for a mono headset route.
            // Keep its existing stereo graph and let the output convert to
            // the device channel layout, using the current device sample rate.
            let effectFormat = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: 2)!
            engine.connect(engine.mainMixerNode, to: reverb, format: effectFormat)
            engine.connect(reverb, to: engine.outputNode, format: effectFormat)
            connectedOutputFormat = output; outputNeedsReconnect = false
        }
        var woke = false
        if !engine.isRunning {
            // Stopped engines can retain scheduled buffers. Only the new
            // start/stop request below may make sound after recovery.
            node.stop(); engine.prepare()
            do {
                #if CUE_PLAYBACK_TESTS
                if testingStartFailures > 0 { testingStartFailures -= 1; throw TestingFailure.start }
                #endif
                try engine.start()
            } catch { reportFailure("start_failed"); return false }
            if idlePaused && lastFailure == nil {
                woke = true
            } else if hasStarted || lastFailure != nil {
                Log.write("cue: playback_recovered")
            }
            idlePaused = false
            hasStarted = true
        }
        if !node.isPlaying { node.stop(); node.play() }
        if woke {
            // The whole main-thread cost, player restart included. The first
            // sample reaches the speaker a little later than a warm cue too.
            let ms = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
            Log.write(String(format: "cue: woke after idle in %.1f ms (main thread)", ms))
        }
        lastFailure = nil
        return true
    }

    private func reportFailure(_ reason: String) {
        if lastFailure != reason { Log.write("cue: " + reason) }
        lastFailure = reason
    }

    func setSound(_ id: String) {
        apply(choice: id, startFile: nil, stopFile: nil)
    }

    private func apply(choice: String?, startFile: String?, stopFile: String?) {
        let available = Self.available
        let pick = available.first { $0.id == choice }
            ?? available.first { $0.id == Self.defaultChoice }
            ?? Self.choices.last!
        if ["sona-blend", "sona-portable"].contains(pick.id), startFile == nil, stopFile == nil {
            let native = pick.id == "sona-blend"
            startBuffer = blended(start: true, native: native)
            stopBuffer = blended(start: false, native: native)
            Log.write("sound: Sona blended cues")
            return
        }
        if pick.id == "note4rise", startFile == nil, stopFile == nil {
            startBuffer = pair(note4(164.81), note4(329.63))   // E3 then E4: up
            stopBuffer = completion()
            Log.write("sound: Sona (original)")
            return
        }
        if pick.id == "note4", startFile == nil, stopFile == nil {
            startBuffer = note4(329.63)   // E4, up
            stopBuffer = note4(220.00)    // A3, down
            Log.write("sound: struck note (iteration 4)")
            return
        }
        if pick.id == "note4x2", startFile == nil, stopFile == nil {
            startBuffer = doubled(note4(329.63))
            stopBuffer = doubled(note4(220.00))
            Log.write("sound: struck note x2 (iteration 4)")
            return
        }
        if pick.id == "synth2", startFile == nil, stopFile == nil {
            startBuffer = doubled(note(164.81))   // E3 E3, up
            stopBuffer = doubled(note(110.00))    // A2 A2, down
            Log.write("sound: struck note x2 (iteration 5)")
            return
        }
        if pick.id == "synth", startFile == nil, stopFile == nil {
            startBuffer = note(164.81)   // E3, up
            stopBuffer = note(110.00)    // A2, down
            Log.write("sound: struck note (iteration 5)")
            return
        }
        if pick.id == "clunk", startFile == nil, stopFile == nil {
            startBuffer = clunk3(bodyFrom: 240, to: 90)
            stopBuffer = clunk3(bodyFrom: 170, to: 62)
            Log.write("sound: clunk (iteration 3)")
            return
        }
        if pick.id == "clunknote", startFile == nil, stopFile == nil {
            startBuffer = clunkNote(196.00, decay: 0.20)   // G3, up
            stopBuffer = clunkNote(146.83, decay: 0.17)    // D3, down
            Log.write("sound: clunknote")
            return
        }
        if pick.id == "chime", startFile == nil, stopFile == nil {
            startBuffer = chime(root: 196.00, decay: 0.24)   // G3 major, up
            stopBuffer = chime(root: 146.83, decay: 0.20)    // D3 major, down
            Log.write("sound: chime")
            return
        }
        let start = load(startFile) ?? load(pick.path, rate: pick.rate) ?? note(164.81)
        let stop = load(stopFile)
            ?? (pick.stopPath != nil ? load(pick.stopPath) : load(pick.path, rate: pick.stopRate))
            ?? note(110.00)
        startBuffer = pick.body ? start.flatMap(fattened) : start
        stopBuffer = pick.body ? stop.flatMap(fattened) : stop
        Log.write("sound: \(pick.id)")
    }

    /// System samples are loaded on the Mac, never redistributed with the app.
    /// Other platforms receive the original synthesized companion layers.
    private func blended(start: Bool, native: Bool) -> AVAudioPCMBuffer? {
        let base = start ? pair(note4(164.81), note4(329.63)) : completion()
        let rate = start ? 1.0 : 0.75
        let bottle = (native ? load("/System/Library/Sounds/Bottle.aiff", rate: rate).flatMap(fattened) : nil)
            ?? companion(bottle: true, pitch: rate)
        let purr = (native ? load("/System/Library/Sounds/Purr.aiff", rate: rate).flatMap(fattened) : nil)
            ?? companion(bottle: false, pitch: rate)
        let duration = start ? 0.48 : 0.46
        let frames = Int(sampleRate * duration)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let dst = out.floatChannelData?[0] else { return base }
        out.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { dst[i] = 0 }
        for (buffer, gain, delay) in [(base, Float(0.72), 0.0), (bottle, Float(0.30), 0.0), (purr, Float(0.21), 0.025)] {
            guard let buffer, let src = buffer.floatChannelData?[0] else { continue }
            let offset = Int(delay * sampleRate)
            for i in 0..<min(Int(buffer.frameLength), frames-offset) { dst[i+offset] += src[i]*gain }
        }
        for i in 0..<frames {
            let t = Double(i)/sampleRate
            let x = min(1, max(0, (duration-t)/0.10))
            dst[i] *= Float(x*x*(3-2*x))
        }
        return normalized(out, peak:0.55)
    }

    private func companion(bottle: Bool, pitch: Double) -> AVAudioPCMBuffer? {
        let frames = Int(sampleRate * 0.46)
        guard let out = AVAudioPCMBuffer(pcmFormat:format, frameCapacity:AVAudioFrameCount(frames)), let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let t = Double(i)/sampleRate
            let attack = min(1,t/0.003)
            let v: Double
            if bottle {
                let w = 2 * Double.pi * 530 * pitch * t
                v = (sin(w) + 0.26*sin(2.73*w)*exp(-t/0.028))*exp(-t/0.068)
            } else {
                let w = 2 * Double.pi * 190 * pitch * t
                let flutter = 0.65 + 0.35*sin(2 * Double.pi * 24 * t)
                v = (sin(w) + 0.3*sin(2*w))*flutter*exp(-t/0.14)
            }
            dst[i] = Float(v * attack * 0.55)
        }
        return out
    }

    func export(choice: String, directory: URL) throws {
        apply(choice:choice, startFile:nil, stopFile:nil)
        try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
        for (name,buffer) in [("start.wav",startBuffer),("stop.wav",stopBuffer)] {
            guard let buffer else { throw CleanupError.unavailable("Cue synthesis failed") }
            let settings: [String:Any] = [AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:sampleRate,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false]
            let file = try AVAudioFile(forWriting:directory.appendingPathComponent(name), settings:settings, commonFormat:.pcmFormatFloat32, interleaved:false)
            try file.write(from:buffer)
        }
    }

    func start() { strike(startBuffer) }
    func stop() { strike(stopBuffer) }

    private func strike(_ buffer: AVAudioPCMBuffer?) {
        guard let buffer, ensurePlayback() else { return }
        do { try catchingFrameworkException { node.scheduleBuffer(buffer, at: nil, options: .interrupts) } }
        catch { haltAfterFailure(error); return }
        scheduleIdlePause()
    }

    /// Every cue restarts the warm window; only the latest one can fire.
    private func scheduleIdlePause() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pauseIfIdle() }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleDelay, execute: work)
    }

    private var idleDelay: TimeInterval {
        #if CUE_PLAYBACK_TESTS
        if let testingIdleDelay { return testingIdleDelay }
        #endif
        return Self.warmSeconds
    }

    /// Releases the audio hardware. pause() keeps the prepared graph, so a
    /// wake is start() alone; the player is stopped first so nothing queued
    /// can sound on the next wake except that cue.
    private func pauseIfIdle() {
        idleWork = nil
        guard graphAttached, engine.isRunning else { return }
        // Bluetooth, display and AirPlay outputs fall asleep when their stream
        // stops and clip the start of the next sound; the always-running
        // stream is what kept cues reliable there. Release only the built-in
        // output, where the cost was measured, and look again next window in
        // case the route moves back.
        guard outputIsBuiltIn else { scheduleIdlePause(); return }
        do { try catchingFrameworkException { node.stop(); engine.pause() } }
        catch { haltAfterFailure(error); return }
        idlePaused = true
    }

    /// Unknown counts as not built-in, which keeps today's always-warm behavior.
    private var outputIsBuiltIn: Bool {
        #if CUE_PLAYBACK_TESTS
        if let testingOutputIsBuiltIn { return testingOutputIsBuiltIn }
        #endif
        if engine.isInManualRenderingMode { return true }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(engine.outputNode.auAudioUnit.deviceID,
                                                &address, 0, nil, &size, &transport)
        return status == noErr && transport == kAudioDeviceTransportTypeBuiltIn
    }

    #if CUE_PLAYBACK_TESTS
    private enum TestingFailure: Error { case start }
    var testingStartFailures = 0
    var testingOutputUnavailable = false
    var testingIdleDelay: TimeInterval?
    var testingOutputIsBuiltIn: Bool?
    static func testingOffline(sampleRate: Double = 44100) throws -> Cue {
        let cue = Cue()
        try cue.engine.enableManualRenderingMode(.offline,
            format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!, maximumFrameCount: 512)
        return cue
    }
    var testingEngineRunning: Bool { engine.isRunning }
    var testingPlayerRunning: Bool { node.isPlaying }
    var testingAttachedCount: Int { engine.attachedNodes.count }
    var testingWetDryMix: Float { reverb.wetDryMix }
    func testingStopEngine() { engine.stop() }
    func testingPausePlayer() { node.pause() }
    /// Strikes a buffer whose format the player was not connected with, so
    /// AVFAudio raises inside scheduleBuffer.
    func testingStrikeMismatchedBuffer() {
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4800)!
        buffer.frameLength = 4800
        strike(buffer)
    }
    func testingPostConfigurationChange() {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }
    func testingSetOutputRate(_ sampleRate: Double, channels: AVAudioChannelCount = 2) throws {
        node.stop(); engine.stop(); engine.disableManualRenderingMode()
        try engine.enableManualRenderingMode(.offline,
            format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!, maximumFrameCount: 512)
    }
    func testingRender(seconds: Double) throws -> [Float] {
        let frames = Int(seconds * engine.manualRenderingFormat.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        var samples: [Float] = []
        while samples.count < frames {
            let status = try engine.renderOffline(AVAudioFrameCount(min(512, frames-samples.count)), to: buffer)
            guard status == .success, buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { throw TestingFailure.start }
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        return samples
    }
    #endif

    /// Body. A single recorded sample is thin and hollow on its own, so the
    /// sample is layered with itself an octave down (0.6) and a fifth down
    /// (0.35): the same sound played as a chord with itself. The lower copies
    /// are longer, which also gives the cue a natural tail.
    private func fattened(_ base: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let octave = resampled(base, rate: 0.5),
              let fifth = resampled(base, rate: 2.0 / 3.0),
              let b = base.floatChannelData?[0],
              let o = octave.floatChannelData?[0],
              let f = fifth.floatChannelData?[0]
        else { return base }
        let n = Int(octave.frameLength)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let d = out.floatChannelData?[0]
        else { return base }
        out.frameLength = AVAudioFrameCount(n)
        let nb = Int(base.frameLength), nf = Int(fifth.frameLength)
        for k in 0..<n {
            d[k] = (k < nb ? b[k] : 0) + 0.6 * o[k] + 0.35 * (k < nf ? f[k] : 0)
        }
        return normalized(out)
    }

    /// A lower, quicker variation of the same wooden mallet sound.
    /// Release each note gently before mixing so neither tail ends abruptly.
    private func completion() -> AVAudioPCMBuffer? {
        func released(_ note: AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
            guard let note, let samples = note.floatChannelData?[0] else { return note }
            let frames = Int(note.frameLength)
            let releaseFrames = min(frames, Int(sampleRate * 0.012))
            for i in 0..<releaseFrames {
                let progress = Float(i) / Float(max(1, releaseFrames - 1))
                let fade = 1 - progress * progress * (3 - 2 * progress)
                samples[frames - releaseFrames + i] *= fade
            }
            return note
        }
        return pair(released(note4(164.81)), released(note4(110.00)), gap: 0.09)
    }

    /// Iteration 4, byte for byte: a mallet on a wooden bar. Clear
    /// fundamental with a marimba-like fourth partial, a touch of attack
    /// sparkle, a sub-octave thump for weight, and a few ms of low-passed
    /// noise for the strike. E4 up, A3 down.
    private func note4(_ f: Double) -> AVAudioPCMBuffer? {
        let duration = 0.26
        let frames = Int(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        var rng = SystemRandomNumberGenerator()
        var lowpass = 0.0
        let lpCoefficient = exp(-2 * .pi * 2500 / sampleRate)
        var peak: Float = 0
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let w = 2 * .pi * f * t
            let tone = sin(w) * exp(-t / 0.115)
                     + 0.38 * sin(4 * w) * exp(-t / 0.040)
                     + 0.10 * sin(10 * w) * exp(-t / 0.010)
            let thump = 0.55 * sin(w / 2) * exp(-t / 0.028)
            let noise = Double.random(in: -1...1, using: &rng)
            lowpass = lpCoefficient * lowpass + (1 - lpCoefficient) * noise
            let strike = lowpass * exp(-t / 0.003) * 0.9
            let attack = min(1.0, t / 0.0015)
            let v = Float((tone + thump + strike) * attack)
            out[i] = v
            peak = max(peak, abs(v))
        }
        if peak > 0 { let scale: Float = 0.55 / peak; for i in 0..<frames { out[i] *= scale } }
        return buffer
    }

    /// Iteration 5's note with two subtle additions: a voice an octave up,
    /// and a real woodblock knock under the attack at about a third of the
    /// note's level. Both are meant to be felt more than heard.
    private func knockNote(_ f: Double) -> AVAudioPCMBuffer? {
        guard let base = note(f), let d = base.floatChannelData?[0] else { return nil }
        let n = Int(base.frameLength)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let attack = min(1.0, t / 0.0015)
            d[i] += Float(0.28 * sin(2 * .pi * 2 * f * t) * exp(-t / 0.06) * attack)
        }
        if let knock = Self.woodblocks.lazy.compactMap({ self.load($0) }).first,
           let k = knock.floatChannelData?[0] {
            let m = min(n, Int(knock.frameLength))
            for i in 0..<m { d[i] += k[i] * 0.35 }
        }
        return normalized(base)
    }

    /// Two different hits in sequence. The second lands while the first is
    /// still ringing, so it reads as one gesture, not two cues. Levelled to
    /// match the single iteration-4 note.
    private func pair(_ a: AVAudioPCMBuffer?, _ b: AVAudioPCMBuffer?,
                      gap: Double = 0.12, first: Float = 0.9, second: Float = 1.0) -> AVAudioPCMBuffer? {
        guard let a, let b, let sa = a.floatChannelData?[0], let sb = b.floatChannelData?[0] else { return a ?? b }
        let na = Int(a.frameLength), nb = Int(b.frameLength)
        let offset = Int(sampleRate * gap)
        let total = max(na, offset + nb)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let d = out.floatChannelData?[0]
        else { return a }
        out.frameLength = AVAudioFrameCount(total)
        for i in 0..<total { d[i] = 0 }
        for i in 0..<na { d[i] += sa[i] * first }
        for i in 0..<nb { d[offset + i] += sb[i] * second }
        return normalized(out, peak: 0.55)
    }

    /// Two of the same hit, close together, the second a touch softer. Not
    /// a tail, not a bounce: a doo-doo.
    private func doubled(_ single: AVAudioPCMBuffer?, gap: Double = 0.105, second: Float = 0.88) -> AVAudioPCMBuffer? {
        guard let single, let src = single.floatChannelData?[0] else { return single }
        let n = Int(single.frameLength)
        let offset = Int(sampleRate * gap)
        let total = offset + n
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let d = out.floatChannelData?[0]
        else { return single }
        out.frameLength = AVAudioFrameCount(total)
        for i in 0..<total { d[i] = 0 }
        for i in 0..<n { d[i] += src[i] }
        for i in 0..<n { d[offset + i] += src[i] * second }
        return normalized(out)
    }

    /// Iteration 3, byte for byte as first shipped: a low body whose pitch
    /// drops fast, a second harmonic for wood, a very short low-passed noise
    /// burst for the strike. 130 ms. Start higher than stop.
    private func clunk3(bodyFrom f0: Double, to f1: Double) -> AVAudioPCMBuffer? {
        let duration = 0.13
        let frames = Int(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        var rng = SystemRandomNumberGenerator()
        var phase = 0.0
        var lowpass = 0.0
        let lpCoefficient = exp(-2 * .pi * 2800 / sampleRate)
        var peak: Float = 0
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let f = f1 + (f0 - f1) * exp(-t / 0.018)
            phase += 2 * .pi * f / sampleRate
            let body = sin(phase) * exp(-t / 0.034) + 0.35 * sin(2 * phase) * exp(-t / 0.020)
            let noise = Double.random(in: -1...1, using: &rng)
            lowpass = lpCoefficient * lowpass + (1 - lpCoefficient) * noise
            let strike = lowpass * exp(-t / 0.006) * 2.4
            let attack = min(1.0, t / 0.001)
            let v = Float((body + strike) * attack)
            out[i] = v
            peak = max(peak, abs(v))
        }
        if peak > 0 { let scale: Float = 0.6 / peak; for i in 0..<frames { out[i] *= scale } }
        return buffer
    }

    /// Recorded woodblock hits from the Logic library, in preference order.
    /// A real strike under a clean tone is what a synthesized thud is not.
    private static let woodblocks = [
        exsKits + "Deep Mystery Kit/Woodblock - Deep Mystery.aif",
        exsKits + "Agogo Funk Kit/Woodblock - Agogo Funk.aif",
        exsKits + "Red Line Kit/Woodblock_RedLine.aif",
    ]

    /// The one that was "pretty close", refined: a REAL woodblock strike for
    /// the clunk, with a clean tone stack tied to it. Note, a strong octave
    /// above, a lighter octave above that, and a sub below. No noise, no pitch
    /// sweep, no room. Falls back to a synthesized thud only if no sample
    /// library is installed.
    private func clunkNote(_ f: Double, decay: Double) -> AVAudioPCMBuffer? {
        let duration = 0.38
        let frames = Int(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        // Transient: recorded if possible.
        let transient = Self.woodblocks.lazy.compactMap { self.load($0) }.first
        let tData = transient?.floatChannelData?[0]
        let tLen = Int(transient?.frameLength ?? 0)

        var rng = SystemRandomNumberGenerator()
        var lowpass = 0.0
        let lpCoefficient = exp(-2 * .pi * 2200 / sampleRate)
        var bodyPhase = 0.0

        for i in 0..<frames {
            let t = Double(i) / sampleRate

            var strike = 0.0
            if let tData, i < tLen {
                strike = Double(tData[i]) * 0.8
            } else if transient == nil {
                // Synthesized fallback thud, kept short and low.
                let fb = 90 + (200 - 90) * exp(-t / 0.012)
                bodyPhase += 2 * .pi * fb / sampleRate
                let noise = Double.random(in: -1...1, using: &rng)
                lowpass = lpCoefficient * lowpass + (1 - lpCoefficient) * noise
                strike = 0.7 * sin(bodyPhase) * exp(-t / 0.030) + lowpass * exp(-t / 0.004) * 1.2
            }

            let w = 2 * .pi * f * t
            let attack = min(1.0, t / 0.003)
            let note = sin(w) * exp(-t / decay)
            let octave = 0.85 * sin(2 * w) * exp(-t / (decay * 0.75))
            let high = 0.28 * sin(4 * w) * exp(-t / (decay * 0.45))
            let sub = 0.45 * sin(w / 2) * exp(-t / (decay * 0.55))

            out[i] = Float(strike + attack * (0.9 * note + octave + high + sub))
        }
        return normalized(buffer)
    }

    /// A warm major chord (root, fifth, octave, third above) with a soft
    /// attack, a sub-octave underneath, and a slow decay, then the EQ and
    /// room on the way out. Built to be full rather than bright.
    private func chime(root: Double, decay: Double) -> AVAudioPCMBuffer? {
        let duration = 0.6
        let frames = Int(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        let voices: [(ratio: Double, amp: Double)] = [(1.0, 1.0), (1.5, 0.7), (2.0, 0.55), (2.5, 0.3)]
        let attack = 0.012
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let env = (t < attack ? t / attack : 1.0) * exp(-max(0, t - attack) / decay)
            var v = 0.0
            for voice in voices {
                let w = 2 * .pi * root * voice.ratio * t
                v += voice.amp * (sin(w) + 0.30 * sin(2 * w) + 0.10 * sin(3 * w))
            }
            v += 0.5 * sin(2 * .pi * root / 2 * t) * exp(-t / 0.16)   // sub
            out[i] = Float(v * env)
        }
        return normalized(buffer)
    }

    // MARK: - Synthesis (last resort)

    private func note(_ f: Double) -> AVAudioPCMBuffer? {
        let duration = 0.26
        let frames = Int(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        var rng = SystemRandomNumberGenerator()
        var lowpass = 0.0
        let lpCoefficient = exp(-2 * .pi * 2500 / sampleRate)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let w = 2 * .pi * f * t
            let tone = sin(w) * exp(-t / 0.085) + 0.22 * sin(4 * w) * exp(-t / 0.028)
            let thump = 0.70 * sin(w / 2) * exp(-t / 0.030)
            let noise = Double.random(in: -1...1, using: &rng)
            lowpass = lpCoefficient * lowpass + (1 - lpCoefficient) * noise
            let strike = lowpass * exp(-t / 0.003) * 0.9
            let attack = min(1.0, t / 0.0015)
            out[i] = Float((tone + thump + strike) * attack)
        }
        return normalized(buffer)
    }

    // MARK: - Sample files

    /// Reads a file into the engine's mono format, normalized, optionally
    /// resampled (`rate` < 1 plays lower and longer). nil on any problem, so a
    /// bad path silently falls back to the next option.
    private func load(_ path: String?, rate: Double = 1.0) -> AVAudioPCMBuffer? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: expanded)),
              file.length > 0,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil,
              let converter = AVAudioConverter(from: file.processingFormat, to: format)
        else { return nil }

        let ratio = format.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        let shifted = rate == 1.0 ? out : resampled(out, rate: rate)
        return shifted.map { normalized(trimmed($0, maxSeconds: 0.6, fade: 0.12)) }
    }

    /// Caps a sustained note so a piano or pad does not drone under the next
    /// thing the user does. The fade avoids a click at the cut.
    private func trimmed(_ buffer: AVAudioPCMBuffer, maxSeconds: Double, fade: Double) -> AVAudioPCMBuffer {
        let limit = Int(sampleRate * maxSeconds)
        let n = Int(buffer.frameLength)
        guard n > limit, let d = buffer.floatChannelData?[0] else { return buffer }
        let fadeFrames = Int(sampleRate * fade)
        for k in max(0, limit - fadeFrames)..<limit {
            d[k] *= Float(limit - k) / Float(fadeFrames)
        }
        buffer.frameLength = AVAudioFrameCount(limit)
        return buffer
    }

    /// Linear-interpolation resample. rate 0.75 = a fourth down, 4/3 longer.
    private func resampled(_ src: AVAudioPCMBuffer, rate: Double) -> AVAudioPCMBuffer? {
        let n = Int(Double(src.frameLength) / rate)
        guard n > 1,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let i = src.floatChannelData?[0], let o = out.floatChannelData?[0]
        else { return nil }
        out.frameLength = AVAudioFrameCount(n)
        let last = Int(src.frameLength) - 1
        for k in 0..<n {
            let pos = Double(k) * rate
            let a = min(Int(pos), last), b = min(a + 1, last)
            let f = Float(pos - Double(Int(pos)))
            o[k] = i[a] * (1 - f) + i[b] * f
        }
        return out
    }

    /// Peak-normalize so a quiet sample and a loud one land at the same level.
    private func normalized(_ buffer: AVAudioPCMBuffer, peak target: Float = 0.78) -> AVAudioPCMBuffer {
        guard let d = buffer.floatChannelData?[0] else { return buffer }
        let n = Int(buffer.frameLength)
        var peak: Float = 0
        for k in 0..<n { peak = max(peak, abs(d[k])) }
        if peak > 0 { let s: Float = target / peak; for k in 0..<n { d[k] *= s } }
        return buffer
    }
}
