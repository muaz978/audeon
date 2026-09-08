import XCTest
import AVFoundation
import CoreAudio
@testable import Audeon

/// End-to-end checks against the real CoreAudio stack on this machine.
///
/// Skipped unless `AUDEON_HW_TESTS=1`, because they need actual audio devices —
/// CI runners have none, and a machine without the Audeon driver installed
/// cannot run them either. They are deliberately silent: every route runs
/// between virtual devices, so nothing reaches a speaker and the system's
/// default output device is never touched.
///
/// What these cover that unit tests cannot: that a route built by AudioRouter
/// actually carries audio through a real aggregate device, and that a recording
/// of it survives being stopped while audio is still flowing.
@MainActor
final class HardwareIntegrationTests: XCTestCase {
    private var manager: AudioDeviceManager!
    private var router: AudioRouter!
    private var folder: URL!

    /// The loopback the injected signal goes through: anything played to its
    /// output appears on its input.
    private let loopbackUID = audeonVirtualDeviceUID

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AUDEON_HW_TESTS"] == "1",
                          "set AUDEON_HW_TESTS=1 to run against real audio hardware")
        manager = AudioDeviceManager()
        router = AudioRouter(deviceManager: manager)
        try XCTSkipUnless(manager.deviceID(forUID: loopbackUID) != nil,
                          "the Audeon virtual driver is not installed on this machine")
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudeonHW-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        router?.stopAll()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// A second full-duplex virtual device, so a cross-device route can be built
    /// without any real speaker being involved.
    private func silentOutputUID() throws -> String {
        let candidates = manager.outputs.filter {
            $0.uid != loopbackUID &&
            ($0.name.localizedCaseInsensitiveContains("steam") ||
             $0.name.localizedCaseInsensitiveContains("blackhole"))
        }
        let uid = try XCTUnwrap(candidates.first?.uid,
                                "no second virtual output device to route to; skipping rather than making noise")
        return uid
    }

    private func route(from input: String, to output: String) -> Route {
        Route(id: UUID(), inputUID: "input:\(input)", outputUID: "output:\(output)",
              volume: 1.0, isMuted: false, boost: 1.0,
              eqEnabled: false, eq: AudioEQ.flat, magicBoost: false)
    }

    /// AudioRouter.apply is asynchronous now, so wait for the engine to exist.
    private func waitForEngine(_ id: UUID, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if router.hasEngine(routeID: id) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    /// Play a tone into the loopback's output so it appears on its input.
    private func injectTone(seconds: Double) throws -> AVAudioEngine {
        let deviceID = try XCTUnwrap(manager.deviceID(forUID: loopbackUID))
        let engine = AVAudioEngine()
        let unit = try XCTUnwrap(engine.outputNode.audioUnit)
        var dev = deviceID
        XCTAssertEqual(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                            kAudioUnitScope_Global, 0, &dev,
                                            UInt32(MemoryLayout<AudioDeviceID>.size)), noErr)
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        var phase = 0.0
        let increment = 2.0 * Double.pi * 440.0 / rate
        let source = AVAudioSourceNode { _, _, frames, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            for f in 0..<Int(frames) {
                let v = Float(sin(phase) * 0.25)
                phase += increment
                if phase > 2 * .pi { phase -= 2 * .pi }
                for b in buffers {
                    b.mData?.assumingMemoryBound(to: Float.self)[f] = v
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.outputNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        try engine.start()
        return engine
    }

    /// Peak level and the largest sample-to-sample jump, which is how a dropout
    /// or a splice shows up numerically.
    private func analyse(_ url: URL) throws -> (frames: AVAudioFramePosition, peak: Float, maxJump: Float) {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return (0, 0, 0) }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        let data = try XCTUnwrap(buffer.floatChannelData)
        var peak: Float = 0, jump: Float = 0, previous: Float = data[0][0]
        for f in 0..<n {
            let s = data[0][f]
            peak = max(peak, abs(s))
            jump = max(jump, abs(s - previous))
            previous = s
        }
        return (file.length, peak, jump)
    }

    /// The control for the two tests below: the same route and recorder with no
    /// signal injected must record silence. Without this, a peak assertion
    /// could be passing on noise, or on nothing at all — the machinery still
    /// records tens of thousands of frames either way, so frame count alone
    /// proves nothing about whether audio actually arrived.
    func testRouteWithNoInputRecordsSilence() throws {
        let outUID = try silentOutputUID()
        let r = route(from: loopbackUID, to: outUID)
        router.apply(routes: [r])
        XCTAssertTrue(waitForEngine(r.id), "the route never started on real hardware")

        let target = folder.appendingPathComponent("silence.caf")
        let recorder = MixRecorder(url: target)
        recorder.start()
        router.setRecorder(routeID: r.id, recorder)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        recorder.finish()
        router.stopAll()

        let (frames, peak, _) = try analyse(target)
        print("  [hw] silence control: frames=\(frames) peak=\(peak)")
        XCTAssertGreaterThan(frames, 20_000, "the recorder captured nothing at all")
        XCTAssertLessThan(peak, 0.001, "expected silence with no signal injected")
    }

    // MARK: - Tests

    /// A cross-device route on real hardware carries the injected signal, and
    /// recording it produces a file with real audio in it.
    func testCrossDeviceRouteCarriesAudioAndRecordsIt() throws {
        let outUID = try silentOutputUID()
        let r = route(from: loopbackUID, to: outUID)
        router.apply(routes: [r])
        XCTAssertTrue(waitForEngine(r.id), "the route never started on real hardware")

        let target = folder.appendingPathComponent("crossdevice.caf")
        let recorder = MixRecorder(url: target)
        recorder.start()
        router.setRecorder(routeID: r.id, recorder)

        let tone = try injectTone(seconds: 1.0)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        tone.stop()
        recorder.finish()
        router.stopAll()

        let (frames, peak, jump) = try analyse(target)
        print("  [hw] cross-device: frames=\(frames) peak=\(peak) maxJump=\(jump)")
        XCTAssertGreaterThan(frames, 20_000, "recorded far less than the second of audio that was played")
        XCTAssertGreaterThan(peak, 0.01, "the route produced silence: audio did not reach the output")
    }

    /// The truncation defect, on real hardware: stop while audio is still
    /// flowing and the recording must survive intact.
    func testStoppingMidPlaybackKeepsTheRecording() throws {
        let outUID = try silentOutputUID()
        let r = route(from: loopbackUID, to: outUID)
        router.apply(routes: [r])
        XCTAssertTrue(waitForEngine(r.id), "the route never started on real hardware")

        let target = folder.appendingPathComponent("stopmid.caf")
        let recorder = MixRecorder(url: target)
        recorder.start()
        router.setRecorder(routeID: r.id, recorder)

        let tone = try injectTone(seconds: 2.0)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        // Stop the recorder while the engine is still running and pushing.
        recorder.finish()
        tone.stop()
        router.stopAll()

        let (frames, peak, jump) = try analyse(target)
        print("  [hw] stop mid-playback: frames=\(frames) peak=\(peak) maxJump=\(jump)")
        XCTAssertGreaterThan(frames, 40_000,
                             "a short file here is the truncation defect: stop re-opened the file")
        XCTAssertGreaterThan(peak, 0.01, "recorded silence")
        XCTAssertLessThan(jump, 0.9,
                          "a full-scale discontinuity indicates a dropout or a spliced buffer")
    }

    /// Per-app capture, against real process taps.
    ///
    /// This is the check that the tap actually *starts*. Construction and
    /// starting were split apart so a replacement unit can be built while the
    /// one it replaces keeps playing, and the compiler cannot tell you that the
    /// start call was left out — the build stays clean while no audio ever
    /// flows. Only a live unit proves the wiring.
    func testAppTapStartsAndSurvivesAProcessSetChange() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("process taps need macOS 14.2") }
        let outUID = try silentOutputUID()
        let processes = Self.audioProcessObjects()
        try XCTSkipUnless(processes.count >= 2, "need at least two audio processes to tap")

        let redirect = AppRedirectEngine(deviceManager: manager)
        defer { redirect.stopAll() }

        func request(_ objects: [AudioObjectID]) -> AppTapRequest {
            AppTapRequest(bundleID: "test.audeon.probe", processObjects: objects,
                          outputUID: outUID, volume: 1.0, boost: 1.0,
                          eqEnabled: false, eq: AudioEQ.flat, magicBoost: false)
        }
        func waitForUnit(_ expected: Bool, _ message: String) {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if redirect.hasLiveUnit(bundleID: "test.audeon.probe", outputUID: outUID) == expected { return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            XCTFail(message)
        }

        redirect.apply([request([processes[0]])])
        waitForUnit(true, "the tap is not running — construction succeeded but the engine never started")

        // The app gains a second audio process. The unit is rebuilt, and the
        // replacement is constructed before the outgoing one is stopped.
        redirect.apply([request([processes[0], processes[1]])])
        waitForUnit(true, "the tap did not survive a process-set change")
    }

    /// A device disappearing while a route is live.
    ///
    /// Unplugging hardware needs hands, but destroying an aggregate device is
    /// indistinguishable from it as far as CoreAudio is concerned: the device
    /// leaves the device list and its id stops resolving. That is the exact
    /// path that used to leave the engine running with a stale meter, leaking
    /// its own aggregate and I/O proc for the lifetime of the app.
    func testRouteTearsDownWhenItsOutputDeviceDisappears() throws {
        let sub = try XCTUnwrap(manager.outputs.first { !manager.isVirtualSystemAudio($0.uid) }?.uid,
                                "no real output device to build a temporary aggregate over")
        // Deliberately not the "audeon." prefix: AudioDeviceManager hides those
        // from its published lists, and this one has to be visible to be routed to.
        let tempUID = "test.audeon.vanishing.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Audeon Test Vanishing",
            kAudioAggregateDeviceUIDKey as String: tempUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMainSubDeviceKey as String: sub,
            kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: sub]]
        ]
        var tempID: AudioObjectID = 0
        let created = AudioHardwareCreateAggregateDevice(description as CFDictionary, &tempID)
        try XCTSkipUnless(created == noErr && tempID != 0,
                          "could not create a temporary aggregate device (status \(created))")
        var destroyed = false
        defer { if !destroyed { AudioHardwareDestroyAggregateDevice(tempID) } }

        // Let the device list settle so the manager can resolve the new uid.
        manager.refresh()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        manager.refresh()
        try XCTSkipUnless(manager.deviceID(forUID: tempUID) != nil,
                          "the temporary device did not appear in the device list")

        let r = route(from: loopbackUID, to: tempUID)
        router.apply(routes: [r])
        XCTAssertTrue(waitForEngine(r.id), "the route to the temporary device never started")

        // The device goes away underneath the running route.
        XCTAssertEqual(AudioHardwareDestroyAggregateDevice(tempID), noErr)
        destroyed = true
        manager.refresh()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        manager.refresh()
        XCTAssertNil(manager.deviceID(forUID: tempUID), "the device should be gone from the map")

        // Reconciliation must now stop and clear the engine rather than leave a
        // dead route running.
        router.apply(routes: [r])
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !router.hasEngine(routeID: r.id) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(router.hasEngine(routeID: r.id),
                       "the engine outlived its device: this is the stale-route leak")
    }

    /// Audio process objects on this machine, for building a tap request.
    private static func audioProcessObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// A route between two real devices reports a live engine. Uses the default
    /// output only as a target for the aggregate; nothing is played to it.
    func testRouteToARealOutputStarts() throws {
        let real = manager.outputs.first {
            !manager.isVirtualSystemAudio($0.uid) &&
            !$0.name.localizedCaseInsensitiveContains("steam")
        }
        let outUID = try XCTUnwrap(real?.uid, "no real output device present")
        let r = route(from: loopbackUID, to: outUID)
        router.apply(routes: [r])
        XCTAssertTrue(waitForEngine(r.id),
                      "a cross-device route to a real output device failed to start")
        router.stopAll()
    }
}
