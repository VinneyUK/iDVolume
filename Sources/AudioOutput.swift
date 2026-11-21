import CoreAudio
import Foundation

import os

enum AudioOutput {
    struct Info: Equatable { let name: String; let isAudient: Bool }

    private static let log = Logger(subsystem: "com.vinneyuk.idvolume", category: "output")
    /// Latest known output, kept up to date by `watch` (read on every volume key press).
    private(set) static var cached: Info?
    private static var watching = false

    /// Follow changes of the system output. Calls `changed` on the main queue after each switch.
    /// Asking Core Audio from inside the key tap on every press could return a stale device after
    /// switching outputs (keys then went to e.g. a monitor's speakers until relaunch).
    static func watch(_ changed: @escaping (Info) -> Void) {
        guard !watching else { return }
        watching = true
        // Let Core Audio deliver its notifications on its own thread rather than relying on ours.
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyRunLoop,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var runLoop: CFRunLoop? = nil
        _ = withUnsafeMutablePointer(to: &runLoop) { ptr in
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                       UInt32(MemoryLayout<CFRunLoop?>.size), ptr)
        }
        cached = current()
        log.info("output: \(cached?.name ?? "?", privacy: .public) audient=\(cached?.isAudient ?? false)")
        var def = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &def, DispatchQueue.main) { _, _ in
            // Read it a few times over the next second: the new device can take a moment to settle.
            for delay in [0.0, 0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    let now = current()
                    guard now != cached else { return }
                    cached = now
                    log.info("output changed: \(now.name, privacy: .public) audient=\(now.isAudient)")
                    changed(now)
                }
            }
        }
    }

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
