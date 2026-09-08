import Foundation
import AVFoundation
import CoreAudio
import Combine
import os

/// UID prefix for the private aggregate devices Audeon creates per app capture.
/// Used both to recognize and to hide them from the device lists.
let audeonAggregateUIDPrefix = "audeon.redirect."
let audeonAggregateName = "Audeon Redirect"

/// A request to send one app's audio to one output device with volume, boost,
/// and EQ.
struct AppTapRequest: Equatable {
    let bundleID: String
    let processObjects: [AudioObjectID]   // all audio processes owned by the app
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
///
/// Concurrency: `@unchecked Sendable`, on the same audit as its sibling
/// `AudioRouter`. Field by field:
///
/// - `lastError`, `levels`: main thread only. Both are written exclusively
///   inside `DispatchQueue.main.async` blocks, or by `drainLevels()`, which
///   runs on a timer scheduled on `.main`, and both are read only from
///   `MixerStore` and the views, which are `@MainActor`.
/// - `deviceManager`: a `let` of a type that is itself `@unchecked Sendable`
///   under its own audit. The two methods `applyOnWorker` calls on it off the
///   main thread, `deviceID(forUID:)` and `wakeOutputIfSilent(forUID:)`, reach
///   only its `mapLock`-guarded uid map and stateless CoreAudio property calls.
/// - `failures`: confined to `work`. `applyOnWorker` is the only thing that
///   touches it and the only thing that runs on that serial queue, so the queue
///   is the mutual exclusion.
/// - `pendingLevels`, `liveKeys`: guarded by `meterLock`, at every access. The
///   tap callbacks only ever `trylock` it, so contention costs a meter frame
///   rather than a realtime deadline.
/// - `meterPump`: main thread only. `syncMeterPump(hasUnits:)` is its sole
///   mutator and is called from exactly one place, inside a
///   `DispatchQueue.main.async`.
/// - `lock`, `meterLock`, `work`: immutable, and `NSLock`, a pointer and a
///   `DispatchQueue` are all Sendable.
/// - `units`: guarded by `lock` at every access, all ten of them. The last
///   holdout was the "which outgoing taps are still playing" loop at the end
///   of `applyOnWorker`, which read the dictionary bare; it now takes its
///   snapshot under the lock and logs from that.
///
/// That read was not a live data race even before the fix, and the reason it
/// was not is why it was worth fixing rather than annotating around.
/// `applyOnWorker` is serial with itself, so the only writer that could have
/// run alongside it is `stopAll()`, and `stopAll()` could not: both it and
/// `apply()` are called only from `MixerStore` and the tests, which are
/// `@MainActor`, so the main thread is inside `stopAll()` when it drains the
/// queue and nothing can enqueue past it. The safety rested on an invariant
/// held in another file, about which threads call this one — and `Sendable` is
/// precisely the promise that no such invariant is needed. Conforming with the
/// bare read still in place would have let a `stopAll()` be called from any
/// thread with no diagnostic, putting `units.removeAll()` next to an unguarded
/// dictionary read: a lower warning count bought by discarding the only thing
/// the warning was protecting.
final class AppRedirectEngine: ObservableObject, @unchecked Sendable {
    @Published private(set) var lastError: String?
    /// Live meter per (bundleID, outputUID) key, same key as `units`.
    @Published private(set) var levels: [String: MeterReading] = [:]

    private let deviceManager: AudioDeviceManager
    private var units: [String: TapUnit] = [:]   // key: "bundleID|outputUID"
    private let lock = NSLock()

    /// Keys whose tap could not be created, with the process set that failed
    /// and when it may be retried. Without this, a tap that can never be
    /// created was retried on every single graph mutation, and each attempt
    /// rewrote the target device's hardware mute and volume.
    private var failures: [String: (processes: Set<AudioObjectID>, retryAfter: Date, attempts: Int)] = [:]

    /// Serialises tap construction and teardown, keeping those HAL calls off
    /// the main thread.
    private let work = DispatchQueue(label: "com.audeon.redirect.apply", qos: .userInitiated)

    /// Meter readings staged by the tap callbacks and drained on the main
    /// thread at a fixed rate, rather than one dispatch block per firing.
    private var pendingLevels: [String: MeterReading] = [:]
    private var liveKeys: Set<String> = []
    private let meterLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var meterPump: DispatchSourceTimer?

    init(deviceManager: AudioDeviceManager) {
        self.deviceManager = deviceManager
        meterLock.initialize(to: os_unfair_lock())
        Self.cleanupLeakedAggregates()
    }

    deinit {
        meterPump?.cancel()
        meterLock.deinitialize(count: 1)
        meterLock.deallocate()
    }

    private func key(_ bundleID: String, _ outputUID: String) -> String { "\(bundleID)|\(outputUID)" }

    /// Reconcile the live capture units against the wanted taps.
    ///
    /// Returns immediately. Creating a process tap and its private aggregate,
    /// and destroying them again, are blocking HAL calls that used to run on
    /// the main thread — so every change to a redirected app froze the UI. The
    /// work now runs on a serial queue, and the units lock is held only across
    /// dictionary operations, never across a HAL call.
    func apply(_ requests: [AppTapRequest]) {
        work.async { [weak self] in self?.applyOnWorker(requests) }
    }

    private func applyOnWorker(_ requests: [AppTapRequest]) {
        // A new reconciliation supersedes any previous failure. Without this,
        // one stale error banner stayed on screen forever.
        DispatchQueue.main.async { if self.lastError != nil { self.lastError = nil } }

        var wanted: [String: AppTapRequest] = [:]
        for r in requests where deviceManager.deviceID(forUID: r.outputUID) != nil {
            wanted[key(r.bundleID, r.outputUID)] = r
        }

        // Take the doomed units out under the lock, stop them outside it.
        // Process sets are compared as sets: re-enumerating a multi-process app
        // (Chrome, Edge) returns the same processes in a different order, and
        // treating that as a change tore the tap down and rebuilt it, dropping
        // audio and briefly unmuting the app's own output.
        // Three outcomes, not two. A unit whose key nobody wants any more is
        // retired immediately. A unit that needs rebuilding — usually because
        // the app gained or lost an audio process — is left running until its
        // replacement has been built, so the app keeps playing meanwhile.
        var retired: [(String, TapUnit)] = []
        var outgoing: [String: TapUnit] = [:]
        var survivors: [String: TapUnit] = [:]
        lock.lock()
        for (k, unit) in units {
            if let w = wanted[k], unit.isHealthy, Set(w.processObjects) == Set(unit.processes) {
                survivors[k] = unit
            } else if wanted[k] != nil {
                outgoing[k] = unit          // stays in `units`, and stays playing
            } else {
                retired.append((k, unit))
                units[k] = nil
            }
        }
        lock.unlock()

        for (k, unit) in retired {
            unit.stop()
            DispatchQueue.main.async { self.levels[k] = nil }
        }
        for (k, unit) in survivors {
            guard let w = wanted[k] else { continue }
            unit.configure(volume: w.volume, boost: w.boost, eqEnabled: w.eqEnabled,
                           eq: w.eq, magicBoost: w.magicBoost)
        }

        let now = Date()
        for (k, w) in wanted where survivors[k] == nil {
            // Back off from a tap that keeps failing. A changed process set
            // means it is worth trying again straight away.
            if let failure = failures[k] {
                if failure.processes != Set(w.processObjects) {
                    failures[k] = nil
                } else if now < failure.retryAfter {
                    continue
                }
            }

            // Same hardware-level wake as the device router: an output that
            // has never been selected in System Settings can sit muted or at
            // 0% volume with nothing in Audeon having touched it. Only on a
            // first attempt -- repeating it on every retry is what let a
            // failing tap keep overwriting the user's volume.
            if failures[k] == nil { deviceManager.wakeOutputIfSilent(forUID: w.outputUID) }

            if let unit = TapUnit(request: w, onLevel: { [weak self] reading in
                self?.record(reading, for: k)
            }) {
                // Everything expensive is done and the outgoing unit has been
                // playing throughout. Only the engine start sits between the
                // two, instead of a whole teardown and rebuild. The incoming
                // tap is already muting the app, so its own output never
                // briefly unmutes during the swap either.
                outgoing.removeValue(forKey: k)?.stop()
                if unit.start() {
                    lock.lock(); units[k] = unit; lock.unlock()
                    failures[k] = nil
                    continue
                }
                unit.stop()
                lock.lock(); units[k] = nil; lock.unlock()
                let attempts = (failures[k]?.attempts ?? 0) + 1
                let delay = min(pow(4.0, Double(attempts - 1)) * 2.0, 120.0)
                failures[k] = (Set(w.processObjects), now.addingTimeInterval(delay), attempts)
                DispatchQueue.main.async { self.lastError = "Could not capture \(w.bundleID)" }
            } else {
                let attempts = (failures[k]?.attempts ?? 0) + 1
                // 2 s, 8 s, 32 s, capped at 2 minutes.
                let delay = min(pow(4.0, Double(attempts - 1)) * 2.0, 120.0)
                failures[k] = (Set(w.processObjects), now.addingTimeInterval(delay), attempts)
                DispatchQueue.main.async { self.lastError = "Could not capture \(w.bundleID)" }
            }
        }

        // A unit whose replacement could not be built keeps running rather than
        // being stopped. Its process set is stale, but stale audio beats none,
        // and the backoff above governs when the rebuild is retried.
        lock.lock()
        let kept = outgoing.filter { units[$0.key] === $0.value }.keys.sorted()
        lock.unlock()
        for k in kept {
            NSLog("Audeon.route: keeping the existing tap for \(k); its replacement could not be built")
        }

        // Forget failures for taps nobody wants any more.
        for k in failures.keys where wanted[k] == nil { failures[k] = nil }

        publishLiveUnits()
    }

    /// Meter readings are staged and drained on a timer rather than dispatched
    /// per callback. Mirrors AudioRouter.
    private func record(_ reading: MeterReading, for key: String) {
        guard os_unfair_lock_trylock(meterLock) else { return }
        pendingLevels[key] = reading
        os_unfair_lock_unlock(meterLock)
    }

    private func publishLiveUnits() {
        lock.lock(); let keys = Set(units.keys); lock.unlock()
        os_unfair_lock_lock(meterLock)
        liveKeys = keys
        os_unfair_lock_unlock(meterLock)
        DispatchQueue.main.async { self.syncMeterPump(hasUnits: !keys.isEmpty) }
    }

    private func syncMeterPump(hasUnits: Bool) {
        if !hasUnits {
            meterPump?.cancel()
            meterPump = nil
            return
        }
        guard meterPump == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.033, repeating: 0.033, leeway: .milliseconds(8))
        timer.setEventHandler { [weak self] in self?.drainLevels() }
        timer.resume()
        meterPump = timer
    }

    private func drainLevels() {
        os_unfair_lock_lock(meterLock)
        let batch = pendingLevels
        let live = liveKeys
        pendingLevels.removeAll(keepingCapacity: true)
        os_unfair_lock_unlock(meterLock)
        for (k, reading) in batch where live.contains(k) { levels[k] = reading }
    }

    /// Synchronous by design: callers sequence cleanup work immediately after
    /// it, and a queued reconciliation must not resurrect units they just
    /// stopped.
    func stopAll() {
        work.sync {}
        lock.lock()
        let all = Array(units.values)
        units.removeAll()
        lock.unlock()
        all.forEach { $0.stop() }
        publishLiveUnits()
        DispatchQueue.main.async { self.levels.removeAll() }
    }

    /// True when a capture unit for this app and output exists *and its engine
    /// is running*. The health check is the point: a unit that was constructed
    /// but never started still sits in the map, so testing only for presence
    /// would pass while no audio flows at all.
    func hasLiveUnit(bundleID: String, outputUID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return units[key(bundleID, outputUID)]?.isHealthy ?? false
    }

    /// Attach or detach a recorder on a live capture unit. The key is the same
    /// "bundleID|outputUID" used internally by apply().
    func setRecorder(bundleID: String, outputUID: String, _ recorder: MixRecorder?) {
        lock.lock(); defer { lock.unlock() }
        units[key(bundleID, outputUID)]?.recorderSlot.set(recorder)
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
    let processes: [AudioObjectID]
    private let bundleID: String
    private let outputUID: String
    let recorderSlot = RecorderSlot()

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private let engine = AVAudioEngine()
    private let eq = AVAudioUnitEQ(numberOfBands: AudioEQ.bandCount)
    private let magicBoost = MagicBoost.makeEffect()
    private var started = false
    private let onLevel: (MeterReading) -> Void
    private let throttle = MeterThrottle()

    /// False once AVAudioEngine has stopped underneath us — which it does on a
    /// configuration change. A dead unit left mounted kept the process tap
    /// alive, so the app stayed muted on its own output and silent everywhere.
    var isHealthy: Bool { started && engine.isRunning }

    init?(request: AppTapRequest, onLevel: @escaping (MeterReading) -> Void) {
        self.processes = request.processObjects
        self.bundleID = request.bundleID
        self.outputUID = request.outputUID
        self.onLevel = onLevel

        guard #available(macOS 14.2, *) else {
            NSLog("Audeon.route: tap unavailable, needs macOS 14.2+ (\(request.bundleID))")
            cleanup(); return nil
        }
        guard !request.processObjects.isEmpty else {
            NSLog("Audeon.route: no audio processes yet for \(request.bundleID); waiting for it to play")
            cleanup(); return nil
        }

        // Tap every audio process the app owns (all of a browser's tabs), mixed
        // down together, so nothing the app plays is missed.
        let desc = CATapDescription(stereoMixdownOfProcesses: request.processObjects)
        desc.muteBehavior = .muted
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
        guard tapStatus == noErr, tapID != 0 else {
            NSLog("Audeon.route: process tap create failed for \(request.bundleID) (status \(tapStatus))")
            cleanup(); return nil
        }
        guard let tapUID = Self.cfString(tapID, kAudioTapPropertyUID) else {
            NSLog("Audeon.route: could not read tap UID for \(request.bundleID)")
            cleanup(); return nil
        }

        let aggUID = "\(audeonAggregateUIDPrefix)\(request.processObjects.first ?? 0).\(UInt32.random(in: 1...UInt32.max))"
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
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
        guard aggStatus == noErr, aggregateID != 0 else {
            NSLog("Audeon.route: aggregate create failed for \(request.bundleID) -> \(request.outputUID) (status \(aggStatus))")
            cleanup(); return nil
        }

        // Bind the engine's input and output to the aggregate (tap in, device out).
        let bindIn = Self.setDevice(engine.inputNode.audioUnit, aggregateID)
        let bindOut = Self.setDevice(engine.outputNode.audioUnit, aggregateID)
        guard bindIn == noErr, bindOut == noErr else {
            NSLog("Audeon.route: engine bind failed for \(request.bundleID) (in \(bindIn), out \(bindOut))")
            cleanup(); return nil
        }

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
        let slot = self.recorderSlot
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024,
                                        format: engine.mainMixerNode.outputFormat(forBus: 0)) { buffer, _ in
            slot.acquire()?.append(buffer)
            guard throttle.shouldFire() else { return }
            onLevel(AudioMeter.reading(for: buffer))
        }

        engine.prepare()
    }

    /// Begin passing audio. Split from `init` so a replacement unit can be
    /// built while the unit it replaces is still playing: everything expensive
    /// — creating the process tap, creating the private aggregate, wiring the
    /// engine — happens during construction, leaving only this call between the
    /// outgoing unit stopping and the incoming one taking over.
    func start() -> Bool {
        guard !started else { return true }
        let inFmt = engine.inputNode.outputFormat(forBus: 0)
        let outFmt = engine.outputNode.inputFormat(forBus: 0)
        do {
            try engine.start()
            started = true
            NSLog("Audeon.route: STARTED app tap \(bundleID) -> \(outputUID) | in \(Int(inFmt.channelCount))ch@\(Int(inFmt.sampleRate)) out \(Int(outFmt.channelCount))ch@\(Int(outFmt.sampleRate))")
            return true
        } catch {
            // Previously this error was swallowed silently, so a route that
            // failed to start just vanished and the app appeared to "only route
            // to the default output". Surface it instead.
            NSLog("Audeon.route: FAILED app tap \(bundleID) -> \(outputUID): \(error) | in \(Int(inFmt.channelCount))ch out \(Int(outFmt.channelCount))ch")
            return false
        }
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
