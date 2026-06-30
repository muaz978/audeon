import Foundation
import CoreAudio

/// Per-device hardware controls used by the System detail panel: output volume
/// and sample rate. These map to standard CoreAudio device properties.
extension AudioDeviceManager {

    // MARK: - Volume (0...1)

    func outputVolume(forUID uid: String) -> Float? {
        volume(forUID: uid, scope: kAudioObjectPropertyScopeOutput)
    }
    func setOutputVolume(_ value: Float, forUID uid: String) {
        setVolume(value, forUID: uid, scope: kAudioObjectPropertyScopeOutput)
    }
    func inputVolume(forUID uid: String) -> Float? {
        volume(forUID: uid, scope: kAudioObjectPropertyScopeInput)
    }
    func setInputVolume(_ value: Float, forUID uid: String) {
        setVolume(value, forUID: uid, scope: kAudioObjectPropertyScopeInput)
    }

    /// True when the device exposes any settable software volume in this scope.
    func hasVolumeControl(forUID uid: String, scope: AudioObjectPropertyScope) -> Bool {
        guard let id = deviceID(forUID: uid) else { return false }
        return [kAudioObjectPropertyElementMain, 1, 2].contains {
            var addr = Self.volumeAddress($0, scope)
            return AudioObjectHasProperty(id, &addr)
        }
    }

    private func volume(forUID uid: String, scope: AudioObjectPropertyScope) -> Float? {
        guard let id = deviceID(forUID: uid) else { return nil }
        if let v = Self.volume(id, element: kAudioObjectPropertyElementMain, scope: scope) { return v }
        let l = Self.volume(id, element: 1, scope: scope)
        let r = Self.volume(id, element: 2, scope: scope)
        switch (l, r) {
        case let (l?, r?): return (l + r) / 2
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    private func setVolume(_ value: Float, forUID uid: String, scope: AudioObjectPropertyScope) {
        guard let id = deviceID(forUID: uid) else { return }
        let v = max(0, min(1, value))
        if Self.setVolume(id, element: kAudioObjectPropertyElementMain, scope: scope, value: v) { return }
        _ = Self.setVolume(id, element: 1, scope: scope, value: v)
        _ = Self.setVolume(id, element: 2, scope: scope, value: v)
    }

    private static func volumeAddress(_ element: AudioObjectPropertyElement, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: element
        )
    }

    private static func volume(_ id: AudioObjectID, element: AudioObjectPropertyElement, scope: AudioObjectPropertyScope) -> Float? {
        var addr = volumeAddress(element, scope)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var size = UInt32(MemoryLayout<Float32>.size)
        var v: Float32 = 0
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    private static func setVolume(_ id: AudioObjectID, element: AudioObjectPropertyElement, scope: AudioObjectPropertyScope, value: Float) -> Bool {
        var addr = volumeAddress(element, scope)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { return false }
        var v = Float32(value)
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    // MARK: - Sample rate

    func sampleRate(forUID uid: String) -> Double? {
        guard let id = deviceID(forUID: uid) else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Float64>.size)
        var v: Float64 = 0
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    func setSampleRate(_ rate: Double, forUID uid: String) {
        guard let id = deviceID(forUID: uid) else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var v = Float64(rate)
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &v)
    }

    // MARK: - Preferred stereo channels (Left / Right)

    func preferredStereoChannels(forUID uid: String) -> (left: Int, right: Int)? {
        guard let id = deviceID(forUID: uid) else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var chans: [UInt32] = [0, 0]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &chans) == noErr else { return nil }
        return (Int(chans[0]), Int(chans[1]))
    }

    func setPreferredStereoChannels(left: Int, right: Int, forUID uid: String) {
        guard let id = deviceID(forUID: uid) else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var chans: [UInt32] = [UInt32(left), UInt32(right)]
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size * 2), &chans)
    }

    /// Total output channel count, used to bound the Left/Right pickers.
    func outputChannelCount(forUID uid: String) -> Int {
        guard let id = deviceID(forUID: uid) else { return 0 }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func availableSampleRates(forUID uid: String) -> [Double] {
        guard let id = deviceID(forUID: uid) else { return [] }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        // Expand discrete rates; ranges usually carry mMinimum == mMaximum.
        var rates: [Double] = []
        for r in ranges {
            if r.mMinimum == r.mMaximum { rates.append(r.mMinimum) }
            else { rates.append(r.mMaximum) }
        }
        return Array(Set(rates)).sorted()
    }
}
