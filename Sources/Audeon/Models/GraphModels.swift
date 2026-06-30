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

    init(id: UUID = UUID(), kind: SourceKind, volume: Double = 1.0, isMuted: Bool = false) {
        self.id = id
        self.kind = kind
        self.volume = volume
        self.isMuted = isMuted
    }

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
