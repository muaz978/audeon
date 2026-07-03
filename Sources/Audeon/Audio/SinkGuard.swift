import Foundation
import CoreAudio

/// Keeps the virtual capture sink pinned at unity gain while system audio
/// capture is active. The sink's driver applies its own volume and mute to the
/// audio it stores, so the keyboard volume keys or System Settings acting on
/// it (it is the default output while capturing) would silently scale the
/// entire capture toward zero. This watcher listens for those control changes
/// and immediately restores full volume, unmuted.
final class SinkGuard {
    private let deviceManager: AudioDeviceManager
    private var deviceID: AudioObjectID = 0
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private(set) var isActive = false

    init(deviceManager: AudioDeviceManager) {
        self.deviceManager = deviceManager
    }

    func activate(uid: String) {
        deactivate()
        guard let id = deviceManager.deviceID(forUID: uid) else { return }
        deviceID = id
        // Pin immediately, then again on every change notification.
        deviceManager.forceUnityGain(forUID: uid)

        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2] {
                    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
                    guard AudioObjectHasProperty(id, &address) else { continue }
                    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                        guard let self, self.isActive else { return }
                        self.deviceManager.forceUnityGain(forUID: uid)
                    }
                    AudioObjectAddPropertyListenerBlock(id, &address, DispatchQueue.main, block)
                    listeners.append((address, block))
                }
            }
        }
        isActive = true
        NSLog("Audeon.sink: guarding \(uid) at unity gain (\(listeners.count) control listeners)")
    }

    func deactivate() {
        guard !listeners.isEmpty || isActive else { return }
        for (address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &addr, DispatchQueue.main, block)
        }
        listeners.removeAll()
        isActive = false
        deviceID = 0
    }

    deinit { deactivate() }
}
