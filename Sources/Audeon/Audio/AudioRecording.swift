import Foundation
import AVFoundation
import os

/// Writes a source's processed audio to a file.
///
/// The audio thread never touches the file. `append` and `push` copy samples
/// into a fixed, pre-allocated ring, and a dedicated writer thread drains that
/// ring and owns the `AVAudioFile`
/// exclusively. Three things follow that the previous design could not
/// guarantee: the realtime thread performs no allocation, no disk I/O and no
/// `AVAudioFile` access; stopping cannot race a write; and the file is opened
/// exactly once per format, so it can never be re-created — and truncated —
/// part-way through a recording.
///
/// If the engine is rebuilt underneath a live recording (sleep/wake, a sample
/// rate change) the incoming format changes. Rather than hand a mismatched
/// buffer to `AVAudioFile.write(from:)`, which raises an Objective-C exception
/// that `try?` cannot catch, the recorder rolls over to a new numbered segment.
final class MixRecorder {
    /// The first segment's URL. Later segments append "-2", "-3", ...
    let url: URL

    /// 4 MB of float storage: ~10 s of stereo at 48 kHz, ~1.3 s of eight
    /// channels at 96 kHz. Allocated once, here, never on the audio thread.
    private static let ringCapacity = 1 << 20
    private static let ringMask = ringCapacity - 1
    private static let drainChunk = 1 << 16

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let ring: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>

    // All of the following are guarded by `lock`.
    private var head = 0
    private var tail = 0
    private var filled = 0
    private var ringSampleRate: Double = 0
    private var ringChannels = 0
    private var awaitingRollover = false
    private var stopping = false
    private var didOverflow = false

    private let finished = DispatchSemaphore(value: 0)
    private var writerRunning = false

    /// Set once by the writer thread, read on the main thread after `finish()`.
    private(set) var writeError: String?

    init(url: URL) {
        self.url = url
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        ring = UnsafeMutablePointer<Float>.allocate(capacity: Self.ringCapacity)
        ring.initialize(repeating: 0, count: Self.ringCapacity)
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.drainChunk)
        scratch.initialize(repeating: 0, count: Self.drainChunk)
    }

    deinit {
        // finish() is the supported teardown; this only covers a recorder that
        // is dropped without it.
        if writerRunning { finish() }
        ring.deallocate()
        scratch.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: - Audio-thread side

    /// Append a rendered buffer (AVAudioEngine tap path).
    ///
    /// Safe to call from any audio callback: it allocates nothing, touches no
    /// file, and returns immediately rather than waiting for the writer.
    func append(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        guard channels > 0 else { return }
        let rate = buffer.format.sampleRate

        if buffer.format.isInterleaved {
            write(interleaved: data[0], count: frames * channels,
                  channels: channels, sampleRate: rate)
        } else {
            write(planar: data, frames: frames, channels: channels, sampleRate: rate)
        }
    }

    /// Append up to two channels read through a (base, stride) pair — the shape
    /// the cross-device I/O proc already has its samples in. Taking the stride
    /// here is what lets that callback record without building Swift arrays on
    /// the realtime thread.
    func push(frames: Int,
              sampleRate: Double,
              gain: Float,
              left: UnsafePointer<Float>, leftStride: Int,
              right: UnsafePointer<Float>?, rightStride: Int) {
        guard frames > 0 else { return }
        let channels = right == nil ? 1 : 2
        let count = frames * channels
        guard let start = reserve(count: count, channels: channels, sampleRate: sampleRate) else { return }

        var w = start
        if let right {
            for f in 0..<frames {
                ring[w] = left[f * leftStride] * gain; w = (w + 1) & Self.ringMask
                ring[w] = right[f * rightStride] * gain; w = (w + 1) & Self.ringMask
            }
        } else {
            for f in 0..<frames {
                ring[w] = left[f * leftStride] * gain; w = (w + 1) & Self.ringMask
            }
        }
        publish(count: count, from: start)
    }

    private func write(planar data: UnsafePointer<UnsafeMutablePointer<Float>>,
                       frames: Int, channels: Int, sampleRate: Double) {
        let count = frames * channels
        guard let start = reserve(count: count, channels: channels, sampleRate: sampleRate) else { return }
        var w = start
        for f in 0..<frames {
            for c in 0..<channels {
                ring[w] = data[c][f]; w = (w + 1) & Self.ringMask
            }
        }
        publish(count: count, from: start)
    }

    private func write(interleaved data: UnsafePointer<Float>, count: Int,
                       channels: Int, sampleRate: Double) {
        guard let start = reserve(count: count, channels: channels, sampleRate: sampleRate) else { return }
        var w = start
        for i in 0..<count {
            ring[w] = data[i]; w = (w + 1) & Self.ringMask
        }
        publish(count: count, from: start)
    }

    /// Adopt the incoming format, or ask the writer to roll over to a new
    /// segment if it differs from what is still buffered. Returns false when
    /// the caller must drop this buffer. Caller holds `lock`.
    private func prepareLocked(channels: Int, sampleRate: Double) -> Bool {
        if stopping { return false }
        if ringChannels == channels && ringSampleRate == sampleRate { return !awaitingRollover }
        if filled == 0 && !awaitingRollover {
            // Nothing buffered in the old format: adopt the new one outright.
            // On the very first buffer this is simply how the format is learned.
            if ringChannels != 0 { awaitingRollover = true; return false }
            ringChannels = channels
            ringSampleRate = sampleRate
            return true
        }
        awaitingRollover = true
        return false
    }

    /// Claim `count` slots and return where to start writing, or nil when the
    /// format is rolling over or the ring is genuinely full. Dropping on a full
    /// ring is deliberate: a gap is recoverable, interleaved garbage is not.
    ///
    /// Takes the lock rather than trying it. Both sides hold it only across
    /// index arithmetic -- the sample copies happen outside it on both the
    /// producer and the writer -- so the wait is a few instructions and
    /// os_unfair_lock donates priority to whoever holds it. Trying the lock and
    /// giving up instead meant a contended cycle silently discarded that
    /// buffer, which for a recording is lost audio rather than a dropped meter
    /// frame.
    private func reserve(count: Int, channels: Int, sampleRate: Double) -> Int? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard prepareLocked(channels: channels, sampleRate: sampleRate) else { return nil }
        guard count <= Self.ringCapacity - filled else {
            didOverflow = true
            return nil
        }
        return head
    }

    /// Make the samples just written visible to the writer thread. `head` is
    /// only ever advanced here, by the single producer, so it is stable between
    /// the reserve above and this call.
    private func publish(count: Int, from start: Int) {
        os_unfair_lock_lock(lock)
        head = (start + count) & Self.ringMask
        filled += count
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Main-thread side

    /// Begin writing. Idempotent.
    func start() {
        os_unfair_lock_lock(lock)
        let alreadyRunning = writerRunning
        if !alreadyRunning { writerRunning = true }
        os_unfair_lock_unlock(lock)
        guard !alreadyRunning else { return }

        let thread = Thread { [weak self] in self?.writerLoop() }
        thread.name = "com.audeon.recorder"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Stop writing and close the file. Idempotent, and safe to call while the
    /// audio thread is still running: it signals the writer, which drains what
    /// is already buffered and closes the file itself. Waits briefly so the
    /// file has a valid header before the app exits.
    func finish() {
        os_unfair_lock_lock(lock)
        let running = writerRunning
        let alreadyStopping = stopping
        stopping = true
        os_unfair_lock_unlock(lock)

        guard running, !alreadyStopping else { return }
        // Bounded: a wedged writer must never block quitting.
        _ = finished.wait(timeout: .now() + 2.0)
    }

    // MARK: - Writer thread

    private func writerLoop() {
        var file: AVAudioFile?
        var segment = 1
        defer {
            file = nil
            finished.signal()
        }

        while true {
            var rollover = false
            var drained = 0
            var rate: Double = 0
            var channels = 0
            var done = false

            var readFrom = 0
            os_unfair_lock_lock(lock)
            if awaitingRollover && filled == 0 {
                rollover = true
            } else {
                // Decide what to take, but copy it out below with the lock
                // released. Holding the lock across a chunk-sized copy made the
                // audio side's trylock fail constantly under load, and a failed
                // trylock drops the buffer -- which silently loses recorded
                // audio. The critical sections here are now O(1).
                drained = min(filled, Self.drainChunk)
                readFrom = tail
                rate = ringSampleRate
                channels = ringChannels
            }
            os_unfair_lock_unlock(lock)

            if drained > 0 {
                // Safe without the lock: the producer only ever writes to the
                // free region beyond `head`, and `filled` is not reduced until
                // after this copy, so it cannot overwrite what is being read.
                var r = readFrom
                for i in 0..<drained { scratch[i] = ring[r]; r = (r + 1) & Self.ringMask }
                os_unfair_lock_lock(lock)
                tail = r
                filled -= drained
                done = stopping && filled == 0
                os_unfair_lock_unlock(lock)
            } else if !rollover {
                os_unfair_lock_lock(lock)
                done = stopping && filled == 0
                os_unfair_lock_unlock(lock)
            }

            if rollover {
                // Close the old segment BEFORE clearing the flag, so a push
                // that adopts the new format cannot land in the old file.
                file = nil
                segment += 1
                os_unfair_lock_lock(lock)
                ringChannels = 0
                ringSampleRate = 0
                awaitingRollover = false
                os_unfair_lock_unlock(lock)
                continue
            }

            if drained > 0, channels > 0, rate > 0 {
                if file == nil {
                    file = openFile(segment: segment, channels: channels, sampleRate: rate)
                    if file == nil { return }
                }
                if let file { write(scratch, count: drained, channels: channels, to: file) }
            }

            if done { return }
            if drained == 0 { Thread.sleep(forTimeInterval: 0.02) }
        }
    }

    private func segmentURL(_ segment: Int) -> URL {
        guard segment > 1 else { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-\(segment)")
            .appendingPathExtension(ext)
    }

    private func openFile(segment: Int, channels: Int, sampleRate: Double) -> AVAudioFile? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels)) else {
            recordError("Unsupported recording format: \(Int(sampleRate)) Hz, \(channels) ch")
            return nil
        }
        do {
            return try AVAudioFile(forWriting: segmentURL(segment), settings: format.settings)
        } catch {
            // Previously swallowed by try? and retried on every buffer. Report
            // it once and stop, rather than failing silently forever.
            recordError("Could not create the recording file: \(error.localizedDescription)")
            return nil
        }
    }

    private func write(_ samples: UnsafePointer<Float>, count: Int, channels: Int, to file: AVAudioFile) {
        let frames = count / channels
        guard frames > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for f in 0..<frames {
            for c in 0..<channels { dst[c][f] = samples[f * channels + c] }
        }
        do {
            try file.write(from: buffer)
        } catch {
            recordError("Recording stopped: \(error.localizedDescription)")
        }
    }

    private func recordError(_ message: String) {
        NSLog("Audeon.record: %@", message)
        DispatchQueue.main.async { self.writeError = message }
    }
}

/// A swappable mount point for a recorder inside an audio engine. The main
/// thread assigns it; the audio callback reads it on every cycle. Keeping the
/// indirection in one small class lets engines be rebuilt while a recording
/// continues seamlessly on the replacement engine.
///
/// Both sides go through the lock. The audio side only ever *tries* to take it
/// and copies out a strong reference before use, so the main thread cannot
/// release the recorder while a callback is inside it, and the callback never
/// blocks on the main thread.
final class RecorderSlot {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var stored: MixRecorder?

    init() {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Main thread. The previous recorder is released after the lock is
    /// dropped, so deallocation never happens while a callback is waiting.
    func set(_ recorder: MixRecorder?) {
        withExtendedLifetime(replace(with: recorder)) {}
    }

    /// Like `set`, but hands the displaced recorder back instead of releasing
    /// it here. A caller reassigning several slots at once holds a lock across
    /// the batch, and dropping the last reference to a `MixRecorder` runs its
    /// `deinit`, which finishes the file and waits for the writer thread --
    /// none of which should happen with another lock held.
    func replace(with recorder: MixRecorder?) -> MixRecorder? {
        os_unfair_lock_lock(lock)
        let previous = stored
        stored = recorder
        os_unfair_lock_unlock(lock)
        return previous
    }

    /// True when this exact recorder is the one mounted here.
    func holds(_ recorder: MixRecorder) -> Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return stored === recorder
    }

    /// Audio thread. Returns a strong reference, or nil if none is mounted or
    /// the slot is being reassigned this instant. Never blocks.
    func acquire() -> MixRecorder? {
        guard os_unfair_lock_trylock(lock) else { return nil }
        defer { os_unfair_lock_unlock(lock) }
        return stored
    }
}
