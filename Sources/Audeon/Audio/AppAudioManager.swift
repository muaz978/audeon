import Foundation
import CoreAudio
import AppKit
import Combine

/// A running application that the audio system knows about. An app can own
/// several audio processes at once (browsers play each tab from a separate
/// helper process), so we keep all of them and tap them together.
struct AudioApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let pid: pid_t                       // the owning regular app (for icon)
    let processObjects: [AudioObjectID]  // every audio process this app owns

    var id: String { bundleID }

    /// The app icon, looked up live from the running application.
    var icon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.processObjects == rhs.processObjects
    }
}

/// Auto-discovers applications that the audio system is tracking, so they can be
/// shown in the Applications list and routed individually. Uses the Core Audio
/// process object list (macOS 14.2+).
///
/// Concurrency: `@unchecked Sendable`, because every stored property is
/// confined to the main thread:
///
/// - `apps`, `runningBundleIDs`: written only inside the
///   `DispatchQueue.main.async` block that closes `refresh()`, and read only
///   from `MixerStore` and the views, which are `@MainActor`.
/// - `listenerBlock`, `timer`, `workspaceObservers`: established by `init` on
///   the main thread and torn down by `deinit`. Nothing writes them in between,
///   and nothing else reads them.
///
/// `refresh()` is the only method that could plausibly be called from another
/// thread, and it holds no stored property while it works: the enumeration runs
/// entirely in locals and static helpers, and only the trailing main-queue block
/// touches `self`. In practice every caller is already on the main thread — the
/// initializer, the workspace observers (`queue: .main`), the backstop `Timer`
/// on the main run loop, and the CoreAudio process-list listener, which is
/// installed with `DispatchQueue.main`. That belt-and-braces arrangement is why
/// this type needs no lock at all.
final class AppAudioManager: ObservableObject, @unchecked Sendable {
    @Published private(set) var apps: [AudioApp] = []
    /// Bundle ids of all regular apps currently running, regardless of whether
    /// they have produced audio yet. Drives the active state of input cards.
    @Published private(set) var runningBundleIDs: Set<String> = []

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var timer: Timer?

    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        refresh()
        installListener()
        installWorkspaceObservers()
        // Backstop poll in case a notification is missed.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
        removeListener()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// React immediately when any app launches or quits, so a reopened input
    /// reactivates and reconnects without waiting for the poll.
    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Give CoreAudio a moment to register the new process, then refresh.
                self?.refresh()
                // Its own capture list rather than a reference to the outer
                // block's `self`: same weak semantics, but the deferred block
                // no longer reads a variable another block owns.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
            }
            workspaceObservers.append(token)
        }
    }

    func refresh() {
        let objects = Self.processObjects()

        // Group every audio process object under its owning regular app. A raw
        // audio process is often a child helper (browsers, Electron apps), so
        // resolve it up to the visible application before grouping.
        struct Group { let app: NSRunningApplication; var objects: [AudioObjectID] }
        var byBundle: [String: Group] = [:]
        for obj in objects {
            guard let pid = Self.pid(of: obj),
                  let owner = Self.owningRegularApp(pid: pid),
                  let bundleID = owner.bundleIdentifier else { continue }
            if byBundle[bundleID] == nil { byBundle[bundleID] = Group(app: owner, objects: []) }
            byBundle[bundleID]?.objects.append(obj)
        }

        let result = byBundle.map { bundleID, group in
            AudioApp(bundleID: bundleID,
                     name: group.app.localizedName ?? bundleID,
                     pid: group.app.processIdentifier,
                     processObjects: group.objects.sorted())
        }

        let sorted = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let running = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleIdentifier })
        DispatchQueue.main.async {
            if self.apps != sorted { self.apps = sorted }
            if self.runningBundleIDs != running { self.runningBundleIDs = running }
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

    /// Resolve an audio process pid to the visible regular application that owns
    /// it. Audio often comes from a child helper (Microsoft Edge Helper, Chrome
    /// renderer, Electron GPU process); walking the parent chain, then falling
    /// back to a bundle-id prefix match, maps it back to Edge/Chrome/etc.
    private static func owningRegularApp(pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular, app.bundleIdentifier != nil {
                return app
            }
            guard let parent = parentPID(of: current), parent > 1, parent != current else { break }
            current = parent
        }
        // Fallback: a helper's bundle id ("com.microsoft.edgemac.helper") starts
        // with the main app's bundle id. Find the running app that matches.
        if let helperBundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
            // Require the match to end on a component boundary. A bare prefix
            // test also matched unrelated neighbours ("com.acme.mail" against
            // "com.acme.mailbox"), so routing one app tapped and muted another.
            return NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular
                    && ($0.bundleIdentifier.map {
                        helperBundle == $0 || helperBundle.hasPrefix($0 + ".")
                    } ?? false)
            }
        }
        return nil
    }

    /// Parent pid via sysctl (public API), for the process-tree walk.
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let ok = mib.withUnsafeMutableBufferPointer { buf in
            sysctl(buf.baseAddress, 4, &info, &size, nil, 0) == 0
        }
        guard ok, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
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
