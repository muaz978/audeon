import Foundation
import AVFoundation
import CoreAudio
import Combine

/// UID prefix for the private aggregate devices Audeon creates for cross-device
/// routes. Shares the naming convention with the per-app redirect aggregates so
/// both are recognized and hidden from device pickers, and cleaned up on launch.
let audeonRouteAggregateUIDPrefix = "audeon.route."

/// Routes device sources to output devices.
///
/// Important: on macOS, AVAudioEngine.inputNode and .outputNode share ONE
/// underlying Audio Unit. Pointing that single unit at two different physical
/// devices (one call to set the input device, a second to set the output
/// device) does not create a real input-to-output route: the second call wins
/// for both directions. The correct technique, used here and already proven by
/// the per-app capture engine, is to combine the two real devices into one
/// private aggregate device (with drift compensation, since they are
/// independent hardware clocks) and bind the engine's single shared unit to
/// that one aggregate. The aggregate's input side carries the input device's
/// channels and its output side carries the output device's channels.
final class AudioRouter: ObservableObject {
    @Published private(set) var lastError: String?
    /// Live meter per route id (same id as the connection it came from).
    @Published private(set) var levels: [UUID: MeterReading] = [:]

    private let deviceManager: AudioDeviceManager
    private var engines: [UUID: RouteEngine] = [:]
    private let lock = NSLock()

    init(deviceManager: AudioDeviceManager) {
        self.deviceManager = deviceManager
        Self.cleanupLeakedAggregates()
    }

    func apply(routes: [Route]) {
        lock.lock(); defer { lock.unlock() }

        let wanted = Set(routes.map(\.id))
        for (id, engine) in engines where !wanted.contains(id) {
            engine.stop(); engines[id] = nil
            DispatchQueue.main.async { self.levels[id] = nil }
        }

        for route in routes {
            guard let inID = deviceManager.deviceID(forUID: route.inputDeviceUID),
                  let outID = deviceManager.deviceID(forUID: route.outputDeviceUID) else { continue }

            if let engine = engines[route.id],
               engine.inputDeviceUID == route.inputDeviceUID, engine.outputDeviceUID == route.outputDeviceUID {
                engine.configure(route)
            } else {
                engines[route.id]?.stop()
                let id = route.id
                let engine = RouteEngine(
                    inputDeviceUID: route.inputDeviceUID, inputDeviceID: inID,
                    outputDeviceUID: route.outputDeviceUID, outputDeviceID: outID,
                    onLevel: { [weak self] reading in
                        DispatchQueue.main.async { self?.levels[id] = reading }
                    })
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
        DispatchQueue.main.async { self.levels.removeAll() }
    }

    /// Destroy any private route aggregates left behind by a previous run.
    static func cleanupLeakedAggregates() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return }
        for id in ids {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var s = UInt32(MemoryLayout<CFString?>.size)
            var v: CFString? = nil
            let st = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &s, $0) }
            if st == noErr, let uid = v as String?, uid.hasPrefix(audeonRouteAggregateUIDPrefix) {
                AudioHardwareDestroyAggregateDevice(id)
            }
        }
    }
}

private final class RouteEngine {
    let inputDeviceUID: String
    let outputDeviceUID: String
    private let inputDeviceID: AudioDeviceID
    private let outputDeviceID: AudioDeviceID

    private let engine = AVAudioEngine()
    private let eq = AVAudioUnitEQ(numberOfBands: AudioEQ.bandCount)
    private let magicBoost = MagicBoost.makeEffect()
    private let onLevel: (MeterReading) -> Void
    private let throttle = MeterThrottle()
    private var aggregateID: AudioObjectID = 0
    private var started = false

    init(inputDeviceUID: String, inputDeviceID: AudioDeviceID,
         outputDeviceUID: String, outputDeviceID: AudioDeviceID,
         onLevel: @escaping (MeterReading) -> Void) {
        self.inputDeviceUID = inputDeviceUID
        self.inputDeviceID = inputDeviceID
        self.outputDeviceUID = outputDeviceUID
        self.outputDeviceID = outputDeviceID
        self.onLevel = onLevel
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
        // Input and output device are the same hardware: bind directly, no
        // aggregate needed, and no cross-clock drift to compensate for.
        if inputDeviceUID == outputDeviceUID {
            try bind(inputDeviceID)
        } else {
            try createAndBindAggregate()
        }

        engine.attach(eq)
        engine.attach(magicBoost)
        // Use the engine's own format queries (not a manually built format from
        // a raw hardware ASBD: AVAudioEngine.connect rejects formats it did not
        // derive itself and can throw an Objective-C exception when given one).
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)

        engine.connect(engine.inputNode, to: eq, format: inputFormat)
        engine.connect(eq, to: magicBoost, format: inputFormat)
        engine.connect(magicBoost, to: engine.mainMixerNode, format: inputFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
        configure(route)

        // Meter the final mixed signal (post EQ, boost, and volume).
        let onLevel = self.onLevel
        let throttle = self.throttle
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024,
                                        format: engine.mainMixerNode.outputFormat(forBus: 0)) { buffer, _ in
            guard throttle.shouldFire() else { return }
            onLevel(AudioMeter.reading(for: buffer))
        }

        engine.prepare()
        try engine.start()
        started = true
    }

    func configure(_ route: Route) {
        engine.mainMixerNode.outputVolume = route.isMuted ? 0 : Float(route.volume)
        eq.globalGain = route.isMuted ? -96 : AudioEQ.boostDecibels(route.boost)
        for (i, band) in eq.bands.enumerated() where i < route.eq.count {
            band.bypass = !route.eqEnabled
            band.gain = Float(route.eq[i])
        }
        MagicBoost.configure(magicBoost, enabled: route.magicBoost)
    }

    func stop() {
        if started { engine.mainMixerNode.removeTap(onBus: 0); engine.stop(); started = false }
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
    }

    // MARK: - Device binding

    private func bind(_ device: AudioDeviceID) throws {
        try setDevice(device, on: engine.inputNode.audioUnit, label: "device")
        engine.reset()
    }

    private func createAndBindAggregate() throws {
        let aggUID = "\(audeonRouteAggregateUIDPrefix)\(UUID().uuidString)"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Audeon Route",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputDeviceUID,
                 kAudioSubDeviceDriftCompensationKey as String: 1],
                [kAudioSubDeviceUIDKey as String: inputDeviceUID,
                 kAudioSubDeviceDriftCompensationKey as String: 1]
            ]
        ]
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID) == noErr,
              aggregateID != 0 else { throw Err.aggregateCreate }
        // Give CoreAudio a moment to settle the aggregate's derived clock and
        // stream formats before any unit binds to it.
        Thread.sleep(forTimeInterval: 0.05)
        try setDevice(aggregateID, on: engine.inputNode.audioUnit, label: "aggregate")
        engine.reset()
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
        case noUnit(String), setDevice(String, OSStatus), aggregateCreate
        var errorDescription: String? {
            switch self {
            case .noUnit(let l): return "Missing \(l) audio unit"
            case .setDevice(let l, let s): return "Could not set \(l) device (\(s))"
            case .aggregateCreate: return "Could not create the routing aggregate device"
            }
        }
    }
}
