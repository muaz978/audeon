import Foundation
import AVFoundation

/// Writes a source's processed audio to a file. The file is opened lazily on
/// the first buffer so it always matches the live stream's format, and writes
/// happen on the audio callback thread (the same pattern the meter taps use).
final class MixRecorder {
    let url: URL
    private var file: AVAudioFile?
    private var finished = false

    init(url: URL) {
        self.url = url
    }

    /// Append a rendered buffer (AVAudioEngine tap path).
    func append(_ buffer: AVAudioPCMBuffer) {
        guard !finished else { return }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings)
        }
        try? file?.write(from: buffer)
    }

    /// Append deinterleaved float channels (direct I/O proc path).
    func append(deinterleaved channels: [[Float]], sampleRate: Double) {
        guard !finished, let frames = channels.first?.count, frames > 0 else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels.count)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.floatChannelData else { return }
        for ch in 0..<channels.count {
            channels[ch].withUnsafeBufferPointer { src in
                dst[ch].update(from: src.baseAddress!, count: min(frames, src.count))
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        append(buffer)
    }

    /// Close the file. Safe to call once from the main thread; the audio thread
    /// checks `finished` before touching the file.
    func finish() {
        finished = true
        file = nil
    }
}

/// A swappable mount point for a recorder inside an audio engine. The main
/// thread assigns it; the audio callback reads it on every cycle. Keeping the
/// indirection in one small class lets engines be rebuilt while a recording
/// continues seamlessly on the replacement engine.
final class RecorderSlot {
    var recorder: MixRecorder?
}
