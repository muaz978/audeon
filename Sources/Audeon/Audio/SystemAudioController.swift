import Foundation
import CoreAudio
import Combine

/// Reads and sets the three system default audio devices, mirroring the
/// "System" section in the example: Output, Input, and Sound Effects (which maps
/// to the system output device used for alerts).
final class SystemAudioController: ObservableObject {
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var defaultInputUID: String?
    @Published private(set) var defaultSystemOutputUID: String?

    private let deviceManager: AudioDeviceManager
    private var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []

    init(deviceManager: AudioDeviceManager) {
        self.deviceManager = deviceManager
        refresh()
        installListeners()
    }

    deinit { removeListeners() }

    func refresh() {
        let out = currentUID(kAudioHardwarePropertyDefaultOutputDevice)
        let inp = currentUID(kAudioHardwarePropertyDefaultInputDevice)
        let sys = currentUID(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let apply = { [self] in
            if defaultOutputUID != out { defaultOutputUID = out }
            if defaultInputUID != inp { defaultInputUID = inp }
            if defaultSystemOutputUID != sys { defaultSystemOutputUID = sys }
        }
        // Applied inline on the main thread so a caller that reads these
        // straight after refresh() (launch-time adoption) sees real values
        // rather than the pre-init nils.
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// Each returns false when the uid does not resolve to a live device or
    /// CoreAudio rejects the change. Callers that are restoring the system
    /// output MUST check it: a silent no-op here leaves the Mac pointed at a
    /// device that produces no sound.
    @discardableResult
    func setDefaultOutput(_ uid: String) -> Bool { setDefault(uid, kAudioHardwarePropertyDefaultOutputDevice) }
    @discardableResult
    func setDefaultInput(_ uid: String) -> Bool { setDefault(uid, kAudioHardwarePropertyDefaultInputDevice) }
    @discardableResult
    func setDefaultSystemOutput(_ uid: String) -> Bool { setDefault(uid, kAudioHardwarePropertyDefaultSystemOutputDevice) }

    // MARK: - Internals

    private func setDefault(_ uid: String, _ selector: AudioObjectPropertySelector) -> Bool {
        guard let id = deviceManager.deviceID(forUID: uid) else { return false }
        var dev = id
        var addr = address(selector)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &dev
        )
        guard status == noErr else { return false }
        refresh()
        return true
    }

    private func currentUID(_ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var dev: AudioObjectID = 0
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev
        ) == noErr, dev != 0 else { return nil }
        return deviceUID(dev)
    }

    private func deviceUID(_ id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var v: CFString? = nil
        let s = withUnsafeMutablePointer(to: &v) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard s == noErr, let v = v else { return nil }
        return v as String
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func installListeners() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var addr = address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
            listeners.append((selector, block))
        }
    }

    private func removeListeners() {
        for (selector, block) in listeners {
            var addr = address(selector)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        }
        listeners.removeAll()
    }
}
