import AppKit

enum MediaKey { case up, down, mute }

/// Intercepts the hardware volume keys (F10/F11/F12 or Touch Bar) via a CGEvent tap.
final class MediaKeyTap {
    /// Return true to swallow the event.
    var handler: ((MediaKey, Bool, NSEvent.ModifierFlags) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool {
        guard let t = tap else { return false }
        if !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
        return CGEvent.tapIsEnabled(tap: t)
    }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << 14)  // NX_SYSDEFINED
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: mediaKeyCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event),
              ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return pass }

        let code = (ns.data1 & 0xFFFF_0000) >> 16
        let down = ((ns.data1 & 0xFF00) >> 8) == 0x0A
        let key: MediaKey
        switch code {
        case 0: key = .up     // NX_KEYTYPE_SOUND_UP
        case 1: key = .down   // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute   // NX_KEYTYPE_MUTE
        default: return pass
        }
        return (handler?(key, down, ns.modifierFlags) ?? false) ? nil : pass
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
