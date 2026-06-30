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
struct Route: Identifiable, Codable, Equatable {
    let id: UUID
    var inputUID: String     // direction-qualified endpoint key, e.g. "input:UID"
    var outputUID: String    // direction-qualified endpoint key, e.g. "output:UID"
    var volume: Double   // 0...1
    var isMuted: Bool
    var isSoloed: Bool

    /// Raw device uids for engine wiring, stripped of the direction prefix.
    var inputDeviceUID: String { AudioEndpoint.uid(fromKey: inputUID) }
    var outputDeviceUID: String { AudioEndpoint.uid(fromKey: outputUID) }

    init(id: UUID = UUID(),
         inputUID: String,
         outputUID: String,
         volume: Double = 0.8,
         isMuted: Bool = false,
         isSoloed: Bool = false) {
        self.id = id
        self.inputUID = inputUID
        self.outputUID = outputUID
        self.volume = volume
        self.isMuted = isMuted
        self.isSoloed = isSoloed
    }

    /// Backwards compatible decoding: older presets have no solo field.
    enum CodingKeys: String, CodingKey {
        case id, inputUID, outputUID, volume, isMuted, isSoloed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        inputUID = try c.decode(String.self, forKey: .inputUID)
        outputUID = try c.decode(String.self, forKey: .outputUID)
        volume = try c.decode(Double.self, forKey: .volume)
        isMuted = try c.decode(Bool.self, forKey: .isMuted)
        isSoloed = try c.decodeIfPresent(Bool.self, forKey: .isSoloed) ?? false
    }
}

/// A named snapshot of routes + colors, like MIXLINE session presets.
struct Preset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var routes: [Route]
    var colors: [String: Int]   // endpoint uid -> ChannelColor.rawValue

    init(id: UUID = UUID(), name: String, routes: [Route], colors: [String: Int]) {
        self.id = id
        self.name = name
        self.routes = routes
        self.colors = colors
    }
}
