import AppKit
import QuartzCore

/// Two thin level bars drawn with Core Animation layers on the status item button.
/// Updating the meter only changes layer heights — no new images, so no graphics memory churn.
final class MenuBarMeter {
    static let width: CGFloat = 8
    private let host = CALayer()
    private let tracks = [CALayer(), CALayer()]
    private let fills = [CALayer(), CALayer()]

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

    func hide() { host.isHidden = true }

    /// Speaker L/R in dBFS; bars span −48…0.
    func update(on button: NSStatusBarButton, left: Double, right: Double) {
        let imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
        let frame = CGRect(x: imageRect.maxX - Self.width + 1, y: imageRect.minY + 2,
                           width: Self.width - 1, height: max(4, imageRect.height - 4))

        var color = NSColor.labelColor.cgColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.cgColor
        }
        func frac(_ db: Double) -> CGFloat { CGFloat(min(1, max(0, (db + 48) / 48))) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.isHidden = false
        host.frame = frame
        for (i, db) in [left, right].enumerated() {
            let x = CGFloat(i) * 3.5
            let h = frame.height * frac(db)
            tracks[i].frame = CGRect(x: x, y: 0, width: 2, height: frame.height)
            tracks[i].backgroundColor = color.copy(alpha: 0.25)
            // Grow from the bottom whichever way the button's coordinates run.
            let y = button.isFlipped ? frame.height - h : 0
            fills[i].frame = CGRect(x: x, y: y, width: 2, height: h)
            fills[i].backgroundColor = color
        }
        CATransaction.commit()
    }
}
