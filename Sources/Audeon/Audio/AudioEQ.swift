import Foundation

/// Shared definitions for the 10 band equalizer and the volume boost.
enum AudioEQ {
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static var bandCount: Int { frequencies.count }
    static let gainRange: ClosedRange<Double> = -12...12

    /// Named starting points, mirroring a typical graphic EQ preset list.
    static let presets: [(name: String, gains: [Double])] = [
        ("Flat",         [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Boost",   [7, 6, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Treble Boost", [0, 0, 0, 0, 0, 1, 2, 4, 6, 7]),
        ("Vocal",        [-3, -2, 0, 2, 4, 4, 3, 1, 0, -1]),
        ("Loudness",     [6, 4, 0, -1, -2, -1, 0, 3, 5, 6]),
    ]

    static var flat: [Double] { Array(repeating: 0, count: bandCount) }

    /// Boost multiplier (1x...4x) expressed as decibels for the EQ global gain.
    static func boostDecibels(_ multiplier: Double) -> Float {
        guard multiplier > 0 else { return 0 }
        return Float(20 * log10(multiplier))
    }

    static func shortLabel(forFrequency hz: Float) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }
}
