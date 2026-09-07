import Foundation
import AVFoundation
import CoreAudio

/// Plays a short sine tone directly into a specific output device, bypassing
/// the routing graph. One click on an output card answers "can this device
/// make sound at all?", which separates device problems from routing problems
/// when verifying by ear.
/// Main-actor isolated: `activeEngines` is mutated only from the routing
/// canvas, and the source node's render block touches its own captured phase
/// rather than any state of this type.
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

        var phase = 0.0
        let increment = 2.0 * Double.pi * frequency / sampleRate
        let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                // A gentle fade at the edges avoids clicks.
                let value = Float(sin(phase)) * 0.25
                phase += increment
                if phase > 2 * .pi { phase -= 2 * .pi }
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    data.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }

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
