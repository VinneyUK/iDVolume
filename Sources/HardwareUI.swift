import AppKit
import SwiftUI

// MARK: - Skin (silver hardware)

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

/// The hardware skin. Every colour is a light/dark pair; macOS picks one from the panel's
/// appearance (Light, Dark, or Auto = follow the system — see Settings → Panel).
enum Skin {
    /// A colour that resolves per appearance.
    static func pair(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    //                               light     dark (graphite)
    static let plateTop  = pair(0xeceef0, 0x2e3237)
    static let plate     = pair(0xe3e4e7, 0x24272b)
    static let plateLo   = pair(0xd5d7da, 0x1f2225)
    static let groove    = pair(0xc4c7cb, 0x121315)
    static let well      = pair(0xcfd1d5, 0x1a1c1f)
    static let sidebar   = pair(0xd9dbde, 0x1d1f22)
    static let ink       = pair(0x2f3236, 0xe6e8eb)
    static let silk      = pair(0x4f535a, 0xb9bec6)
    static let silkDim   = pair(0x868a91, 0x6f757e)
    static let edge      = pair(0xa2a6ac, 0x15171a)
    static let edgeOn    = pair(0x2f3236, 0x6a6e75)
    static let ledOff    = pair(0xb4b7bc, 0x3a3e44)
    static let tick      = pair(0x9ea2a8, 0x6f757e)
    static let charcoal  = pair(0x3d4045, 0xd8dbe0)     // lit arcs and fader fills
    static let keyDark   = pair(0x3f4247, 0x5a5e65)     // selected / "on" fill
    static let brushLine = pair(0xffffff, 0xffffff, lightAlpha: 0.28, darkAlpha: 0.022)

    static let amber = Color(hex: 0xf0a020)
    static let red = Color(hex: 0xe5483a)
    static let green = Color(hex: 0x2fae66)

    static func silkFont(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .semibold).width(.condensed) }
    static func readoutFont(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold).width(.condensed).monospacedDigit() }

    static let plateGradient = LinearGradient(colors: [plateTop, plate, plateLo], startPoint: .top, endPoint: .bottom)
    static let keyLight = LinearGradient(colors: [pair(0xf3f4f6, 0x363a40), pair(0xe1e3e6, 0x2a2d32)], startPoint: .top, endPoint: .bottom)
    static let keyOn = LinearGradient(colors: [pair(0x4a4d52, 0x686c73), keyDark], startPoint: .top, endPoint: .bottom)
    static let keyMuted = LinearGradient(colors: [Color(hex: 0xb8392d), Color(hex: 0x9c2c22)], startPoint: .top, endPoint: .bottom)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

/// Level (0…1) → dB text on the app's scale.
func dBText(_ v: Double) -> String {
    guard v > 0.005 else { return "−∞" }
    let d = Int((AUD_DEFAULT_FLOOR_DB * (1 - v)).rounded())
    return d == 0 ? "0" : "−\(abs(d))"
}

private func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

// MARK: - Small pieces

struct SilkText: View {
    let text: String
    var dim = false
    var size: CGFloat = 11
    init(_ text: String, dim: Bool = false, size: CGFloat = 11) { self.text = text; self.dim = dim; self.size = size }
    var body: some View {
        Text(text.uppercased())
            .font(Skin.silkFont(size))
            .tracking(size * 0.13)
            .foregroundStyle(dim ? Skin.silkDim : Skin.silk)
            .lineLimit(1)
    }
}

struct Readout: View {
    let text: String
    var size: CGFloat = 18
    var alert = false
    var body: some View {
        Text(text).font(Skin.readoutFont(size)).foregroundStyle(alert ? Skin.red : Skin.ink)
    }
}

/// Status LED; flashes when asked (1 Hz, like the hardware).
struct LEDView: View {
    var color: Color?
    var flash = false
    var size: CGFloat = 7
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let blinkOff = flash && Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 1
            Circle()
                .fill(color.map { blinkOff ? Skin.ledOff : $0 } ?? Skin.ledOff)
                .frame(width: size, height: size)
                .shadow(color: (color != nil && !blinkOff) ? color!.opacity(0.8) : .clear, radius: 3)
        }
    }
}

/// The silver plate every panel sits on.
struct PlateBackground: View {
    var brushed = false
    var body: some View {
        ZStack {
            Skin.plateGradient
            if brushed {
                Canvas { ctx, size in
                    var x: CGFloat = 0
                    while x < size.width {
                        ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Skin.brushLine))
                        x += 3
                    }
                }
            }
        }
    }
}

// MARK: - Keys

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.offset(y: configuration.isPressed ? 1 : 0)
    }
}

/// Hardware key: light when off, dark when on, optional LED, icon and "backlit" amber label.
struct HWKey: View {
    let label: String
    var icon: String? = nil
    let isOn: Bool
    var led: Color? = Skin.amber
    var flash = false
    var backlit = false
    var mutedStyle = false          // red fill when on (mute keys in the backlit layout)
    var horizontal = false
    var compact = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            stack(content)
                .padding(.vertical, compact ? 6 : 8)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
                .foregroundStyle(foreground)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isOn ? Skin.edgeOn : Skin.edge, lineWidth: 1))
                .shadow(color: .black.opacity(isOn ? 0 : 0.18), radius: 1, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .opacity(isEnabled ? 1 : 0.6)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    @ViewBuilder private var content: some View {
        if !backlit, let led { LEDView(color: isOn ? led : nil, flash: isOn && flash) }
        if let icon { Image(systemName: icon).font(.system(size: 12, weight: .medium)) }
        Text(label.uppercased())
            .font(Skin.silkFont(11))
            .tracking(1.2)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .shadow(color: backlit && isOn && !mutedStyle ? Skin.amber.opacity(0.7) : .clear, radius: 4)
    }

    @ViewBuilder private func stack<C: View>(_ c: C) -> some View {
        if horizontal { HStack(spacing: 7) { c } } else { VStack(spacing: 5) { c } }
    }

    private var fill: LinearGradient {
        guard isOn else { return Skin.keyLight }
        return mutedStyle ? Skin.keyMuted : Skin.keyOn
    }

    private var foreground: Color {
        guard isOn else { return Skin.silk }
        return backlit && !mutedStyle ? Skin.amber : .white
    }
}

struct SegOption<T: Hashable> {
    let value: T
    let label: String
    var icon: String? = nil
    init(_ value: T, _ label: String, icon: String? = nil) { self.value = value; self.label = label; self.icon = icon }
}

/// Two- or three-way selector in a recessed groove.
struct HWSegmented<T: Hashable>: View {
    let options: [SegOption<T>]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                Button { selection = o.value } label: {
                    HStack(spacing: 6) {
                        if let icon = o.icon { Image(systemName: icon).font(.system(size: 11)) }
                        Text(o.label.uppercased()).font(Skin.silkFont(11)).tracking(1.2)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selection == o.value ? Color.white : Skin.silk)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selection == o.value ? AnyShapeStyle(Skin.keyOn) : AnyShapeStyle(Color.clear)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Skin.groove))
    }
}

// MARK: - Knob

/// Metal knob. Drag up/down, or focus it and use the arrow keys.
struct HWKnob: View {
    enum Ring { case arc, segments, ticks }
    @Binding var value: Double
    var size: CGFloat = 96
    var ring: Ring = .arc
    var segments = 21
    var dimmed = false
    var label = "Level"
    @State private var dragStart: Double?

    var body: some View {
        Canvas { ctx, sz in draw(ctx, sz) }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil { dragStart = value }
                    value = clamp01((dragStart ?? value) - g.translation.height / 200)
                }
                .onEnded { _ in dragStart = nil })
            .focusable()
            .onMoveCommand { dir in
                switch dir {
                case .up, .right: value = clamp01(value + 1.0 / 64)
                case .down, .left: value = clamp01(value - 1.0 / 64)
                @unknown default: break
                }
            }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int((value * 100).rounded())) percent")
            .accessibilityAdjustableAction { dir in
                value = clamp01(value + (dir == .increment ? 1.0 : -1.0) / 64)
            }
    }

    private func point(_ deg: Double, _ r: CGFloat, _ c: CGPoint) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a)))
    }

    private func arc(from: Double, to: Double, r: CGFloat, c: CGPoint) -> Path {
        var p = Path()
        let steps = max(2, Int(abs(to - from) / 3))
        for i in 0...steps {
            let d = from + (to - from) * Double(i) / Double(steps)
            if i == 0 { p.move(to: point(d, r, c)) } else { p.addLine(to: point(d, r, c)) }
        }
        return p
    }

    private func draw(_ ctx: GraphicsContext, _ sz: CGSize) {
        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let rOuter = sz.width / 2 - 3
        let rBody = sz.width * 0.33
        let angle = -135 + 270 * value
        let lit = value > 0.005 && !dimmed

        switch ring {
        case .arc:
            ctx.stroke(arc(from: -135, to: 135, r: rOuter - 2, c: c), with: .color(Skin.groove),
                       style: StrokeStyle(lineWidth: 4, lineCap: .round))
            if value > 0.005 {
                ctx.stroke(arc(from: -135, to: angle, r: rOuter - 2, c: c), with: .color(dimmed ? Skin.edge : Skin.charcoal),
                           style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
        case .segments:
            for i in 0..<segments {
                let t = Double(i) / Double(segments - 1)
                let a = -135 + 270 * t
                var p = Path(); p.move(to: point(a, rOuter - 7, c)); p.addLine(to: point(a, rOuter, c))
                let hue = t > 0.85 ? Skin.red : t > 0.65 ? Skin.amber : Skin.green
                let on = lit && t <= value + 1e-6
                ctx.stroke(p, with: .color(on ? hue : Skin.groove), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        case .ticks:
            for i in 0...10 {
                let a = -135 + 27 * Double(i)
                var p = Path(); p.move(to: point(a, rOuter - 5, c)); p.addLine(to: point(a, rOuter, c))
                ctx.stroke(p, with: .color(Skin.tick), lineWidth: 1.5)
            }
        }

        let shadow = CGRect(x: c.x - rBody - 5, y: c.y - rBody - 3, width: (rBody + 5) * 2, height: (rBody + 5) * 2)
        ctx.fill(Path(ellipseIn: shadow), with: .color(Color(hex: 0x282c32).opacity(0.25)))
        let skirt = CGRect(x: c.x - rBody - 4, y: c.y - rBody - 4, width: (rBody + 4) * 2, height: (rBody + 4) * 2)
        ctx.fill(Path(ellipseIn: skirt), with: .linearGradient(
            Gradient(colors: [Color(hex: 0x8c9097), Color(hex: 0x3f4247)]),
            startPoint: CGPoint(x: c.x, y: skirt.minY), endPoint: CGPoint(x: c.x, y: skirt.maxY)))
        let cap = CGRect(x: c.x - rBody, y: c.y - rBody, width: rBody * 2, height: rBody * 2)
        ctx.fill(Path(ellipseIn: cap), with: .radialGradient(
            Gradient(colors: [.white, Color(hex: 0xe2e4e7), Color(hex: 0xaeb2b8)]),
            center: CGPoint(x: c.x - rBody * 0.25, y: c.y - rBody * 0.4), startRadius: 0, endRadius: rBody * 1.5))
        var pointer = Path(); pointer.move(to: c); pointer.addLine(to: point(angle, rBody * 0.72, c))
        ctx.stroke(pointer, with: .color(Skin.ink), style: StrokeStyle(lineWidth: max(2, sz.width / 36), lineCap: .round))
    }
}

// MARK: - Faders

/// Vertical long-throw fader with scale marks.
struct HWFader: View {
    @Binding var value: Double
    var height: CGFloat = 170
    var label = "Level"

    var body: some View {
        let travel = height - 24
        ZStack(alignment: .topLeading) {
            ForEach(0..<5, id: \.self) { i in
                Rectangle().fill(Skin.silkDim).frame(width: 8, height: 1)
                    .offset(y: 12 + (1 - CGFloat(i) / 4) * travel)
            }
            RoundedRectangle(cornerRadius: 2).fill(Skin.groove).frame(width: 4, height: travel).offset(x: 20, y: 12)
            RoundedRectangle(cornerRadius: 2).fill(Skin.charcoal.opacity(0.8)).frame(width: 4, height: travel * value)
                .offset(x: 20, y: 12 + travel * (1 - value))
            capView.offset(x: 8, y: 1 + (1 - value) * travel)
        }
        .frame(width: 44, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            value = clamp01(1 - (g.location.y - 12) / travel)
        })
        .focusable()
        .onMoveCommand { dir in
            if dir == .up { value = clamp01(value + 1.0 / 64) }
            if dir == .down { value = clamp01(value - 1.0 / 64) }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { dir in value = clamp01(value + (dir == .increment ? 1.0 : -1.0) / 64) }
    }

    private var capView: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(LinearGradient(colors: [Color(hex: 0xfafbfc), Color(hex: 0xd3d6da), Color(hex: 0xe8eaec)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(hex: 0x9ea2a8), lineWidth: 1))
            .overlay(Rectangle().fill(Skin.charcoal).frame(height: 2).padding(.horizontal, 3))
            .frame(width: 28, height: 22)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
    }
}

/// Horizontal fader with a hardware cap.
struct HWSlider: View {
    @Binding var value: Double
    var thin = false
    var label = "Level"

    var body: some View {
        let h: CGFloat = thin ? 22 : 30
        GeometryReader { geo in
            let travel = geo.size.width - 20
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Skin.groove).frame(width: travel, height: 4).offset(x: 10)
                RoundedRectangle(cornerRadius: 2).fill(Skin.charcoal.opacity(0.8)).frame(width: max(0, travel * value), height: 4).offset(x: 10)
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(hex: 0xd3d6da), Color(hex: 0xfafbfc), Color(hex: 0xd0d3d7)], startPoint: .leading, endPoint: .trailing))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(hex: 0x9ea2a8), lineWidth: 1))
                    .overlay(Rectangle().fill(Skin.charcoal).frame(width: 2).padding(.vertical, 3))
                    .frame(width: thin ? 12 : 16, height: thin ? 16 : 26)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
                    .offset(x: 10 + travel * value - (thin ? 6 : 8))
            }
            .frame(width: geo.size.width, height: h)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = clamp01((g.location.x - 10) / travel)
            })
        }
        .frame(height: h)
        .focusable()
        .onMoveCommand { dir in
            if dir == .right { value = clamp01(value + 1.0 / 64) }
            if dir == .left { value = clamp01(value - 1.0 / 64) }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { dir in value = clamp01(value + (dir == .increment ? 1.0 : -1.0) / 64) }
    }
}

// MARK: - Meter

/// Stereo LED bar meter (speaker output), −48…0 dBFS.
struct HWStereoMeter: View {
    @ObservedObject var levels: PanelLevels
    var segments = 30

    var body: some View {
        Canvas { ctx, size in
            let rows = [levels.left, levels.right]
            let gap: CGFloat = 2
            let rowH = (size.height - 3) / 2
            let segW = (size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            for (r, db) in rows.enumerated() {
                let frac = min(1, max(0, (db + 48) / 48))
                for i in 0..<segments {
                    let t = Double(i + 1) / Double(segments)
                    let hue = t > 0.9 ? Skin.red : t > 0.75 ? Skin.amber : Skin.green
                    let rect = CGRect(x: CGFloat(i) * (segW + gap), y: CGFloat(r) * (rowH + 3), width: segW, height: rowH)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(frac >= t ? hue : Skin.groove))
                }
            }
        }
        .frame(height: 13)
        .accessibilityHidden(true)
    }
}
