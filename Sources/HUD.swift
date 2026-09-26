import AppKit
import SwiftUI

final class HUDModel: ObservableObject {
    @Published var level: Double = 0
    @Published var muted = false
    @Published var title = "Speakers"
    @Published var symbol = "speaker.wave.2.fill"
}

/// Small floating level display, top-right of the active screen (where macOS shows its own).
final class VolumeHUD {
    private let model = HUDModel()
    private let size = NSSize(width: 290, height: 64)
    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var generation = 0

    func show(level: Double, muted: Bool, title: String, symbol: String) {
        model.level = level
        model.muted = muted
        model.title = title
        model.symbol = symbol

        let p = panel ?? makePanel()
        panel = p
        position(p)
        generation += 1

        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }

        hideTimer?.invalidate()
        let gen = generation
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.hide(gen)
        }
    }

    private func hide(_ gen: Int) {
        guard let p = panel, gen == generation else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, gen == self.generation else { return }  // shown again mid-fade
            p.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: HUDView(model: model).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        return p
    }

    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        p.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 12, y: vf.maxY - size.height - 10))
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: model.symbol)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(model.muted ? "Muted" : "\(Int((model.level * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule()
                            .fill(Color.primary.opacity(model.muted ? 0.3 : 0.9))
                            .frame(width: geo.size.width * (model.muted ? 0 : model.level))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HUDBackground(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: model.level)
    }
}

/// Behind-window blur with rounded corners (SwiftUI materials don't blur the desktop).
struct HUDBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        let d = cornerRadius * 2 + 1
        let mask = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: self.cornerRadius, yRadius: self.cornerRadius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        mask.resizingMode = .stretch
        v.maskImage = mask
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
