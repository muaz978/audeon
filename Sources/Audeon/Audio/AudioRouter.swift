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
/// Two engines, chosen per route:
///
/// - Same device on both ends: an AVAudioEngine bound directly to it, with the
///   full DSP chain (EQ, overdrive, Magic Boost).
/// - Two different devices: a private aggregate combining them (independent
///   hardware clocks, so drift compensation on the sub-devices) driven by a
///   direct I/O proc. AVAudioEngine's input and output share one HAL unit and
///   binding that single unit to an aggregate proved fragile across sample
///   rate and channel layouts; the I/O proc reads the input device's channels
///   and writes the output device's channels explicitly, the same low-level
///   primitive already proven by the earliest per-app capture engine.
///   Trade-off: gain and mute apply on this path, while EQ, overdrive, and
///   Magic Boost do not yet.
final class AudioRouter: ObservableObject {
    @Published private(set) var lastError: String?
    /// Live meter per route id (same id as the connection it came from).
    @Published private(set) var levels: [UUID: MeterReading] = [:]

    private let deviceManager: AudioDeviceManager
    private var engines: [UUID: AnyRouteEngine] = [:]
    private let lock = NSLock()

    init(deviceManager: AudioDeviceManager) {
        self.deviceManager = deviceManager
        Self.cleanupLeakedAggregates()
    }

    func apply(routes: [Route]) {
        lock.lock(); defer { lock.unlock() }

        // A new reconciliation supersedes any previous failure. Without this,
        // one stale error banner stayed on screen forever.
        DispatchQueue.main.async { if self.lastError != nil { self.lastError = nil } }

        let wanted = Set(routes.map(\.id))
        for (id, engine) in engines where !wanted.contains(id) {
            engine.stop(); engines[id] = nil
            DispatchQueue.main.async { self.levels[id] = nil }
        }

        for route in routes {
            guard let inID = deviceManager.deviceID(forUID: route.inputDeviceUID),
                  let outID = deviceManager.deviceID(forUID: route.outputDeviceUID) else { continue }

            if let engine = engines[route.id],
               engine.inputDeviceUID == route.inputDeviceUID, engine.outputDeviceUID == route.outputDeviceUID,
               engine.inputDeviceID == inID, engine.outputDeviceID == outID {
                engine.configure(route)
            } else {
                // Tear down whatever was here and clear the slot before
                // attempting the new engine, so a failed start leaves no stale
                // entry that could later masquerade as a live route.
                engines[route.id]?.stop()
                engines[route.id] = nil

                // A device that has never been selected in System Settings
                // keeps whatever mute/volume state it last had. Wake it once
                // so a fresh route is not silently muted at the hardware level.
                deviceManager.wakeOutputIfSilent(forUID: route.outputDeviceUID)

                let id = route.id
                let onLevel: (MeterReading) -> Void = { [weak self] reading in
                    DispatchQueue.main.async { self?.levels[id] = reading }
                }
                let engine: AnyRouteEngine
                if route.inputDeviceUID == route.outputDeviceUID {
                    engine = SameDeviceRouteEngine(
                        inputDeviceUID: route.inputDeviceUID, inputDeviceID: inID,
                        outputDeviceUID: route.outputDeviceUID, outputDeviceID: outID,
                        onLevel: onLevel)
                } else {
                    engine = CrossDeviceRouteEngine(
                        inputDeviceUID: route.inputDeviceUID, inputDeviceID: inID,
                        outputDeviceUID: route.outputDeviceUID, outputDeviceID: outID,
                        onLevel: onLevel)
                }
                do { try engine.start(route); engines[route.id] = engine }
                catch {
                    DispatchQueue.main.async { self.lastError = error.localizedDescription }
                }
            }
        }
    }

    /// Attach or detach a recorder on a live route's engine.
    func setRecorder(routeID: UUID, _ recorder: MixRecorder?) {
        lock.lock(); defer { lock.unlock() }
        engines[routeID]?.recorderSlot.set(recorder)
    }

    /// True when a live engine currently carries this route id. Recording
    /// mounts use it to pick a group member that is actually running.
    func hasEngine(routeID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return engines[routeID] != nil
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

// MARK: - Engine protocol

protocol AnyRouteEngine: AnyObject {
    var inputDeviceUID: String { get }
    var outputDeviceUID: String { get }
    var inputDeviceID: AudioDeviceID { get }
    var outputDeviceID: AudioDeviceID { get }
    var recorderSlot: RecorderSlot { get }
    func start(_ route: Route) throws
    func configure(_ route: Route)
    func stop()
}

enum RouteEngineError: LocalizedError {
    case noUnit(String), setDevice(String, OSStatus), aggregateCreate(OSStatus), ioProcCreate(OSStatus), deviceStart(OSStatus)
    var errorDescription: String? {
        switch self {
        case .noUnit(let l): return "Missing \(l) audio unit"
        case .setDevice(let l, let s): return "Could not set \(l) device (\(s))"
        case .aggregateCreate(let s): return "Could not create the routing aggregate device (\(s))"
        case .ioProcCreate(let s): return "Could not create the routing I/O callback (\(s))"
        case .deviceStart(let s): return "Could not start the routing device (\(s))"
        }
    }
}

// MARK: - Same-device engine (full DSP chain)

private final class SameDeviceRouteEngine: AnyRouteEngine {
    let inputDeviceUID: String
    let outputDeviceUID: String
    let inputDeviceID: AudioDeviceID
    let outputDeviceID: AudioDeviceID
    let recorderSlot = RecorderSlot()

    private let engine = AVAudioEngine()
    private let eq = AVAudioUnitEQ(numberOfBands: AudioEQ.bandCount)
    private let magicBoost = MagicBoost.makeEffect()
    private let onLevel: (MeterReading) -> Void
    private let throttle = MeterThrottle()
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
        do {
            try startUnsafe(route)
        } catch {
            stop()
            throw error
        }
    }

    private func startUnsafe(_ route: Route) throws {
        guard let unit = engine.inputNode.audioUnit else { throw RouteEngineError.noUnit("device") }
        var dev = inputDeviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &dev,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { throw RouteEngineError.setDevice("device", status) }
        engine.reset()

        engine.attach(eq)
        engine.attach(magicBoost)
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)

        engine.connect(engine.inputNode, to: eq, format: inputFormat)
        engine.connect(eq, to: magicBoost, format: inputFormat)
        engine.connect(magicBoost, to: engine.mainMixerNode, format: inputFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
        configure(route)

        // One tap serves both the meter (throttled) and the recorder (every
        // buffer): a bus allows only a single tap.
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
        do {
            try engine.start()
        } catch {
            NSLog("Audeon.route: FAILED device route \(inputDeviceUID) -> \(outputDeviceUID): \(error) | in \(Int(inputFormat.channelCount))ch out \(Int(outputFormat.channelCount))ch")
            throw error
        }
        started = true
        NSLog("Audeon.route: STARTED device route \(inputDeviceUID) -> \(outputDeviceUID) | in \(Int(inputFormat.channelCount))ch@\(Int(inputFormat.sampleRate)) out \(Int(outputFormat.channelCount))ch@\(Int(outputFormat.sampleRate))")
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
    }
}

// MARK: - Cross-device engine (direct I/O proc on a private aggregate)

private final class CrossDeviceRouteEngine: AnyRouteEngine {
    let inputDeviceUID: String
    let outputDeviceUID: String
    let inputDeviceID: AudioDeviceID
    let outputDeviceID: AudioDeviceID
    let recorderSlot = RecorderSlot()

    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private var sampleRate: Double = 48000

    /// How many leading channels of the aggregate's input stream belong to the
    /// OUTPUT device rather than the input device. The aggregate lists the
    /// output sub-device first, so when that device is duplex (an interface, a
    /// virtual device, anything with its own inputs) its input channels sit
    /// ahead of the real source. Skipping them is the whole reason a route to a
    /// duplex output used to fall silent while a route to the built-in speakers
    /// (no inputs) worked.
    private var inputChannelOffset = 0

    /// The EQ + overdrive + Magic Boost chain, rendered manually inside the
    /// I/O proc. nil when manual rendering is unavailable, in which case the
    /// raw gain path below still carries audio.
    private var dsp: CrossDeviceDSPChain?

    // Read by the audio thread every cycle, written by configure() on the main
    // thread. A single Float write is atomic enough for a gain value.
    private let gain = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    private let onLevel: (MeterReading) -> Void
    private let throttle = MeterThrottle()

    init(inputDeviceUID: String, inputDeviceID: AudioDeviceID,
         outputDeviceUID: String, outputDeviceID: AudioDeviceID,
         onLevel: @escaping (MeterReading) -> Void) {
        self.inputDeviceUID = inputDeviceUID
        self.inputDeviceID = inputDeviceID
        self.outputDeviceUID = outputDeviceUID
        self.outputDeviceID = outputDeviceID
        self.onLevel = onLevel
        gain.initialize(to: 0)
    }

    deinit {
        gain.deallocate()
    }

    func start(_ route: Route) throws {
        do {
            try startUnsafe(route)
        } catch {
            stop()
            throw error
        }
    }

    private func startUnsafe(_ route: Route) throws {
        let aggUID = "\(audeonRouteAggregateUIDPrefix)\(UUID().uuidString)"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Audeon Route",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputDeviceUID],
                [kAudioSubDeviceUIDKey as String: inputDeviceUID,
                 kAudioSubDeviceDriftCompensationKey as String: 1]
            ]
        ]
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
        guard aggStatus == noErr, aggregateID != 0 else {
            NSLog("Audeon.route: FAILED cross route aggregate \(inputDeviceUID) -> \(outputDeviceUID) (status \(aggStatus))")
            throw RouteEngineError.aggregateCreate(aggStatus)
        }
        // Give CoreAudio a moment to settle the aggregate's derived clock and
        // stream formats before I/O begins.
        Thread.sleep(forTimeInterval: 0.05)
        sampleRate = Self.nominalSampleRate(aggregateID) ?? 48000

        // The output sub-device is listed first, so its own input channels (if
        // it is a duplex device) lead the aggregate's input stream. The real
        // source begins right after them.
        inputChannelOffset = Self.inputChannelCount(outputDeviceID)

        // The DSP chain (EQ, overdrive, Magic Boost) rendered inside the I/O
        // proc. If it cannot start, the raw gain path below still carries
        // audio, so a chain problem can never silence the route.
        dsp = CrossDeviceDSPChain(sampleRate: sampleRate, maxFrames: 4096)

        configure(route)

        let gain = self.gain
        let onLevel = self.onLevel
        let throttle = self.throttle
        let slot = self.recorderSlot
        let rate = self.sampleRate
        let dsp = self.dsp
        let offset = self.inputChannelOffset

        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inInput, _, outOutput, _ in
            Self.render(input: inInput, output: outOutput, gain: gain.pointee, dsp: dsp,
                        slot: slot, sampleRate: rate, inputOffset: offset, throttle: throttle, onLevel: onLevel)
        }
        guard procStatus == noErr, let procID else {
            NSLog("Audeon.route: FAILED cross route ioproc \(inputDeviceUID) -> \(outputDeviceUID) (status \(procStatus))")
            throw RouteEngineError.ioProcCreate(procStatus)
        }
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            NSLog("Audeon.route: FAILED cross route start \(inputDeviceUID) -> \(outputDeviceUID) (status \(startStatus))")
            throw RouteEngineError.deviceStart(startStatus)
        }
        running = true
        NSLog("Audeon.route: STARTED cross route \(inputDeviceUID) -> \(outputDeviceUID) via I/O proc @\(Int(sampleRate)), skipping \(inputChannelOffset) output-side input channel(s)")
    }

    /// The realtime callback body. With a DSP chain, the input is pulled
    /// through EQ + overdrive + Magic Boost (volume and mute included, on the
    /// chain's mixer) and the processed stereo result fans out to the output
    /// channels. Without one, or if a cycle fails, the raw path copies input
    /// to output with plain gain, so audio keeps flowing no matter what.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               gain: Float,
                               dsp: CrossDeviceDSPChain?,
                               slot: RecorderSlot,
                               sampleRate: Double,
                               inputOffset: Int,
                               throttle: MeterThrottle,
                               onLevel: @escaping (MeterReading) -> Void) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // Flatten the input side into logical channels (a stream buffer can
        // carry several interleaved channels).
        var allInChannels: [(base: UnsafePointer<Float>, stride: Int, frames: Int)] = []
        allInChannels.reserveCapacity(8)
        for buf in inList {
            guard let data = buf.mData, buf.mNumberChannels > 0 else { continue }
            let chs = Int(buf.mNumberChannels)
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * chs)
            let base = data.assumingMemoryBound(to: Float.self)
            for c in 0..<chs {
                allInChannels.append((base: UnsafePointer(base) + c, stride: chs, frames: frames))
            }
        }

        // Drop the leading channels that belong to a duplex output device, so
        // what remains is the real source. Clamp defensively: never skip so far
        // that nothing is left, or the route would silence itself.
        let skip = inputOffset < allInChannels.count ? inputOffset : 0
        let inChannels = Array(allInChannels[skip...])

        // Processed stereo from the DSP chain, when available this cycle.
        var processed: (left: UnsafePointer<Float>, right: UnsafePointer<Float>)?
        var processedFrames = 0
        if let dsp, !inChannels.isEmpty {
            let frames = inChannels[0].frames
            processed = dsp.process(frames: AVAudioFrameCount(frames)) { left, right, n in
                let l = inChannels[0]
                let r = inChannels.count > 1 ? inChannels[1] : inChannels[0]
                let count = min(n, l.frames, r.frames)
                for f in 0..<count {
                    left[f] = l.base[f * l.stride]
                    right[f] = r.base[f * r.stride]
                }
                if count < n {
                    for f in count..<n { left[f] = 0; right[f] = 0 }
                }
            }
            processedFrames = frames
        }

        var sumSquares: Float = 0
        var peak: Float = 0
        var meterSamples = 0
        var globalOut = 0

        for buf in outList {
            guard let data = buf.mData, buf.mNumberChannels > 0 else { continue }
            let chs = Int(buf.mNumberChannels)
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * chs)
            let base = data.assumingMemoryBound(to: Float.self)

            for c in 0..<chs {
                if let processed {
                    // DSP path: fan the processed stereo out (L, R, L, R...).
                    let src = (globalOut % 2 == 0) ? processed.left : processed.right
                    let n = min(frames, processedFrames)
                    for f in 0..<n {
                        let s = src[f]
                        base[f * chs + c] = s
                        sumSquares += s * s
                        let a = abs(s)
                        if a > peak { peak = a }
                    }
                    if n < frames {
                        for f in n..<frames { base[f * chs + c] = 0 }
                    }
                    meterSamples += n
                } else if inChannels.isEmpty {
                    for f in 0..<frames { base[f * chs + c] = 0 }
                } else {
                    // Raw path: direct copy with gain.
                    let src = inChannels[globalOut % inChannels.count]
                    let n = min(frames, src.frames)
                    for f in 0..<n {
                        let s = src.base[f * src.stride] * gain
                        base[f * chs + c] = s
                        sumSquares += s * s
                        let a = abs(s)
                        if a > peak { peak = a }
                    }
                    if n < frames {
                        for f in n..<frames { base[f * chs + c] = 0 }
                    }
                    meterSamples += n
                }
                globalOut += 1
            }
        }

        if let recorder = slot.acquire(), !inChannels.isEmpty {
            // Only taken while actually recording, so the steady-state path
            // stays copy-free. Records exactly what is sent to the output, and
            // pushes straight from the source pointers: the realtime thread
            // builds no Swift array and touches no file.
            if let processed {
                recorder.push(frames: processedFrames, sampleRate: sampleRate, gain: 1,
                              left: processed.left, leftStride: 1,
                              right: processed.right, rightStride: 1)
            } else {
                let l = inChannels[0]
                let r = inChannels.count > 1 ? inChannels[1] : nil
                recorder.push(frames: min(l.frames, r?.frames ?? l.frames),
                              sampleRate: sampleRate, gain: gain,
                              left: l.base, leftStride: l.stride,
                              right: r?.base, rightStride: r?.stride ?? 1)
            }
        }

        if meterSamples > 0, throttle.shouldFire() {
            let rms = (sumSquares / Float(meterSamples)).squareRoot()
            onLevel(AudioMeter.reading(rms: rms, peak: peak))
        }
    }

    func configure(_ route: Route) {
        // The raw fallback path applies this gain; the DSP chain applies
        // volume, mute, EQ, overdrive, and Magic Boost itself.
        gain.pointee = route.isMuted ? 0 : Float(route.volume)
        dsp?.configure(route)
    }

    func stop() {
        if let procID {
            if running { AudioDeviceStop(aggregateID, procID) }
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        running = false
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
    }

    /// Total input channels a device exposes, used to find where the real
    /// source begins inside the aggregate's combined input stream.
    private static func inputChannelCount(_ device: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Float64>.size)
        var v: Float64 = 0
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr, v > 0 else { return nil }
        return v
    }
}
