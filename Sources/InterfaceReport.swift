import AppKit
import Foundation

/// Builds a full description of the connected interface from its USB descriptors — the same
/// data macOS reads when it's plugged in, already cached by macOS. Nothing is sent to the
/// interface, so this is safe on any model.
enum InterfaceReport {
    static func build(state: AppState) -> String {
        var out: [String] = []
        let pid = state.devicePID ?? -1
        let release = aud_device_release()
        let firmware = String(format: "%x.%02x", Int(release >> 8), Int(release & 0xff))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        out.append("**Model:** \(state.deviceName ?? "iD") · USB 2708:\(String(format: "%04x", Int(pid))) · firmware release \(firmware)")
        out.append("**iDVolume:** \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("*Read from the interface's USB descriptors only. Nothing was sent to the interface.*")

        var ptr: UnsafePointer<UInt8>?
        let total = Int(aud_config_descriptor(&ptr))
        guard total > 0, let base = ptr else {
            out.append("\n(Couldn't read the configuration descriptor.)")
            return out.joined(separator: "\n")
        }
        let d = Array(UnsafeBufferPointer(start: base, count: total))
        func word(_ i: Int) -> Int { i + 1 < d.count ? Int(d[i]) | Int(d[i + 1]) << 8 : 0 }
        func hex(_ v: Int, _ w: Int = 2) -> String { "0x" + String(v, radix: 16).leftPad(w) }

        // Interfaces
        out.append("\n**USB interfaces**")
        var i = 0
        var cls = -1, sub = -1
        var units: [String] = []
        let spare = Int(aud_control_interface())
        while i + 2 <= d.count, d[i] >= 2 {
            let len = Int(d[i]), type = Int(d[i + 1])
            if type == 0x04, i + 8 < d.count {
                let num = Int(d[i + 2]), alt = Int(d[i + 3]), eps = Int(d[i + 4])
                cls = Int(d[i + 5]); sub = Int(d[i + 6]); let proto = Int(d[i + 7])
                var line = "- Interface \(num), alt \(alt): class \(hex(cls)) subclass \(hex(sub)) protocol \(hex(proto)) — \(className(cls, sub)), \(eps) endpoint(s)"
                if cls == 0xFE && sub == 0x01 { line += " ⚠ firmware-update (DFU) interface" }
                if num == spare && alt == 0 { line += " ← the interface iDVolume's commands were addressed to" }
                out.append(line)
            } else if type == 0x21, cls == 0xFE, sub == 0x01, len >= 7 {
                let attrs = Int(d[i + 2]), detach = word(i + 3), transfer = word(i + 5)
                out.append("  - DFU functional descriptor: attributes \(hex(attrs)), detach timeout \(detach) ms, transfer size \(transfer)")
            } else if type == 0x24, cls == 0x01, sub == 0x01, len >= 4 {
                units.append(describeUnit(Array(d[i..<min(d.count, i + len)])))
            }
            i += len
        }

        out.append("\n**Audio units**")
        out.append(contentsOf: units.map { "- " + $0 })

        // Raw descriptor, 32 bytes per line
        out.append("\n**Raw configuration descriptor** (\(total) bytes)")
        out.append("```")
        for row in stride(from: 0, to: d.count, by: 32) {
            out.append(d[row..<min(d.count, row + 32)].map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        out.append("```")
        return out.joined(separator: "\n")
    }

    private static func className(_ cls: Int, _ sub: Int) -> String {
        switch (cls, sub) {
        case (0x01, 0x01): return "Audio Control"
        case (0x01, 0x02): return "Audio Streaming"
        case (0x01, 0x03): return "MIDI Streaming"
        case (0x03, _): return "HID"
        case (0xFE, 0x01): return "Device Firmware Update"
        case (0xFE, _): return "Application specific"
        case (0xFF, _): return "Vendor specific"
        default: return "other"
        }
    }

    /// One class-specific AudioControl descriptor (USB Audio 2.0), in words.
    private static func describeUnit(_ u: [UInt8]) -> String {
        func b(_ i: Int) -> Int { i < u.count ? Int(u[i]) : 0 }
        func w(_ i: Int) -> Int { b(i) | b(i + 1) << 8 }
        let sub = b(2), id = b(3)
        let idText = String(format: "0x%02x", id)
        switch sub {
        case 0x02: return "\(idText) input terminal, type \(String(format: "0x%04x", w(4))), \(b(8)) channels"
        case 0x03: return "\(idText) output terminal, type \(String(format: "0x%04x", w(4))), source \(String(format: "0x%02x", b(7)))"
        case 0x04: return "\(idText) mixer unit, \(b(4)) input pin(s)"
        case 0x05: return "\(idText) selector unit, \(b(4)) input pin(s)"
        case 0x06:
            let channels = max(0, (u.count - 6) / 4 - 1)
            let controls = (0...channels).map { ch -> String in
                let o = 5 + ch * 4
                let v = b(o) | b(o + 1) << 8 | b(o + 2) << 16 | b(o + 3) << 24
                return String(format: "%@%08x", ch == 0 ? "master " : "ch\(ch) ", v)
            }.joined(separator: ", ")
            return "\(idText) feature unit, source \(String(format: "0x%02x", b(4))), \(channels) channels, controls [\(controls)]"
        case 0x07, 0x08: return "\(idText) processing unit, type \(String(format: "0x%04x", w(4)))"
        case 0x09: return "\(idText) extension unit, code \(String(format: "0x%04x", w(4))), \(b(6)) input pin(s)"
        case 0x0a: return "\(idText) clock source, attributes \(String(format: "0x%02x", b(4)))"
        case 0x0b: return "\(idText) clock selector, \(b(4)) input pin(s)"
        default: return "\(idText) unit type \(String(format: "0x%02x", sub)), \(u.count) bytes"
        }
    }

    /// Opens a pre-filled GitHub issue. Very long reports are trimmed to fit a web address;
    /// Copy Report always has the full text.
    static func openIssue(state: AppState) {
        var body = build(state: state)
        if body.count > 6500, let cut = body.range(of: "\n**Raw configuration descriptor**") {
            body = String(body[..<cut.lowerBound]) + "\n\n*(Raw descriptor trimmed to fit — please also paste the full text from **Copy Report**.)*"
        }
        var comps = URLComponents(string: "https://github.com/\(Updater.repo)/issues/new")!
        comps.queryItems = [URLQueryItem(name: "title", value: "Interface report: \(state.deviceName ?? "iD")"),
                            URLQueryItem(name: "body", value: body)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    static func copy(state: AppState) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(build(state: state), forType: .string)
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}
