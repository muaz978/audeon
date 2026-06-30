import Foundation
import AVFoundation
import CoreAudio
import Combine

/// Routes device sources to output devices. One AVAudioEngine per route:
///   input device -> EQ (with boost as global gain) -> mixer -> output device.
/// The mixer performs any sample-rate conversion between mismatched devices.
final class AudioRouter: ObservableObject {
    @Published private(set) var lastError: String?

    private let deviceManager: AudioDeviceManager
    private var engines: [UUID: RouteEngine] = [:]
    private let lock = NSLock()

    init(deviceManager: AudioDeviceManager) {
        self.deviceManager = deviceManager
    }

    func apply(routes: [Route]) {
        lock.lock(); defer { lock.unlock() }

        let wanted = Set(routes.map(\.id))
        for (id, engine) in engines where !wanted.contains(id) {
            engine.stop(); engines[id] = nil
        }

        for route in routes {
            guard let inID = deviceManager.deviceID(forUID: route.inputDeviceUID),
                  let outID = deviceManager.deviceID(forUID: route.outputDeviceUID) else { continue }

            if let engine = engines[route.id], engine.inputDevice == inID, engine.outputDevice == outID {
                engine.configure(route)
            } else {
                engines[route.id]?.stop()
                let engine = RouteEngine(inputDevice: inID, outputDevice: outID)
                do { try engine.start(route); engines[route.id] = engine }
                catch {
                    DispatchQueue.main.async { self.lastError = error.localizedDescription }
                }
            }
        }
    }

    func stopAll() {
        lock.lock(); defer { lock.unlock() }
        engines.values.forEach { $0.stop() }
        engines.removeAll()
    }
}

private final class RouteEngine {
    let inputDevice: AudioDeviceID
    let outputDevice: AudioDeviceID

    private let engine = AVAudioEngine()
    private let eq = AVAudioUnitEQ(numberOfBands: AudioEQ.bandCount)

    init(inputDevice: AudioDeviceID, outputDevice: AudioDeviceID) {
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice
        for (i, f) in AudioEQ.frequencies.enumerated() {
            let band = eq.bands[i]
            band.filterType = .parametric
            band.frequency = f
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = true
        }
    }

    func start(_ route: Route) throws {
        try setDevice(inputDevice, on: engine.inputNode.audioUnit, label: "input")
        try setDevice(outputDevice, on: engine.outputNode.audioUnit, label: "output")

        engine.attach(eq)
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.connect(engine.inputNode, to: eq, format: inputFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: inputFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode,
                       format: engine.outputNode.inputFormat(forBus: 0))
        configure(route)
        engine.prepare()
        try engine.start()
    }

    func configure(_ route: Route) {
        engine.mainMixerNode.outputVolume = route.isMuted ? 0 : Float(route.volume)
        eq.globalGain = route.isMuted ? -96 : AudioEQ.boostDecibels(route.boost)
        for (i, band) in eq.bands.enumerated() where i < route.eq.count {
            band.bypass = !route.eqEnabled
            band.gain = Float(route.eq[i])
        }
    }

    func stop() {
        engine.stop()
    }

    private func setDevice(_ device: AudioDeviceID, on unit: AudioUnit?, label: String) throws {
        guard let unit = unit else { throw Err.noUnit(label) }
        var dev = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &dev,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { throw Err.setDevice(label, status) }
    }

    private enum Err: LocalizedError {
        case noUnit(String), setDevice(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .noUnit(let l): return "Missing \(l) audio unit"
            case .setDevice(let l, let s): return "Could not set \(l) device (\(s))"
            }
        }
    }
}
