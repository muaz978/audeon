import Foundation
import SwiftUI

/// A palette of channel colors, mirroring MIXLINE's color-customizable
/// inputs and outputs. Stored by index so configs stay small and stable.
enum ChannelColor: Int, Codable, CaseIterable, Identifiable {
    case blue, teal, green, yellow, orange, red, pink, purple

    var id: Int { rawValue }

    var color: Color {
        switch self {
        case .blue:   return Color(red: 0.20, green: 0.55, blue: 0.95)
        case .teal:   return Color(red: 0.10, green: 0.70, blue: 0.70)
        case .green:  return Color(red: 0.25, green: 0.75, blue: 0.40)
        case .yellow: return Color(red: 0.95, green: 0.80, blue: 0.20)
        case .orange: return Color(red: 0.95, green: 0.55, blue: 0.20)
        case .red:    return Color(red: 0.90, green: 0.30, blue: 0.30)
        case .pink:   return Color(red: 0.95, green: 0.40, blue: 0.65)
        case .purple: return Color(red: 0.60, green: 0.40, blue: 0.90)
        }
    }
}

/// A live audio route from an input endpoint to an output endpoint.
struct Route: Identifiable, Equatable {
    let id: UUID
    var inputUID: String     // direction-qualified endpoint key, e.g. "input:UID"
    var outputUID: String    // direction-qualified endpoint key, e.g. "output:UID"
    var volume: Double   // 0...1
    var isMuted: Bool
    var boost: Double        // 1...4
    var eqEnabled: Bool
    var eq: [Double]         // band gains in dB

    /// Raw device uids for engine wiring, stripped of the direction prefix.
    var inputDeviceUID: String { AudioEndpoint.uid(fromKey: inputUID) }
    var outputDeviceUID: String { AudioEndpoint.uid(fromKey: outputUID) }

    init(id: UUID = UUID(),
         inputUID: String,
         outputUID: String,
         volume: Double = 0.8,
         isMuted: Bool = false,
         boost: Double = 1.0,
         eqEnabled: Bool = false,
         eq: [Double] = AudioEQ.flat) {
        self.id = id
        self.inputUID = inputUID
        self.outputUID = outputUID
        self.volume = volume
        self.isMuted = isMuted
        self.boost = boost
        self.eqEnabled = eqEnabled
        self.eq = eq
    }
}
