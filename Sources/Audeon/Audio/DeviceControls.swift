import Foundation
import CoreAudio

/// Per-device hardware controls used by the System detail panel: output volume
/// and sample rate. These map to standard CoreAudio device properties.
extension AudioDeviceManager {

    // MARK: - Output volume (0...1)

    func outputVolume(forUID uid: String) -> Float? {
        guard let id = deviceID(forUID: uid) else { return nil }
        if let v = Self.volume(id, element: kAudioObjectPropertyElementMain) { return v }
        // Fall back to the average of the first two channels.
        let l = Self.volume(id, element: 1)
        let r = Self.volume(id, element: 2)
        switch (l, r) {
        case let (l?, r?): return (l + r) / 2
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    func setOutputVolume(_ value: Float, forUID uid: String) {
        guard let id = deviceID(forUID: uid) else { return }
        let v = max(0, min(1, value))
        if Self.setVolume(id, element: kAudioObjectPropertyElementMain, value: v) { return }
        _ = Self.setVolume(id, element: 1, value: v)
        _ = Self.setVolume(id, element: 2, value: v)
    }

    private static func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }

    private static func volume(_ id: AudioObjectID, element: AudioObjectPropertyElement) -> Float? {
        var addr = volumeAddress(element)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var size = UInt32(MemoryLayout<Float32>.size)
        var v: Float32 = 0
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    private static func setVolume(_ id: AudioObjectID, element: AudioObjectPropertyElement, value: Float) -> Bool {
        var addr = volumeAddress(element)
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
