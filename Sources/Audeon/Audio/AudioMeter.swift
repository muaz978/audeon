import Foundation
import AVFoundation

/// A single meter sample, normalized for display.
struct MeterReading: Equatable {
    var level: Float    // 0...1, normalized from dBFS for a meter bar
    var peakDB: Float   // peak in dBFS, e.g. -12.3
    var clip: Bool       // true when the signal hit or passed full scale

    static let silent = MeterReading(level: 0, peakDB: -120, clip: false)
}

enum AudioMeter {
    private static let floorDB: Float = -60

    static func reading(for buffer: AVAudioPCMBuffer) -> MeterReading {
        guard let data = buffer.floatChannelData else { return .silent }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return .silent }
        let channels = Int(buffer.format.channelCount)

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
        let rmsDB = rms > 0 ? 20 * log10(rms) : floorDB
        let peakDB = peak > 0 ? 20 * log10(peak) : floorDB
        let level = min(1, max(0, (rmsDB - floorDB) / -floorDB))
        return MeterReading(level: level, peakDB: max(floorDB, peakDB), clip: peak >= 0.999)
    }

    /// Combine several readings (e.g. several routes feeding the same output)
    /// by taking the loudest, which is the meaningful value for a shared bar.
    static func combine(_ readings: [MeterReading]) -> MeterReading {
        readings.max { $0.peakDB < $1.peakDB } ?? .silent
    }
}

/// Throttles how often a real-time audio tap callback is allowed to publish to
/// the UI, so the meter updates smoothly without flooding SwiftUI.
final class MeterThrottle {
    private var lastFire: CFAbsoluteTime = 0
    private let minInterval: CFAbsoluteTime

    init(updatesPerSecond: Double = 12) {
        self.minInterval = 1.0 / updatesPerSecond
    }

    /// Returns true when enough time has passed and the caller should publish.
    func shouldFire() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFire >= minInterval else { return false }
        lastFire = now
        return true
    }
}
