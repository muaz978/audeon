import XCTest
import AVFoundation
@testable import Audeon

/// Covers the recorder rewrite. The defect these guard against was severe: the
/// old implementation could re-open its own file with `forWriting` while the
/// audio thread was mid-append, truncating a finished recording to a single
/// buffer.
final class MixRecorderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudeonTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func url(_ name: String) -> URL {
        folder.appendingPathComponent(name).appendingPathExtension("caf")
    }

    private func frames(at url: URL) throws -> AVAudioFramePosition {
        let file = try AVAudioFile(forReading: url)
        return file.length
    }

    /// Push interleaved stereo through the pointer API the I/O proc uses.
    private func push(_ recorder: MixRecorder, frames: Int, sampleRate: Double = 48_000, value: Float = 0.25) {
        var left = [Float](repeating: value, count: frames)
        var right = [Float](repeating: -value, count: frames)
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                recorder.push(frames: frames, sampleRate: sampleRate, gain: 1,
                              left: l.baseAddress!, leftStride: 1,
                              right: r.baseAddress!, rightStride: 1)
            }
        }
    }

    // MARK: - The headline fix

    func testFinishKeepsEverythingWrittenSoFar() throws {
        let target = url("keeps-audio")
        let recorder = MixRecorder(url: target)
        recorder.start()

        // 100 cycles of 512 frames = 51,200 frames, well beyond one buffer.
        for _ in 0..<100 { push(recorder, frames: 512) }
        recorder.finish()

        let written = try frames(at: target)
        XCTAssertEqual(written, 51_200,
                       "finish() must flush every buffered frame; a short file here is the truncation defect")
    }

    func testFinishWhileStillPushingDoesNotTruncate() throws {
        let target = url("concurrent-stop")
        let recorder = MixRecorder(url: target)
        recorder.start()

        // Drive the recorder from a background thread while the main thread
        // stops it -- the exact interleaving that used to re-open the file with
        // `forWriting` and reduce the recording to one buffer.
        let pushing = expectation(description: "pusher finished")
        DispatchQueue.global().async {
            for _ in 0..<400 { self.push(recorder, frames: 256) }
            pushing.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)
        wait(for: [pushing], timeout: 5)
        recorder.finish()

        let written = try frames(at: target)
        XCTAssertGreaterThan(written, 1_024,
                             "a file of one or two buffers means the recording was truncated on stop")
    }

    func testFinishIsIdempotent() throws {
        let target = url("double-finish")
        let recorder = MixRecorder(url: target)
        recorder.start()
        for _ in 0..<10 { push(recorder, frames: 512) }
        recorder.finish()
        let after = try frames(at: target)
        recorder.finish()   // must not reopen, truncate, or hang
        XCTAssertEqual(try frames(at: target), after)
    }

    func testPushAfterFinishIsIgnored() throws {
        let target = url("push-after-finish")
        let recorder = MixRecorder(url: target)
        recorder.start()
        for _ in 0..<10 { push(recorder, frames: 512) }
        recorder.finish()
        let after = try frames(at: target)

        for _ in 0..<10 { push(recorder, frames: 512) }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(try frames(at: target), after,
                       "a late buffer from the audio thread must not reopen a closed file")
    }

    // MARK: - Format changes

    func testFormatChangeRollsOverToASecondSegment() throws {
        let first = url("rollover")
        let recorder = MixRecorder(url: first)
        recorder.start()

        for _ in 0..<20 { push(recorder, frames: 512, sampleRate: 48_000) }
        Thread.sleep(forTimeInterval: 0.15)   // let the writer drain the first format

        // Sleep/wake putting the engine back at a different rate. Pushed over
        // time rather than in a tight loop, because that is what the audio
        // thread does: the first buffer in the new format asks the writer to
        // roll over and is dropped, and the ones after it land in the new
        // segment. A burst that completes inside one writer poll would be
        // discarded wholesale and prove nothing.
        for _ in 0..<20 {
            push(recorder, frames: 512, sampleRate: 44_100)
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.15)
        recorder.finish()

        let second = folder.appendingPathComponent("rollover-2").appendingPathExtension("caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path),
                      "a sample-rate change must roll over to a new segment rather than write a mismatched buffer")

        let a = try AVAudioFile(forReading: first)
        let b = try AVAudioFile(forReading: second)
        XCTAssertEqual(a.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(b.fileFormat.sampleRate, 44_100)
    }

    // MARK: - Buffer discipline

    func testOverflowDropsRatherThanCorrupts() throws {
        let target = url("overflow")
        let recorder = MixRecorder(url: target)
        recorder.start()

        // Far more than the ring holds, pushed with no chance for the writer to
        // drain. Excess must be dropped, and the file must stay readable.
        for _ in 0..<4_000 { push(recorder, frames: 1_024) }
        recorder.finish()

        let written = try frames(at: target)
        XCTAssertGreaterThan(written, 0, "overflow must drop excess, not abandon the recording")
        let file = try AVAudioFile(forReading: target)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
    }

    func testMonoPushProducesAMonoFile() throws {
        let target = url("mono")
        let recorder = MixRecorder(url: target)
        recorder.start()
        var mono = [Float](repeating: 0.5, count: 512)
        for _ in 0..<10 {
            mono.withUnsafeBufferPointer { m in
                recorder.push(frames: 512, sampleRate: 48_000, gain: 1,
                              left: m.baseAddress!, leftStride: 1,
                              right: nil, rightStride: 1)
            }
        }
        recorder.finish()
        let file = try AVAudioFile(forReading: target)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, 5_120)
    }

    func testGainIsAppliedOnTheWayIn() throws {
        let target = url("gain")
        let recorder = MixRecorder(url: target)
        recorder.start()
        var samples = [Float](repeating: 1.0, count: 512)
        samples.withUnsafeBufferPointer { s in
            recorder.push(frames: 512, sampleRate: 48_000, gain: 0.5,
                          left: s.baseAddress!, leftStride: 1, right: nil, rightStride: 1)
        }
        recorder.finish()

        let file = try AVAudioFile(forReading: target)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let first = buffer.floatChannelData![0][0]
        XCTAssertEqual(first, 0.5, accuracy: 0.001)
    }

    // MARK: - The engine-tap entry point

    func testAppendFromAnAVAudioPCMBuffer() throws {
        let target = url("tap-path")
        let recorder = MixRecorder(url: target)
        recorder.start()

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for _ in 0..<10 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            buffer.frameLength = 512
            for c in 0..<2 {
                for f in 0..<512 { buffer.floatChannelData![c][f] = 0.1 }
            }
            recorder.append(buffer)
        }
        recorder.finish()
        XCTAssertEqual(try frames(at: target), 5_120)
    }
}

/// The slot is the handoff between the main thread and the audio callback.
final class RecorderSlotTests: XCTestCase {
    func testAcquireReturnsWhatWasSet() {
        let slot = RecorderSlot()
        XCTAssertNil(slot.acquire())

        let recorder = MixRecorder(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("slot-\(UUID().uuidString).caf"))
        slot.set(recorder)
        XCTAssertTrue(slot.acquire() === recorder)

        slot.set(nil)
        XCTAssertNil(slot.acquire())
    }

    func testConcurrentSetAndAcquireDoNotCrash() {
        let slot = RecorderSlot()
        let done = expectation(description: "readers finished")
        done.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for i in 0..<2_000 {
                let r = MixRecorder(url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("churn-\(i).caf"))
                slot.set(r)
            }
            slot.set(nil)
            done.fulfill()
        }
        DispatchQueue.global().async {
            for _ in 0..<20_000 { _ = slot.acquire() }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
    }
}
