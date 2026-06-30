import Foundation
import AVFoundation
import CoreAudio
import Combine

/// The live audio engine. One `AVAudioEngine` is created per active route:
///   input device  ->  mainMixer (gain)  ->  output device
///
/// Running one engine per route keeps the model simple and gives true N x M
/// routing of physical devices: the same input can feed several outputs (one
/// engine each), and one output can be fed by several inputs. The mainMixer
/// node performs any sample-rate conversion between mismatched devices.
///
/// What this engine does NOT do yet (documented roadmap, see README):
///   - per-application capture (Core Audio process taps, macOS 14.2+)
///   - presenting Audeon itself as a virtual device for OBS (BlackHole /
///     a bundled AudioServerPlugIn)
/// A single meter sample for one route.
struct MeterReading: Equatable {
    var level: Float    // 0...1, normalized from dBFS for the meter bar
    var peakDB: Float   // peak in dBFS, e.g. -12.3
    var clip: Bool      // true when the signal hit or passed full scale

    static let silent = MeterReading(level: 0, peakDB: -120, clip: false)
}

final class AudioRouter: ObservableObject {

    /// Live meter reading per route id, for the UI.
    @Published private(set) var levels: [UUID: MeterReading] = [:]
    @Published private(set) var lastError: String?

    private let deviceManager: AudioDeviceManager
    private var engines: [UUID: RouteEngine] = [:]
    private let lock = NSLock()

    init(deviceManager: AudioDeviceManager) {
        self.deviceManager = deviceManager
    }

    /// Reconcile running engines with the desired set of routes.
    /// Starts new routes, stops removed ones, and pushes gain/mute updates.
    func apply(routes: [Route]) {
        lock.lock(); defer { lock.unlock() }

        let wanted = Set(routes.map(\.id))

        // Tear down routes that are gone or disabled.
        for (id, engine) in engines where !wanted.contains(id) {
            engine.stop()
            engines[id] = nil
            DispatchQueue.main.async { self.levels[id] = nil }
        }

        // Solo logic: if any route is soloed, only soloed routes pass audio.
        let anySolo = routes.contains { $0.isSoloed && !$0.isMuted }

        for route in routes {
            let gain = Self.gain(for: route, anySolo: anySolo)
            if let engine = engines[route.id] {
                engine.update(volume: gain)
            } else {
                start(route, gain: gain)
            }
        }
    }

    /// Engine gain for a route, accounting for mute and global solo state.
    private static func gain(for route: Route, anySolo: Bool) -> Float {
        if route.isMuted { return 0 }
        if anySolo && !route.isSoloed { return 0 }
        return Float(route.volume)
    }

    func stopAll() {
        lock.lock(); defer { lock.unlock() }
        engines.values.forEach { $0.stop() }
        engines.removeAll()
        DispatchQueue.main.async { self.levels = [:] }
    }

    private func start(_ route: Route, gain: Float) {
        guard let inID = deviceManager.deviceID(forUID: route.inputDeviceUID),
              let outID = deviceManager.deviceID(forUID: route.outputDeviceUID) else {
            return
        }
        let engine = RouteEngine(routeID: route.id, inputDevice: inID, outputDevice: outID) { [weak self] id, reading in
            DispatchQueue.main.async { self?.levels[id] = reading }
        }
        do {
            try engine.start(volume: gain)
            engines[route.id] = engine
        } catch {
            DispatchQueue.main.async {
                self.lastError = "Route \(route.inputUID) to \(route.outputUID) failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - One route = one engine

private final class RouteEngine {
    let routeID: UUID
    private let engine = AVAudioEngine()
    private let onLevel: (UUID, MeterReading) -> Void
    private let inputDevice: AudioDeviceID
    private let outputDevice: AudioDeviceID

    init(routeID: UUID,
         inputDevice: AudioDeviceID,
         outputDevice: AudioDeviceID,
         onLevel: @escaping (UUID, MeterReading) -> Void) {
        self.routeID = routeID
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice
        self.onLevel = onLevel
    }

    func start(volume: Float) throws {
        // Bind the input and output HAL units to the chosen physical devices.
        // This must happen before reading node formats or starting the engine.
        try setDevice(inputDevice, on: engine.inputNode.audioUnit, label: "input")
        try setDevice(outputDevice, on: engine.outputNode.audioUnit, label: "output")

        let mixer = engine.mainMixerNode
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)

        engine.connect(engine.inputNode, to: mixer, format: inputFormat)
        engine.connect(mixer, to: engine.outputNode, format: mixer.outputFormat(forBus: 0))
        mixer.outputVolume = volume

        installMeter(on: mixer)

        engine.prepare()
        try engine.start()
    }

    func update(volume: Float) {
        engine.mainMixerNode.outputVolume = volume
    }

    func stop() {
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func setDevice(_ device: AudioDeviceID, on unit: AudioUnit?, label: String) throws {
        guard let unit = unit else {
            throw RouterError.noAudioUnit(label)
        }
        var dev = device
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw RouterError.setDeviceFailed(label, status)
        }
    }

    private func installMeter(on node: AVAudioNode) {
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            guard frames > 0, channels > 0 else { return }

            var sumSquares: Float = 0
            var peak: Float = 0
            for ch in 0..<channels {
                let samples = data[ch]
                for i in 0..<frames {
                    let s = samples[i]
                    sumSquares += s * s
                    let a = abs(s)
                    if a > peak { peak = a }
                }
            }
            let rms = sqrt(sumSquares / Float(frames * channels))

            // Convert to dBFS and normalize a -60...0 dB window to a 0...1 bar.
            let floorDB: Float = -60
            let rmsDB = rms > 0 ? 20 * log10(rms) : floorDB
            let peakDB = peak > 0 ? 20 * log10(peak) : floorDB
            let level = min(1, max(0, (rmsDB - floorDB) / -floorDB))
            let clip = peak >= 0.999

            self.onLevel(self.routeID, MeterReading(level: level, peakDB: max(floorDB, peakDB), clip: clip))
        }
    }
}

private enum RouterError: LocalizedError {
    case noAudioUnit(String)
    case setDeviceFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noAudioUnit(let label):
            return "Missing \(label) audio unit"
        case .setDeviceFailed(let label, let status):
            return "Could not set \(label) device (OSStatus \(status))"
        }
    }
}
