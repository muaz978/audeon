import Foundation
import AVFoundation
import CoreAudio
import Combine

/// UID prefix for the private aggregate devices Audeon creates per app capture.
/// Used both to recognize and to hide them from the device lists.
let audeonAggregateUIDPrefix = "audeon.redirect."
let audeonAggregateName = "Audeon Redirect"

/// A request to send one app's audio to one output device with volume, boost,
/// and EQ.
struct AppTapRequest: Equatable {
    let bundleID: String
    let processObject: AudioObjectID
    let outputUID: String
    let volume: Float
    let boost: Double
    let eqEnabled: Bool
    let eq: [Double]
    let magicBoost: Bool
}

/// Captures an app's audio with a Core Audio process tap and replays it through
/// an AVAudioEngine (with EQ and boost) to a chosen output device, muting the
/// original. One tap + private aggregate device per (app, output) pair, so an
/// app can feed several outputs at once.
final class AppRedirectEngine: ObservableObject {
    @Published private(set) var lastError: String?
    /// Live meter per (bundleID, outputUID) key, same key as `units`.
    @Published private(set) var levels: [String: MeterReading] = [:]

    private let deviceManager: AudioDeviceManager
    private var units: [String: TapUnit] = [:]   // key: "bundleID|outputUID"
    private let lock = NSLock()

    init(deviceManager: AudioDeviceManager) {
        self.deviceManager = deviceManager
        Self.cleanupLeakedAggregates()
    }

    private func key(_ bundleID: String, _ outputUID: String) -> String { "\(bundleID)|\(outputUID)" }

    func apply(_ requests: [AppTapRequest]) {
        lock.lock(); defer { lock.unlock() }

        var wanted: [String: AppTapRequest] = [:]
        for r in requests where deviceManager.deviceID(forUID: r.outputUID) != nil {
            wanted[key(r.bundleID, r.outputUID)] = r
        }

        for (k, unit) in units {
            if let w = wanted[k], w.processObject == unit.process {
                unit.configure(volume: w.volume, boost: w.boost, eqEnabled: w.eqEnabled, eq: w.eq, magicBoost: w.magicBoost)
            } else {
                unit.stop(); units[k] = nil
                DispatchQueue.main.async { self.levels[k] = nil }
            }
        }

        for (k, w) in wanted where units[k] == nil {
            // Same hardware-level wake as the device router: an output that
            // has never been selected in System Settings can sit muted or at
            // 0% volume with nothing in Audeon having touched it.
            deviceManager.wakeOutputIfSilent(forUID: w.outputUID)

            if let unit = TapUnit(request: w, onLevel: { [weak self] reading in
                DispatchQueue.main.async { self?.levels[k] = reading }
            }) {
                units[k] = unit
            } else {
                DispatchQueue.main.async { self.lastError = "Could not capture \(w.bundleID)" }
            }
        }
    }

    func stopAll() {
        lock.lock(); defer { lock.unlock() }
        units.values.forEach { $0.stop() }
        units.removeAll()
        DispatchQueue.main.async { self.levels.removeAll() }
    }

    /// Destroy any private aggregate devices left behind by a previous run.
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
            if st == noErr, let uid = v as String?, uid.hasPrefix(audeonAggregateUIDPrefix) {
                AudioHardwareDestroyAggregateDevice(id)
            }
        }
    }
}

// MARK: - One tapped app

private final class TapUnit {
    let process: AudioObjectID

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private let engine = AVAudioEngine()
    private let eq = AVAudioUnitEQ(numberOfBands: AudioEQ.bandCount)
    private let magicBoost = MagicBoost.makeEffect()
    private var started = false
    private let onLevel: (MeterReading) -> Void
    private let throttle = MeterThrottle()

    init?(request: AppTapRequest, onLevel: @escaping (MeterReading) -> Void) {
        self.process = request.processObject
        self.onLevel = onLevel

        guard #available(macOS 14.2, *) else { cleanup(); return nil }

        let desc = CATapDescription(stereoMixdownOfProcesses: [request.processObject])
        desc.muteBehavior = .muted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr, tapID != 0 else { cleanup(); return nil }
        guard let tapUID = Self.cfString(tapID, kAudioTapPropertyUID) else { cleanup(); return nil }

        let aggUID = "\(audeonAggregateUIDPrefix)\(request.processObject).\(UInt32.random(in: 1...UInt32.max))"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: audeonAggregateName,
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMainSubDeviceKey as String: request.outputUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: request.outputUID]],
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapDriftCompensationKey as String: 1,
                kAudioSubTapUIDKey as String: tapUID
            ]]
        ]
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID) == noErr,
              aggregateID != 0 else { cleanup(); return nil }

        // Bind the engine's input and output to the aggregate (tap in, device out).
        guard Self.setDevice(engine.inputNode.audioUnit, aggregateID) == noErr,
              Self.setDevice(engine.outputNode.audioUnit, aggregateID) == noErr else { cleanup(); return nil }

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
        let fmt = engine.inputNode.outputFormat(forBus: 0)
        engine.connect(engine.inputNode, to: eq, format: fmt)
        engine.connect(eq, to: magicBoost, format: fmt)
        engine.connect(magicBoost, to: engine.mainMixerNode, format: fmt)
        engine.connect(engine.mainMixerNode, to: engine.outputNode,
                       format: engine.outputNode.inputFormat(forBus: 0))
        configure(volume: request.volume, boost: request.boost, eqEnabled: request.eqEnabled,
                 eq: request.eq, magicBoost: request.magicBoost)

        let onLevel = self.onLevel
        let throttle = self.throttle
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024,
                                        format: engine.mainMixerNode.outputFormat(forBus: 0)) { buffer, _ in
            guard throttle.shouldFire() else { return }
            onLevel(AudioMeter.reading(for: buffer))
        }

        do { engine.prepare(); try engine.start(); started = true }
        catch { cleanup(); return nil }
    }

    func configure(volume: Float, boost: Double, eqEnabled: Bool, eq gains: [Double], magicBoost magicBoostEnabled: Bool) {
        engine.mainMixerNode.outputVolume = volume
        eq.globalGain = volume <= 0 ? -96 : AudioEQ.boostDecibels(boost)
        for (i, band) in eq.bands.enumerated() where i < gains.count {
            band.bypass = !eqEnabled
            band.gain = Float(gains[i])
        }
        MagicBoost.configure(magicBoost, enabled: magicBoostEnabled)
    }

    func stop() { cleanup() }

    private func cleanup() {
        if started { engine.mainMixerNode.removeTap(onBus: 0); engine.stop(); started = false }
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = 0
        }
    }

    private static func setDevice(_ unit: AudioUnit?, _ dev: AudioObjectID) -> OSStatus {
        guard let unit = unit else { return -1 }
        var d = dev
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &d,
                                    UInt32(MemoryLayout<AudioObjectID>.size))
    }

    private static func cfString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var v: CFString? = nil
        let s = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
        guard s == noErr, let v = v else { return nil }
        return v as String
    }
}
