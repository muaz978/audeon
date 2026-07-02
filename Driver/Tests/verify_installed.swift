// Post-install verification for the Audeon virtual audio driver.
//
// Asks the live CoreAudio system whether an "Audeon Stream" device now
// exists, and reads its shape. Talking to CoreAudio at all also proves
// coreaudiod is alive and answering (a crash-looping daemon would make
// these calls hang or fail), so this doubles as a health check.
//
// Needs no admin rights. Run after installing:  swift Tests/verify_installed.swift

import CoreAudio
import Foundation

func allDeviceIDs() -> [AudioDeviceID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func str(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size); var v: CFString? = nil
    let s = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    guard s == noErr, let v = v else { return nil }
    return v as String
}

func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, buf) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

let ids = allDeviceIDs()
print("CoreAudio responded with \(ids.count) devices (coreaudiod is alive).\n")

var found = false
for id in ids {
    let name = str(id, kAudioObjectPropertyName) ?? "?"
    let uid = str(id, kAudioDevicePropertyDeviceUID) ?? "?"
    if name.localizedCaseInsensitiveContains("audeon") || uid.localizedCaseInsensitiveContains("audeon") {
        found = true
        print("FOUND the Audeon device:")
        print("  name:     \(name)")
        print("  uid:      \(uid)")
        print("  input ch: \(channels(id, kAudioObjectPropertyScopeInput))")
        print("  output ch:\(channels(id, kAudioObjectPropertyScopeOutput))")
    }
}

print("")
if found {
    print("== SUCCESS: the Audeon virtual device is live in the system. ==")
    exit(0)
} else {
    print("== NOT FOUND: no Audeon device is registered yet. ==")
    print("Likely causes: install not run, coreaudiod not restarted, or macOS")
    print("declined to load an ad-hoc-signed plug-in. Recovery is clean either")
    print("way: sudo Driver/recover-audio.sh")
    exit(1)
}
