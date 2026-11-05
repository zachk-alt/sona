import AVFoundation

/// Reads PCM buffers as Float samples in -1...1 whatever their layout:
/// Float32 or Int16, interleaved or not, any channel count. Apple's engine
/// takes 16-bit audio on some Macs and multi-input interfaces deliver more
/// than one channel, so the silence check and the microphone's mono mix
/// cannot assume Float32 mono. Other sample formats read as nil.
enum PCMSamples {
    /// Whether `format`'s samples can be read here.
    static func readable(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatInt16
    }

    /// Sets every non-finite Float32 sample (NaN or infinity) to 0 in place, at
    /// any channel count, as Windows' mono mixer does, so one bad sample from a
    /// microphone cannot reach the level meter or spread through the converter's
    /// filter. Int16 audio cannot hold one and is left alone.
    static func zeroNonFinite(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
        // Interleaved audio has one data pointer holding every channel.
        let interleaved = buffer.format.isInterleaved
        let pointers = interleaved ? 1 : channels, count = interleaved ? frames * channels : frames
        for p in 0..<pointers {
            let samples = data[p]
            for i in 0..<count where !samples[i].isFinite { samples[i] = 0 }
        }
    }

    /// Every sample, frame by frame in channel order, as SpeechActivity.add expects.
    static func interleaved(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let channels = Int(buffer.format.channelCount)
        var out = [Float](repeating: 0, count: Int(buffer.frameLength) * channels)
        let read = visit(buffer) { frame, channel, value in out[frame * channels + channel] = value }
        return read ? out : nil
    }

    /// One mono buffer in `format` (Float32, one channel, the buffer's rate)
    /// holding the average of all of `buffer`'s channels, frame by frame.
    /// The same rule as Windows: sum divided by the channel count.
    static func mono(_ buffer: AVAudioPCMBuffer, into format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channels = Float(max(1, buffer.format.channelCount))
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, buffer.frameLength)),
              let mixed = out.floatChannelData?[0] else { return nil }
        out.frameLength = buffer.frameLength
        mixed.update(repeating: 0, count: Int(buffer.frameLength))
        guard visit(buffer, { frame, _, value in mixed[frame] += value / channels }) else { return nil }
        return out
    }

    /// Calls `body` with each sample's frame, channel and value. False when
    /// the sample format is not Float32 or Int16. A non-finite Float32 sample
    /// reads as 0, as on Windows, so one bad sample cannot spread through the mix.
    private static func visit(_ buffer: AVAudioPCMBuffer, _ body: (Int, Int, Float) -> Void) -> Bool {
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        // Interleaved audio has one data pointer holding every channel.
        let interleaved = buffer.format.isInterleaved && channels > 1
        func walk<T>(_ data: UnsafePointer<UnsafeMutablePointer<T>>, _ value: (T) -> Float) {
            for channel in 0..<channels {
                let base = interleaved ? data[0] : data[channel]
                let offset = interleaved ? channel : 0, stride = interleaved ? channels : 1
                for frame in 0..<frames { body(frame, channel, value(base[frame * stride + offset])) }
            }
        }
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return false }
            walk(data) { $0.isFinite ? $0 : 0 }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return false }
            walk(data) { Float($0) / 32768 }
        default:
            return false
        }
        return true
    }
}
