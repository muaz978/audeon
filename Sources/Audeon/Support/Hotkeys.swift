import Foundation
import AppKit
import Carbon.HIToolbox

/// A system-wide Option-Command-A shortcut that shows or hides Audeon.
/// Uses the Carbon hot key API, which works without any special permission.
final class ShowHideHotkey {
    static let shared = ShowHideHotkey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func setEnabled(_ on: Bool) {
        on ? register() : unregister()
    }

    private func register() {
        guard hotKeyRef == nil else { return }

        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
                DispatchQueue.main.async { ShowHideHotkey.shared.toggle() }
                return noErr
            }, 1, &eventType, nil, &handlerRef)
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4155444E) /* AUDN */, id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(optionKey | cmdKey),
                            hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
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
final class SuperVolumeKeys {
    static let shared = SuperVolumeKeys()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var volumeBeforeMute: Float?

    /// NX media key codes carried in NSEvent subtype 8 system-defined events.
    private static let soundUp = 0, soundDown = 1, mute = 7

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Returns false when Accessibility access is missing (macOS shows the
    /// grant prompt; the user re-enables the toggle after granting).
    @discardableResult
    func setEnabled(_ on: Bool) -> Bool {
        if !on { stop(); return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }
        return start()
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
            callback: { _, _, cgEvent, _ in
                if SuperVolumeKeys.shared.handle(cgEvent) { return nil }  // swallow
                return Unmanaged.passUnretained(cgEvent)
            },
            userInfo: nil
        ) else {
            NSLog("Audeon.keys: could not create the volume keys event tap")
            return false
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("Audeon.keys: Super Volume Keys active")
        return true
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
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
