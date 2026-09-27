import AppKit
import SwiftUI

final class HUDModel: ObservableObject {
    @Published var level: Double = 0
    @Published var muted = false
    @Published var title = "iD14"
    @Published var status = ""          // "Muted", "Dim" or empty
}

/// Small floating level display, top-right of the active screen (where macOS shows its own).
final class VolumeHUD {
    private let model = HUDModel()
    private let size = NSSize(width: 300, height: 78)
    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var generation = 0

    func show(level: Double, muted: Bool, title: String, status: String) {
        model.level = level
        model.muted = muted
        model.title = title
        model.status = status

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

/// Styled after macOS's own volume display: device name, a slim bar between speaker icons,
/// a row of step dots, on glass (Liquid Glass on macOS 26, frosted blur before that).
struct HUDView: View {
    @ObservedObject var model: HUDModel
    private let steps = 16

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(GlassBackground(cornerRadius: 22))
            .animation(.easeOut(duration: 0.12), value: model.level)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.title).font(.system(size: 15, weight: .semibold))
                Spacer()
                if !model.status.isEmpty {
                    Text(model.status).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 12)).frame(width: 16)
                VStack(spacing: 7) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.18))
                            Capsule()
                                .fill(Color.primary.opacity(model.muted ? 0.35 : 0.85))
                                .frame(width: geo.size.width * (model.muted ? 0 : model.level))
                        }
                    }
                    .frame(height: 6)
                    HStack(spacing: 0) {
                        ForEach(0..<steps, id: \.self) { i in
                            Circle().fill(Color.primary.opacity(0.35)).frame(width: 2.5, height: 2.5)
                            if i < steps - 1 { Spacer(minLength: 0) }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 12)).frame(width: 22)
            }
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
    }
}

/// Liquid Glass on macOS 26 (when built with Xcode 26), otherwise the classic HUD blur.
private struct GlassBackground: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            classic(content)
        }
        #else
        classic(content)
        #endif
    }

    private func classic(_ content: Content) -> some View {
        content
            .background(HUDBackground(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
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
