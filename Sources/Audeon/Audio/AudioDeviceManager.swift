import Foundation
import CoreAudio
import Combine
import os

/// Direction of an audio endpoint.
enum EndpointKind: String, Codable {
    case input
    case output
}

/// Identity of the Audeon virtual audio device (the installed HAL driver).
/// Audio the Mac plays into this device is captured on its input side, which
/// is how Audeon grabs whole-system audio and fans it back out to real
/// outputs. Kept as constants so detection lives in one place.
let audeonVirtualDeviceUID = "Audeon_UID"
let audeonVirtualDeviceName = "Audeon Stream"

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
///
/// Concurrency: `@unchecked Sendable`. The routing engines hold a reference to
/// this object and resolve uids from their own work queues, so this claim has
/// to be earned rather than assumed. Field by field:
///
/// - `inputs`, `outputs`: main thread only. `refresh()` does its enumeration in
///   locals and publishes through `apply`, which runs inline only when
///   `Thread.isMainThread` and is dispatched to `.main` otherwise. Every reader
///   is on the main actor: `endpoint(forUID:)`, `isVirtualSystemAudio(_:)` and
///   `systemAudioSinkUID` are called from `MixerStore` (`@MainActor`), the
///   views, `SinkGuard` and `SystemAudioController`, both of which are driven
///   from the main queue.
/// - `deviceIDByUID`: guarded by `mapLock`, at both accesses. This is the one
///   piece of state a background queue reads, which is why it has a lock and
///   the published arrays do not.
/// - `listenerBlock`: written once by `installDeviceListChangeListener()` from
///   `init`, read once by `removeDeviceListChangeListener()` from `deinit`, and
///   never touched in between.
/// - `mapLock`: immutable, and a pointer is Sendable.
///
/// Note what this does *not* say: the `DeviceControls` extension is safe from a
/// work queue only because those methods go through `deviceID(forUID:)` and
/// then make stateless CoreAudio property calls. Anything added there that
/// reads `inputs` or `outputs` would have to be main-thread only.
final class AudioDeviceManager: ObservableObject, @unchecked Sendable {
    @Published private(set) var inputs: [AudioEndpoint] = []
    @Published private(set) var outputs: [AudioEndpoint] = []

    // Cache: uid -> current AudioDeviceID, resolved fresh on every refresh.
    //
    // Guarded by `mapLock`, not confined to the main thread: the routing
    // engines resolve uids from their own work queues so the HAL calls that
    // follow stay off the main thread. Writes still only happen on the main
    // thread, and the critical sections are single dictionary operations.
    private var deviceIDByUID: [String: AudioDeviceID] = [:]
    private let mapLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        mapLock.initialize(to: os_unfair_lock())
        refresh()
        installDeviceListChangeListener()
    }

    deinit {
        removeDeviceListChangeListener()
        mapLock.deinitialize(count: 1)
        mapLock.deallocate()
    }

    /// Resolve a stable UID to the live AudioDeviceID for engine wiring.
    /// Safe to call from any thread.
    func deviceID(forUID uid: String) -> AudioDeviceID? {
        os_unfair_lock_lock(mapLock); defer { os_unfair_lock_unlock(mapLock) }
        return deviceIDByUID[uid]
    }

    func endpoint(forUID uid: String) -> AudioEndpoint? {
        inputs.first { $0.uid == uid } ?? outputs.first { $0.uid == uid }
    }

    /// True when the given uid is a whole-system capture sink, so the UI can
    /// keep it out of the raw device pickers (it is used only via System Audio)
    /// and the restore paths never hand the system default back to it.
    ///
    /// This must recognize every uid `systemAudioSinkUID` can return, not just
    /// the Audeon device: when the driver is not installed the app selects a
    /// BlackHole output as the sink itself, and restoring the system default to
    /// the sink is exactly the silence those paths exist to prevent.
    func isVirtualSystemAudio(_ uid: String) -> Bool {
        if uid == audeonVirtualDeviceUID { return true }
        if uid.localizedCaseInsensitiveContains("blackhole") { return true }
        if let endpoint = outputs.first(where: { $0.uid == uid }) {
            return endpoint.name.localizedCaseInsensitiveContains("blackhole")
        }
        return false
    }

    /// True when the uid resolves to a live device that can actually be made
    /// the system default. Restore paths must check this: a uid for an
    /// unplugged device, or a synthetic Output Group uid, silently no-ops.
    func isUsableOutput(_ uid: String) -> Bool {
        deviceID(forUID: uid) != nil && !isVirtualSystemAudio(uid)
    }

    /// The best available whole-system capture sink: the Audeon virtual device
    /// if its driver is installed, otherwise BlackHole if present, else nil.
    /// Driver-agnostic so the System Audio feature works either way.
    var systemAudioSinkUID: String? {
        if deviceID(forUID: audeonVirtualDeviceUID) != nil { return audeonVirtualDeviceUID }
        if let bh = outputs.first(where: { $0.name.localizedCaseInsensitiveContains("blackhole") }) {
            return bh.uid
        }
        return nil
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

        // `@Sendable`, not `@MainActor @Sendable`: a nonisolated function
        // converts freely to a main-actor-isolated parameter, so the
        // `async(execute:)` call below needs no change and no
        // `MainActor.assumeIsolated` check is introduced. `newMap` is captured
        // by value because a by-reference capture of a `var` in a `@Sendable`
        // closure is diagnosed in the plain build too; nothing mutates it after
        // this point, so the copy costs nothing.
        let apply: @Sendable () -> Void = { [self, newMap] in
            // Publish only on change. Destroying an aggregate device fires a
            // device-list notification, so republishing unconditionally let a
            // route that could never start drive an endless
            // rebuild -> notify -> reconcile -> rebuild loop on the main thread.
            os_unfair_lock_lock(mapLock)
            let mapChanged = deviceIDByUID != newMap
            if mapChanged { deviceIDByUID = newMap }
            os_unfair_lock_unlock(mapLock)
            if mapChanged { objectWillChange.send() }
            if inputs != sortedIn { inputs = sortedIn }
            if outputs != sortedOut { outputs = sortedOut }
        }

        // Callers on the main thread (init, reapply) read this state
        // immediately after calling refresh(). Deferring the assignment to the
        // next main-loop turn made those reads see an empty device map, which
        // is what left adoptSystemAudioStateOnLaunch() permanently unable to
        // succeed. Apply inline when we are already on the main thread.
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
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
