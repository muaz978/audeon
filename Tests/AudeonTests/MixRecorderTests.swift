import XCTest
import AVFoundation
@testable import Audeon

/// Push interleaved stereo through the pointer API the I/O proc uses.
///
/// File scope rather than a method on the test case: the concurrency test drives
/// this from a background queue, and a free function keeps the XCTestCase out of
/// that `@Sendable` closure's captures. It reads nothing but its parameters.
private func push(_ recorder: MixRecorder, frames: Int, sampleRate: Double = 48_000, value: Float = 0.25) {
    let left = [Float](repeating: value, count: frames)
    let right = [Float](repeating: -value, count: frames)
    left.withUnsafeBufferPointer { l in
        right.withUnsafeBufferPointer { r in
            recorder.push(frames: frames, sampleRate: sampleRate, gain: 1,
                          left: l.baseAddress!, leftStride: 1,
                          right: r.baseAddress!, rightStride: 1)
        }
    }
}

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
            for _ in 0..<400 { push(recorder, frames: 256) }
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
        let mono = [Float](repeating: 0.5, count: 512)
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
        let samples = [Float](repeating: 1.0, count: 512)
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

    // MARK: - Reporting a failed recording

    /// A recording that cannot open its file must say so. It used to record the
    /// failure into a field nothing read, so the file simply stopped growing
    /// and the UI went on showing a healthy recording.
    func testAFailedRecordingReportsAFatalProblem() throws {
        // A directory that does not exist, so AVAudioFile(forWriting:) throws.
        let unwritable = folder
            .appendingPathComponent("no-such-directory", isDirectory: true)
            .appendingPathComponent("out.caf")
        let recorder = MixRecorder(url: unwritable)
        recorder.start()
        push(recorder, frames: 256)

        var problem: RecordingProblem?
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, problem == nil {
            problem = recorder.takeProblem()
            if problem == nil { Thread.sleep(forTimeInterval: 0.02) }
        }
        recorder.finish()

        let reported = try XCTUnwrap(problem, "the recording failed and reported nothing")
        XCTAssertTrue(reported.isFatal, "a recording that cannot write is not a warning")
        XCTAssertTrue(reported.message.contains("recording file"),
                      "unhelpful message: \(reported.message)")
    }

    /// Consuming, so a watcher can poll every second without repeating itself.
    func testAProblemIsHandedOutOnlyOnce() throws {
        let recorder = MixRecorder(url: folder
            .appendingPathComponent("nope", isDirectory: true)
            .appendingPathComponent("out.caf"))
        recorder.start()
        push(recorder, frames: 256)

        var first: RecordingProblem?
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, first == nil {
            first = recorder.takeProblem()
            if first == nil { Thread.sleep(forTimeInterval: 0.02) }
        }
        recorder.finish()

        XCTAssertNotNil(first)
        XCTAssertNil(recorder.takeProblem(), "the same failure was reported twice")
    }

    /// Overflow used to set a Bool that nothing read. A count is reportable:
    /// "some audio was dropped" is not actionable, a duration is.
    func testDroppedAudioIsReportedWithHowMuch() throws {
        // Deliberately not started: with no writer draining, the ring fills and
        // then has to refuse buffers, which is exactly the overflow path.
        let recorder = MixRecorder(url: url("overflow"))
        for _ in 0..<2_000 { push(recorder, frames: 512) }

        let problem = try XCTUnwrap(recorder.takeProblem(), "the ring overflowed and reported nothing")
        XCTAssertFalse(problem.isFatal, "dropped audio is not fatal: the recording continues")
        XCTAssertTrue(problem.message.contains("dropped"), "unhelpful message: \(problem.message)")
        XCTAssertNil(recorder.takeProblem(), "the drop total was reported twice")
    }

    /// A recorder is single-use. Reusing one used to return early and discard
    /// every later push in silence.
    func testReusingAFinishedRecorderIsReported() throws {
        let recorder = MixRecorder(url: url("reuse"))
        recorder.start()
        push(recorder, frames: 256)
        recorder.finish()

        recorder.start()
        let problem = try XCTUnwrap(recorder.takeProblem(), "restarting a finished recorder said nothing")
        XCTAssertTrue(problem.isFatal)
        XCTAssertTrue(problem.message.contains("already finished"),
                      "unhelpful message: \(problem.message)")
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
