import Foundation
import AppKit
import Carbon.HIToolbox

/// `kAXTrustedCheckOptionPrompt` is imported from ApplicationServices as a
/// mutable global, so every reference to it reads as shared mutable state under
/// strict concurrency checking. It is a constant in practice; read it once here
/// into a `String`, which is `Sendable`.
///
/// One strict-concurrency warning remains on this line and cannot be removed
/// without hardcoding the SDK's string value, which would be worse: the
/// annotation gap is in the imported header, not here. Only the prompting path
/// needs the key at all — the passive check passes nil options.
private let axTrustedCheckOptionPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String

/// A system-wide Option-Command-A shortcut that shows or hides Audeon.
/// Uses the Carbon hot key API, which works without any special permission.
/// Main-actor isolated: registration and teardown are driven from Settings and
/// the app delegate, and the Carbon handler runs on the main event loop.
@MainActor
final class ShowHideHotkey {
    static let shared = ShowHideHotkey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// The Carbon status of the last failed registration, or `noErr` while the
    /// shortcut is live. Option-Command-A can already belong to the system or
    /// to another app; registration then fails and the shortcut would never
    /// fire, so the failure is recorded here instead of vanishing.
    private(set) var lastError: OSStatus = noErr

    /// True while the shortcut is registered and will fire.
    var isRegistered: Bool { hotKeyRef != nil }

    /// Returns false when the shortcut could not be registered; `lastError`
    /// then carries the Carbon status.
    @discardableResult
    func setEnabled(_ on: Bool) -> Bool {
        on ? register() : unregister()
    }

    private func register() -> Bool {
        guard hotKeyRef == nil else { return true }

        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
                DispatchQueue.main.async { ShowHideHotkey.shared.toggle() }
                return noErr
            }, 1, &eventType, nil, &handlerRef)
            guard status == noErr else {
                handlerRef = nil
                lastError = status
                NSLog("Audeon.hotkey: could not install the hot key handler (OSStatus \(status))")
                return false
            }
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4155444E) /* AUDN */, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(optionKey | cmdKey),
                                         hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        guard status == noErr, hotKeyRef != nil else {
            hotKeyRef = nil
            lastError = status
            NSLog("Audeon.hotkey: Option-Command-A is unavailable, another app may already own it (OSStatus \(status))")
            return false
        }
        lastError = noErr
        return true
    }

    private func unregister() -> Bool {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        lastError = noErr
        return true
    }

    private func toggle() {
        if NSApp.isActive {
            NSApp.hide(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.unhide(nil)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }
}

/// Super Volume Keys: intercepts the keyboard volume keys with a session event
/// tap and applies them to the system default output through Audeon's own
/// device volume control, which also serves devices that have no native
/// hardware volume. Opt in, and requires Accessibility access.
/// Main-actor isolated: the event tap's run-loop source is added to
/// `CFRunLoopGetMain()`, so the tap callback runs on the main thread, and every
/// other entry point is driven from Settings or the app delegate.
@MainActor
final class SuperVolumeKeys {
    static let shared = SuperVolumeKeys()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var volumeBeforeMute: Float?

    /// NX media key codes carried in NSEvent subtype 8 system-defined events.
    private static let soundUp = 0, soundDown = 1, mute = 7

    /// Passive check: reports whether Accessibility access is granted without
    /// ever raising the system prompt.
    var isTrusted: Bool {
        //  A nil options dictionary is defined as "check, do not prompt", so the
        //  passive path needs no option key at all.
        AXIsProcessTrustedWithOptions(nil)
    }

    /// Returns false when Accessibility access is missing.
    ///
    /// Pass `prompt: true` only when the user has actively asked to turn the
    /// feature on: that raises the macOS grant prompt, and the user re-enables
    /// the toggle after granting. Restoring the saved setting at launch leaves
    /// `prompt` off, so access revoked since the last run is skipped silently
    /// rather than nagging on every launch.
    @discardableResult
    func setEnabled(_ on: Bool, prompt: Bool = false) -> Bool {
        if !on { stop(); return true }
        guard isTrusted || (prompt && requestTrust()) else { return false }
        return start()
    }

    /// Raises the macOS Accessibility grant prompt. Returns true only when
    /// access is already granted, since the prompt is answered out of process.
    private func requestTrust() -> Bool {
        let options = [axTrustedCheckOptionPrompt: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func start() -> Bool {
        guard tap == nil else { return true }
        // NX_SYSDEFINED events (media keys) are event type 14.
        let mask = CGEventMask(1 << 14)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, refcon in
                // A C function pointer captures nothing, so the instance rides
                // along in the refcon handed to tapCreate below.
                guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
                let keys = Unmanaged<SuperVolumeKeys>.fromOpaque(refcon).takeUnretainedValue()
                // macOS switches a tap off when a callback runs long, and on
                // user input; this callback is the only notice of it. Switch
                // the tap back on and pass the event through unmodified.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    keys.reenable()
                    return Unmanaged.passUnretained(cgEvent)
                }
                if keys.handle(cgEvent) { return nil }  // swallow
                return Unmanaged.passUnretained(cgEvent)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Audeon.keys: could not create the volume keys event tap")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            NSLog("Audeon.keys: could not create the volume keys run loop source")
            return false
        }
        self.tap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("Audeon.keys: Super Volume Keys active")
        return true
    }

    /// Called from the tap callback after macOS disabled the tap.
    private func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("Audeon.keys: the system disabled the volume keys tap; re-enabled it")
    }

    /// Tears the tap down completely: the run loop source is removed and
    /// invalidated and the Mach port is invalidated, so toggling the feature
    /// off and on repeatedly neither leaks nor crashes. Safe to call when
    /// nothing is running.
    private func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
    }

    /// Returns true when the event was a volume key press we consumed.
    private func handle(_ cgEvent: CGEvent) -> Bool {
        guard let event = NSEvent(cgEvent: cgEvent), event.subtype.rawValue == 8 else { return false }
        let keyCode = Int((event.data1 & 0xFFFF0000) >> 16)
        let keyDown = ((event.data1 & 0x0000FF00) >> 8) == 0xA
        guard keyCode == Self.soundUp || keyCode == Self.soundDown || keyCode == Self.mute else { return false }

        if keyDown {
            DispatchQueue.main.async { [weak self] in self?.apply(keyCode) }
        }
        return true   // consume both key down and key up of handled keys
    }

    @MainActor private func apply(_ keyCode: Int) {
        let store = MixerStore.shared
        guard let uid = store.systemAudio.defaultOutputUID else { return }

        // While system audio capture is on, the default output is the virtual
        // sink and its controls are pinned at unity (they scale the capture
        // itself). Steer the System Audio card's volume instead, which is the
        // real master level of everything the user hears.
        if store.deviceManager.isVirtualSystemAudio(uid) {
            guard let source = store.inputs.first(where: { $0.kind == .device(uid) }) else { return }
            switch keyCode {
            case Self.soundUp:
                store.updateInput(source.id) { $0.volume = min(1, $0.volume + 1.0 / 16.0); $0.isMuted = false }
            case Self.soundDown:
                store.updateInput(source.id) { $0.volume = max(0, $0.volume - 1.0 / 16.0) }
            case Self.mute:
                store.updateInput(source.id) { $0.isMuted.toggle() }
            default:
                break
            }
            return
        }

        let dm = store.deviceManager
        let current = dm.outputVolume(forUID: uid) ?? 0
        switch keyCode {
        case Self.soundUp:
            volumeBeforeMute = nil
            dm.setOutputVolume(min(1, current + 1.0 / 16.0), forUID: uid)
        case Self.soundDown:
            volumeBeforeMute = nil
            dm.setOutputVolume(max(0, current - 1.0 / 16.0), forUID: uid)
        case Self.mute:
            if current > 0.0001 {
                volumeBeforeMute = current
                dm.setOutputVolume(0, forUID: uid)
            } else {
                dm.setOutputVolume(volumeBeforeMute ?? 0.5, forUID: uid)
                volumeBeforeMute = nil
            }
        default:
            break
        }
    }
}
