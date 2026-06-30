import Foundation
import CoreAudio
import AppKit
import Combine

/// A running application that the audio system knows about.
struct AudioApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let pid: pid_t
    let processObject: AudioObjectID

    var id: String { bundleID }

    /// The app icon, looked up live from the running application.
    var icon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.processObject == rhs.processObject
    }
}

/// Auto-discovers applications that the audio system is tracking, so they can be
/// shown in the Applications list and routed individually. Uses the Core Audio
/// process object list (macOS 14.2+).
final class AppAudioManager: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var timer: Timer?

    init() {
        refresh()
        installListener()
        // Apps come and go, and not every change posts a notification, so poll
        // gently as a backstop.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
        removeListener()
    }

    func refresh() {
        let objects = Self.processObjects()
        var seen = Set<String>()
        var result: [AudioApp] = []

        for obj in objects {
            guard let pid = Self.pid(of: obj),
                  let running = NSRunningApplication(processIdentifier: pid),
                  running.activationPolicy == .regular,
                  let bundleID = running.bundleIdentifier,
                  !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            let name = running.localizedName ?? bundleID
            result.append(AudioApp(bundleID: bundleID, name: name, pid: pid, processObject: obj))
        }

        let sorted = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async {
            if self.apps != sorted { self.apps = sorted }
        }
    }

    // MARK: - CoreAudio

    private static func processObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &out) == noErr else { return [] }
        return out
    }

    private static func pid(of object: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<pid_t>.size)
        var v: pid_t = 0
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    private func installListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    private func removeListener() {
        guard let block = listenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }
}
