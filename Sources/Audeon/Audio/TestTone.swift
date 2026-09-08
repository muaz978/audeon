import Foundation
import AVFoundation
import CoreAudio

/// Plays a short sine tone directly into a specific output device, bypassing
/// the routing graph. One click on an output card answers "can this device
/// make sound at all?", which separates device problems from routing problems
/// when verifying by ear.
/// Main-actor isolated: `activeEngines` is mutated only from the routing
/// canvas. The render block deliberately is not: see `SineOscillator`.
@MainActor
final class TestTonePlayer {
    static let shared = TestTonePlayer()

    private var activeEngines: [AVAudioEngine] = []

    @discardableResult
    func play(deviceID: AudioDeviceID, seconds: Double = 1.5, frequency: Double = 440) -> Bool {
        let engine = AVAudioEngine()
        guard let unit = engine.outputNode.audioUnit else { return false }
        var dev = deviceID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &dev,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { return false }

        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0 else { return false }

        // Explicitly `@Sendable`, and the phase lives in the oscillator rather
        // than in a captured `var`. Both matter: a closure formed inside a
        // `@MainActor` type inherits that isolation, and the audio thread
        // calling a main-actor-isolated block traps at runtime.
        let oscillator = SineOscillator(frequency: frequency, sampleRate: sampleRate)
        let render: @Sendable (UnsafeMutablePointer<ObjCBool>,
                               UnsafePointer<AudioTimeStamp>,
                               AVAudioFrameCount,
                               UnsafeMutablePointer<AudioBufferList>) -> OSStatus = { _, _, frameCount, audioBufferList in
            oscillator.render(into: audioBufferList, frames: Int(frameCount))
            return noErr
        }
        let source = AVAudioSourceNode(renderBlock: render)

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        engine.connect(engine.mainMixerNode, to: engine.outputNode,
                       format: engine.outputNode.inputFormat(forBus: 0))

        do {
            engine.prepare()
            try engine.start()
        } catch {
            NSLog("Audeon.tone: could not start the test tone (\(error))")
            return false
        }

        activeEngines.append(engine)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            engine.stop()
            self?.activeEngines.removeAll { $0 === engine }
        }
        return true
    }
}


/// Generates a sine into an audio buffer list, carrying its phase between
/// render calls.
///
/// A small class rather than a `var` captured by the render block, for a reason
/// that only shows up at runtime: in the Swift 6 language mode a closure formed
/// inside a `@MainActor` type inherits that isolation, so the audio thread
/// calling it trips the executor check and traps -- with a libdispatch "BUG IN
/// CLIENT" abort on the I/O thread, far from anything that names the closure.
/// Keeping the phase here lets the render block be declared `@Sendable`, which
/// does not inherit isolation, and removes the mutable capture at the same time.
///
/// Concurrency: `@unchecked Sendable`. `increment` and `amplitude` are
/// immutable; `phase` is touched only inside `render`, which only ever runs on
/// the audio thread that owns this oscillator's node.
final class SineOscillator: @unchecked Sendable {
    private var phase = 0.0
    private let increment: Double
    private let amplitude: Float

    init(frequency: Double, sampleRate: Double, amplitude: Float = 0.25) {
        self.increment = 2.0 * Double.pi * frequency / sampleRate
        self.amplitude = amplitude
    }

    /// Audio thread only. No allocation, no locks, no ObjC message sends.
    func render(into audioBufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for frame in 0..<frames {
            let value = Float(sin(phase)) * amplitude
            phase += increment
            if phase > 2 * .pi { phase -= 2 * .pi }
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                data.assumingMemoryBound(to: Float.self)[frame] = value
            }
        }
    }
}
