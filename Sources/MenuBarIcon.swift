import AppKit

enum MenuBarStyle: String, CaseIterable {
    case speaker, monitor, knob
}

/// Template images for the status item. All are drawn black; macOS tints them for light/dark menu bars.
enum MenuBarIcon {
    private static let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)

    /// Speaker glyph on a fixed-width canvas, left-aligned, so the speaker body stays put
    /// as the waves change (same behaviour as macOS's own Sound icon).
    static func speaker(symbol: String) -> NSImage {
        guard let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: "Speakers")?
            .withSymbolConfiguration(config) else { return NSImage() }
        let widest = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)?.size ?? sym.size
        let size = NSSize(width: ceil(max(widest.width, sym.size.width)),
                          height: ceil(max(widest.height, sym.size.height)))
        let image = NSImage(size: size, flipped: false) { rect in
            sym.draw(in: NSRect(x: 0, y: (rect.height - sym.size.height) / 2,
                                width: sym.size.width, height: sym.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Studio monitor glyph — clearly "not the system speaker".
    static func monitor(muted: Bool) -> NSImage {
        let image = NSImage(systemSymbolName: muted ? "hifispeaker" : "hifispeaker.fill",
                            accessibilityDescription: "Monitors")?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// Miniature of the app icon: a knob whose ring and pointer show the current level.
    static func knob(level: Double, muted: Bool) -> NSImage {
        let lvl = CGFloat(muted ? 0 : min(1, max(0, level)))
        let image = NSImage(size: NSSize(width: 17, height: 17), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let start: CGFloat = 225, sweep: CGFloat = 270   // 7 o'clock → 5 o'clock
            let end = start - sweep * lvl
            let ringRadius: CGFloat = 7

            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: ringRadius, startAngle: start,
                            endAngle: start - sweep, clockwise: true)
            track.lineWidth = 1.6
            track.lineCapStyle = .round
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()

            if lvl > 0.001 {
                let lit = NSBezierPath()
                lit.appendArc(withCenter: c, radius: ringRadius, startAngle: start, endAngle: end, clockwise: true)
                lit.lineWidth = 1.6
                lit.lineCapStyle = .round
                NSColor.black.setStroke()
                lit.stroke()
            }

            let bodyRadius: CGFloat = 4.4
            NSColor.black.withAlphaComponent(muted ? 0.45 : 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - bodyRadius, y: c.y - bodyRadius,
                                        width: bodyRadius * 2, height: bodyRadius * 2)).fill()

            // Pointer punched out of the knob body.
            let angle = end * .pi / 180
            let pointer = NSBezierPath()
            pointer.move(to: c)
            pointer.line(to: NSPoint(x: c.x + cos(angle) * 3.4, y: c.y + sin(angle) * 3.4))
            pointer.lineWidth = 1.4
            pointer.lineCapStyle = .round
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            pointer.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "iD volume"
        return image
    }

    /// The icon with empty space on its right for the meter bars (drawn separately as layers).
    /// Built only when the icon changes — never per meter update.
    static func padded(_ base: NSImage, extra: CGFloat) -> NSImage {
        let size = NSSize(width: ceil(base.size.width) + extra, height: base.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(origin: .zero, size: base.size))
            return true
        }
        image.isTemplate = true
        return image
    }
}
