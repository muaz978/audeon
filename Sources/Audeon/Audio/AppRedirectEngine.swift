import Foundation
import CoreAudio
import Combine

/// Per-application volume and redirect settings, keyed by bundle id.
/// `outputUID == nil` means "follow the system default output".
struct AppRedirect: Codable, Equatable {
    var bundleID: String
    var outputUID: String?
    var volume: Double   // 0...1 (can exceed 1 later for boost)

    init(bundleID: String, outputUID: String? = nil, volume: Double = 1.0) {
        self.bundleID = bundleID
        self.outputUID = outputUID
        self.volume = volume
    }

    /// We only need to intercept an app's audio when it is not at full volume,
    /// or when it is being sent somewhere other than the system default.
    var isActive: Bool { outputUID != nil || volume < 0.999 }
}

/// Captures an app's audio with a Core Audio process tap and replays it to a
/// chosen output device at a chosen volume, muting the original so the result is
/// a true redirect. One tap + private aggregate device per active app.
final class AppRedirectEngine: ObservableObject {
    @Published private(set) var lastError: String?

    private let deviceManager: AudioDeviceManager
    private var units: [String: TapUnit] = [:]
    private let lock = NSLock()

    init(deviceManager: AudioDeviceManager) {
        self.deviceManager = deviceManager
    }

    /// Reconcile running taps with the desired redirects.
    func apply(redirects: [AppRedirect], apps: [AudioApp], defaultOutputUID: String?) {
        lock.lock(); defer { lock.unlock() }

        let appByBundle = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0) })

        // Determine the desired unit configuration per bundle id.
        struct Want { let process: AudioObjectID; let outputUID: String; let volume: Float }
        var wanted: [String: Want] = [:]
        for r in redirects where r.isActive {
            guard let app = appByBundle[r.bundleID],
                  let outUID = r.outputUID ?? defaultOutputUID,
                  deviceManager.deviceID(forUID: outUID) != nil else { continue }
            wanted[r.bundleID] = Want(process: app.processObject, outputUID: outUID, volume: Float(r.volume))
        }

        // Tear down units no longer wanted or whose target/process changed.
        for (bundle, unit) in units {
            if let w = wanted[bundle], w.process == unit.process, w.outputUID == unit.outputUID {
                unit.setVolume(w.volume)
            } else {
                unit.stop()
                units[bundle] = nil
            }
        }

        // Start units that are wanted but not yet running.
        for (bundle, w) in wanted where units[bundle] == nil {
            if let unit = TapUnit(process: w.process, outputUID: w.outputUID, volume: w.volume) {
                units[bundle] = unit
            } else {
                DispatchQueue.main.async { self.lastError = "Could not redirect \(bundle)" }
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
