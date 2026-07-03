import Foundation
import AVFoundation

/// The EQ + overdrive + Magic Boost chain for cross-device routes.
///
/// Cross-device routes run on a direct I/O proc, not a live AVAudioEngine, so
/// this wraps an AVAudioEngine in realtime manual rendering mode: the I/O proc
/// hands it the input device's samples each cycle and pulls processed samples
/// back, keeping the exact same audio units (and therefore the exact same
/// sound) as same-device routes and per-app capture.
///
/// The chain is always stereo internally: mono inputs are duplicated on the
/// way in, and the I/O proc fans the stereo result out to however many output
/// channels the device has.
final class CrossDeviceDSPChain {
    static let channelCount: AVAudioChannelCount = 2

    private let engine = AVAudioEngine()
    private let eq = AVAudioUnitEQ(numberOfBands: AudioEQ.bandCount)
    private let magicBoost = MagicBoost.makeEffect()

    private let scratchIn: AVAudioPCMBuffer
    private let scratchOut: AVAudioPCMBuffer
    private var renderBlock: AVAudioEngineManualRenderingBlock

    /// Fails (returns nil) when manual rendering cannot start; the caller then
    /// keeps the plain gain path so audio still flows.
    init?(sampleRate: Double, maxFrames: AVAudioFrameCount) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: Self.channelCount),
              let scratchIn = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames),
              let scratchOut = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames) else { return nil }
        self.scratchIn = scratchIn
        self.scratchOut = scratchOut

        for (i, f) in AudioEQ.frequencies.enumerated() {
            let band = eq.bands[i]
            band.filterType = .parametric
            band.frequency = f
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = true
        }

        engine.attach(eq)
        engine.attach(magicBoost)

        do {
            try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: maxFrames)
        } catch {
            NSLog("Audeon.route: manual rendering unavailable (\(error)); cross route stays on the plain gain path")
            return nil
        }

        engine.connect(engine.inputNode, to: eq, format: format)
        engine.connect(eq, to: magicBoost, format: format)
        engine.connect(magicBoost, to: engine.mainMixerNode, format: format)

        let inBuffer = scratchIn
        let ok = engine.inputNode.setManualRenderingInputPCMFormat(format) { _ in
            UnsafePointer(inBuffer.audioBufferList)
        }
        guard ok else {
            NSLog("Audeon.route: manual rendering input rejected; cross route stays on the plain gain path")
            return nil
        }

        do {
            try engine.start()
        } catch {
            NSLog("Audeon.route: manual rendering engine failed to start (\(error)); cross route stays on the plain gain path")
            return nil
        }
        renderBlock = engine.manualRenderingBlock
    }

    /// Mirror of the live engines' configure: volume on the mixer, boost as EQ
    /// global gain, per-band EQ, and the Magic Boost compressor.
    func configure(_ route: Route) {
        engine.mainMixerNode.outputVolume = route.isMuted ? 0 : Float(route.volume)
        eq.globalGain = route.isMuted ? -96 : AudioEQ.boostDecibels(route.boost)
        for (i, band) in eq.bands.enumerated() where i < route.eq.count {
            band.bypass = !route.eqEnabled
            band.gain = Float(route.eq[i])
        }
        MagicBoost.configure(magicBoost, enabled: route.magicBoost)
    }

    /// Run one I/O cycle through the chain. `read` copies the input device's
    /// samples into the given stereo scratch channels. Returns the processed
    /// stereo channels, or nil if rendering failed this cycle (caller falls
    /// back to the raw path for the cycle).
    func process(frames: AVAudioFrameCount,
                 read: (_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) -> Void)
        -> (left: UnsafePointer<Float>, right: UnsafePointer<Float>)? {
        guard frames <= scratchIn.frameCapacity,
              let inData = scratchIn.floatChannelData,
              let outData = scratchOut.floatChannelData else { return nil }

        read(inData[0], inData[1], Int(frames))
        scratchIn.frameLength = frames
        scratchOut.frameLength = frames

        var err: OSStatus = noErr
        let status = renderBlock(frames, scratchOut.mutableAudioBufferList, &err)
        guard status == .success else { return nil }
        return (UnsafePointer(outData[0]), UnsafePointer(outData[1]))
    }
}
