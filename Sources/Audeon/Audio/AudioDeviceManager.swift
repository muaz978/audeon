import Foundation
import CoreAudio
import Combine

/// Direction of an audio endpoint.
enum EndpointKind: String, Codable {
    case input
    case output
}

/// A stable description of a CoreAudio device endpoint.
/// We key everything off `uid` (a stable string) rather than the numeric
/// AudioDeviceID, because device IDs can change across re-plug/reboot.
struct AudioEndpoint: Identifiable, Hashable {
    let uid: String          // kAudioDevicePropertyDeviceUID, stable
    let name: String         // human readable
    let kind: EndpointKind   // input or output

    /// Direction-qualified identity. A device that is both an input and an
    /// output shares one `uid`, so routes and anchors must key off this instead.
    var key: String { "\(kind.rawValue):\(uid)" }
    var id: String { key }

    /// Recover the raw device uid from a direction-qualified key.
    static func uid(fromKey key: String) -> String {
        if let range = key.range(of: ":") { return String(key[range.upperBound...]) }
        return key
    }
}

/// Enumerates CoreAudio devices and republishes whenever the device list
/// changes (hot-plug, sample-rate change, default-device change, etc.).
final class AudioDeviceManager: ObservableObject {
    @Published private(set) var inputs: [AudioEndpoint] = []
    @Published private(set) var outputs: [AudioEndpoint] = []

    // Cache: uid -> current AudioDeviceID, resolved fresh on every refresh.
    private var deviceIDByUID: [String: AudioDeviceID] = [:]

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        installDeviceListChangeListener()
    }

    deinit {
        removeDeviceListChangeListener()
    }

    /// Resolve a stable UID to the live AudioDeviceID for engine wiring.
    func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDByUID[uid]
    }

    func endpoint(forUID uid: String) -> AudioEndpoint? {
        inputs.first { $0.uid == uid } ?? outputs.first { $0.uid == uid }
    }

    // MARK: - Enumeration

    func refresh() {
        let ids = Self.allDeviceIDs()
        var newInputs: [AudioEndpoint] = []
        var newOutputs: [AudioEndpoint] = []
        var newMap: [String: AudioDeviceID] = [:]

        for id in ids {
            guard let uid = Self.stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = Self.deviceName(id) else { continue }
            // Hide Audeon's own private aggregate devices from the lists: the
            // per-app capture aggregates ("audeon.redirect.") and the
            // cross-device routing aggregates ("audeon.route."). Matching by a
            // shared "audeon." prefix means any future internal aggregate is
            // hidden automatically without another call site to remember.
            if uid.hasPrefix("audeon.") || name == audeonAggregateName || name == "Audeon Route" { continue }
            newMap[uid] = id

            if Self.channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0 {
                newInputs.append(AudioEndpoint(uid: uid, name: name, kind: .input))
            }
            if Self.channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0 {
                newOutputs.append(AudioEndpoint(uid: uid, name: name, kind: .output))
            }
        }

        let sortedIn = newInputs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let sortedOut = newOutputs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        DispatchQueue.main.async {
            self.deviceIDByUID = newMap
            self.inputs = sortedIn
            self.outputs = sortedOut
        }
    }

    // MARK: - Change listener

    private func installDeviceListChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeDeviceListChangeListener() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    // MARK: - CoreAudio property helpers

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioObjectPropertyName)
            ?? stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let str = value else { return nil }
        return str as String
    }

    /// Number of channels in the given scope (input or output). Zero means the
    /// device does not act in that direction.
    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return 0
        }
        let abl = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
