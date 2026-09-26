import CoreAudio
import Foundation

enum AudioOutput {
    struct Info { let name: String; let isAudient: Bool }

    /// The current system output device and whether it is an Audient iD.
    static func current() -> Info {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return Info(name: "none", isAudient: false) }
        let name = string(dev, kAudioObjectPropertyName)
        let maker = string(dev, kAudioObjectPropertyManufacturer)
        let uid = string(dev, kAudioDevicePropertyDeviceUID)
        let hay = [name, maker, uid].joined(separator: " ").lowercased()
        let match = hay.contains("audient") || name.range(of: #"^iD\d"#, options: .regularExpression) != nil
        return Info(name: name.isEmpty ? "unknown" : name, isAudient: match)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr, let r = ref else { return "" }
        return r.takeRetainedValue() as String
    }
}
