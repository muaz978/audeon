import Foundation

/// An input source on the canvas: either a capture device or a running app.
enum SourceKind: Codable, Equatable, Hashable {
    case device(String)   // input device uid
    case app(String)      // app bundle id
}

/// An added input card. The user adds these with "Add input".
struct InputSource: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: SourceKind
    var volume: Double     // 0...1
    var isMuted: Bool
    var boost: Double      // 1...4 volume overdrive multiplier
    var eqEnabled: Bool
    var eq: [Double]       // per band gain in dB, length AudioEQ.bandCount

    init(id: UUID = UUID(), kind: SourceKind, volume: Double = 1.0, isMuted: Bool = false,
         boost: Double = 1.0, eqEnabled: Bool = false, eq: [Double] = AudioEQ.flat) {
        self.id = id
        self.kind = kind
        self.volume = volume
        self.isMuted = isMuted
        self.boost = boost
        self.eqEnabled = eqEnabled
        self.eq = eq
    }

    enum CodingKeys: String, CodingKey { case id, kind, volume, isMuted, boost, eqEnabled, eq }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(SourceKind.self, forKey: .kind)
        volume = try c.decode(Double.self, forKey: .volume)
        isMuted = try c.decode(Bool.self, forKey: .isMuted)
        boost = try c.decodeIfPresent(Double.self, forKey: .boost) ?? 1.0
        eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? false
        let stored = try c.decodeIfPresent([Double].self, forKey: .eq) ?? AudioEQ.flat
        eq = stored.count == AudioEQ.bandCount ? stored : AudioEQ.flat
    }

    /// Linear gain before EQ, combining volume, mute, and boost.
    var effectiveGain: Float { isMuted ? 0 : Float(volume) }

    /// Stable string used for color keys and pin anchors.
    var pinKey: String { "src:\(id.uuidString)" }
}

/// An added output card (an output device). The user adds these with "Add output".
struct OutputTarget: Identifiable, Codable, Equatable {
    let id: UUID
    var uid: String        // output device uid
    var volume: Double
    var isMuted: Bool

    init(id: UUID = UUID(), uid: String, volume: Double = 1.0, isMuted: Bool = false) {
        self.id = id
        self.uid = uid
        self.volume = volume
        self.isMuted = isMuted
    }

    var pinKey: String { "out:\(id.uuidString)" }
}

/// A cable from an input source to an output target. Many to one is allowed:
/// several sources can connect to the same output, and one source can connect
/// to several outputs.
struct Connection: Identifiable, Codable, Equatable {
    let id: UUID
    var sourceID: UUID
    var outputID: UUID

    init(id: UUID = UUID(), sourceID: UUID, outputID: UUID) {
        self.id = id
        self.sourceID = sourceID
        self.outputID = outputID
    }
}
