import AppKit
import QuartzCore

/// Two thin level bars drawn with Core Animation layers on the status item button.
/// Updating the meter only changes layer heights — no new images, so no graphics memory churn.
final class MenuBarMeter {
    static let width: CGFloat = 8
    private let host = CALayer()
    private let tracks = [CALayer(), CALayer()]
    private let fills = [CALayer(), CALayer()]
    private var lastLeft = -999.0, lastRight = -999.0
    private var lastFrame = CGRect.zero
    private var lastMono = false
    private var cachedColor: CGColor?
    private var cachedAppearance: NSAppearance.Name?

    init() {
        for i in 0..<2 {
            tracks[i].cornerRadius = 1
            fills[i].cornerRadius = 1
            host.addSublayer(tracks[i])
            host.addSublayer(fills[i])
        }
        host.isHidden = true
    }

    func attach(to button: NSStatusBarButton) {
        button.wantsLayer = true
        if host.superlayer == nil { button.layer?.addSublayer(host) }
    }

    func hide() {
        host.isHidden = true
        lastLeft = -999; lastRight = -999
    }

    /// Speaker L/R in dBFS; bars span −48…0. In mono, a single centred bar shows the level.
    func update(on button: NSStatusBarButton, left: Double, right: Double, mono: Bool = false) {
        let imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
        let frame = CGRect(x: imageRect.maxX - Self.width + 1, y: imageRect.minY + 2,
                           width: Self.width - 1, height: max(4, imageRect.height - 4))

        // Nothing visible changed (less than ~0.3 dB): don't touch the layers at all.
        if !host.isHidden, frame == lastFrame, mono == lastMono,
           abs(left - lastLeft) < 0.3, abs(right - lastRight) < 0.3 { return }
        lastLeft = left; lastRight = right; lastFrame = frame; lastMono = mono

        // The label colour only changes with the menu bar's appearance; resolve it once per change.
        let appearance = button.effectiveAppearance.name
        if cachedColor == nil || cachedAppearance != appearance {
            var color = NSColor.labelColor.cgColor
            button.effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
            cachedColor = color
            cachedAppearance = appearance
            for t in tracks { t.backgroundColor = color.copy(alpha: 0.25) }
            for f in fills { f.backgroundColor = color }
        }
        func frac(_ db: Double) -> CGFloat { CGFloat(min(1, max(0, (db + 48) / 48))) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.isHidden = false
        host.frame = frame
        if mono {
            // One wider bar in the middle: the summed level (left and right are the same in mono).
            let h = frame.height * frac(max(left, right))
            let y = button.isFlipped ? frame.height - h : 0
            tracks[0].frame = CGRect(x: 1.25, y: 0, width: 3, height: frame.height)
            fills[0].frame = CGRect(x: 1.25, y: y, width: 3, height: h)
            tracks[1].isHidden = true
            fills[1].isHidden = true
        } else {
            tracks[1].isHidden = false
            fills[1].isHidden = false
            for (i, db) in [left, right].enumerated() {
                let x = CGFloat(i) * 3.5
                let h = frame.height * frac(db)
                tracks[i].frame = CGRect(x: x, y: 0, width: 2, height: frame.height)
                let y = button.isFlipped ? frame.height - h : 0    // grow from the bottom either way
                fills[i].frame = CGRect(x: x, y: y, width: 2, height: h)
            }
        }
        CATransaction.commit()
    }
}
