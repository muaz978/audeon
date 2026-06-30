import Foundation
import CoreAudio
import Combine

/// A request to send one app's audio to one output device at a given volume.
struct AppTapRequest: Equatable {
    let bundleID: String
    let processObject: AudioObjectID
    let outputUID: String
    let volume: Float
}

/// Captures an app's audio with a Core Audio process tap and replays it to a
/// chosen output device at a chosen volume, muting the original so the result is
/// a true redirect. One tap + private aggregate device per (app, output) pair,
/// so a single app can feed several outputs at once.
final class AppRedirectEngine: ObservableObject {
    @Published private(set) var lastError: String?

    private let deviceManager: AudioDeviceManager
    private var units: [String: TapUnit] = [:]   // key: "bundleID|outputUID"
    private let lock = NSLock()

    init(deviceManager: AudioDeviceManager) {
        self.deviceManager = deviceManager
    }

    private func key(_ bundleID: String, _ outputUID: String) -> String { "\(bundleID)|\(outputUID)" }

    /// Reconcile running taps with the desired set of app connections.
    func apply(_ requests: [AppTapRequest]) {
        lock.lock(); defer { lock.unlock() }

        var wanted: [String: AppTapRequest] = [:]
        for r in requests where deviceManager.deviceID(forUID: r.outputUID) != nil {
            wanted[key(r.bundleID, r.outputUID)] = r
        }

        // Tear down units no longer wanted or whose process changed.
        for (k, unit) in units {
            if let w = wanted[k], w.processObject == unit.process {
                unit.setVolume(w.volume)
            } else {
                unit.stop()
                units[k] = nil
            }
        }

        // Start units that are wanted but not yet running.
        for (k, w) in wanted where units[k] == nil {
            if let unit = TapUnit(process: w.processObject, outputUID: w.outputUID, volume: w.volume) {
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
    }
}

// MARK: - One tapped app

private final class TapUnit {
    let process: AudioObjectID
    let outputUID: String

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private let gain = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    init?(process: AudioObjectID, outputUID: String, volume: Float) {
        self.process = process
        self.outputUID = outputUID
        gain.initialize(to: volume)

        // Process taps require macOS 14.2+. On older systems this redirect is
        // simply unavailable and the app's audio keeps using its normal output.
        guard #available(macOS 14.2, *) else { cleanup(); return nil }

        // 1. Tap the process, muting its normal output so we can replace it.
        let desc = CATapDescription(stereoMixdownOfProcesses: [process])
        desc.muteBehavior = .muted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr, tapID != 0 else {
            cleanup(); return nil
        }
        guard let tapUID = Self.cfString(tapID, kAudioTapPropertyUID) else { cleanup(); return nil }

        // 2. Private aggregate device: the chosen output device + this tap.
        let aggUID = "audeon.redirect.\(process).\(UInt32.random(in: 1...UInt32.max))"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Audeon Redirect",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: outputUID]],
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapDriftCompensationKey as String: 1,
                kAudioSubTapUIDKey as String: tapUID
            ]]
        ]
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID) == noErr,
              aggregateID != 0 else { cleanup(); return nil }

        // 3. Realtime passthrough with gain.
        let gainPtr = gain
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            (_, inInput, _, outOutput, _) in
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            let output = UnsafeMutableAudioBufferListPointer(outOutput)
            let g = gainPtr.pointee
            for i in 0..<min(input.count, output.count) {
                guard let src = input[i].mData, let dst = output[i].mData else { continue }
                let bytes = Int(min(input[i].mDataByteSize, output[i].mDataByteSize))
                let count = bytes / MemoryLayout<Float>.size
                let s = src.assumingMemoryBound(to: Float.self)
                let d = dst.assumingMemoryBound(to: Float.self)
                for k in 0..<count { d[k] = s[k] * g }
            }
        }
        guard status == noErr, let procID = procID else { cleanup(); return nil }
        guard AudioDeviceStart(aggregateID, procID) == noErr else { cleanup(); return nil }
    }

    func setVolume(_ v: Float) { gain.pointee = v }

    func stop() { cleanup() }

    deinit { gain.deallocate() }

    private func cleanup() {
        if let p = procID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
        }
        procID = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = 0
        }
    }

    private static func cfString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var v: CFString? = nil
        let s = withUnsafeMutablePointer(to: &v) {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
        }
        guard s == noErr, let v = v else { return nil }
        return v as String
    }
}
