import AVFoundation
import AudioToolbox

/// Wraps Apple's built-in Dynamics Processor Audio Unit, tuned to lift quiet
/// passages and tame loud peaks, in the spirit of SoundSource's Magic Boost.
enum MagicBoost {
    static func makeEffect() -> AVAudioUnitEffect {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        let effect = AVAudioUnitEffect(audioComponentDescription: desc)
        configure(effect, enabled: false)
        return effect
    }

    /// Tuned for speech and game audio: pull up quiet content, leave loud
    /// content mostly alone, with a touch of master gain.
    static func configure(_ effect: AVAudioUnitEffect, enabled: Bool) {
        let unit = effect.audioUnit
        let params: [(AudioUnitParameterID, AudioUnitParameterValue)] = enabled
            ? [
                (kDynamicsProcessorParam_Threshold, Float(-26)),
                (kDynamicsProcessorParam_HeadRoom, Float(12)),
                (kDynamicsProcessorParam_ExpansionRatio, Float(3)),
                (kDynamicsProcessorParam_ExpansionThreshold, Float(-68)),
                (kDynamicsProcessorParam_AttackTime, Float(0.003)),
                (kDynamicsProcessorParam_ReleaseTime, Float(0.15)),
                (kDynamicsProcessorParam_OverallGain, Float(6)),
              ]
            : [
                (kDynamicsProcessorParam_Threshold, Float(0)),
                (kDynamicsProcessorParam_HeadRoom, Float(40)),
                (kDynamicsProcessorParam_ExpansionRatio, Float(1)),
                (kDynamicsProcessorParam_OverallGain, Float(0)),
              ]
        for (param, value) in params {
            AudioUnitSetParameter(unit, param, kAudioUnitScope_Global, 0, value, 0)
        }
        effect.bypass = !enabled
    }
}
