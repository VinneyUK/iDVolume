import SwiftUI

/// The popover shown from the menu bar icon.
struct PanelView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            SectionDivider()

            VStack(spacing: 16) {
                LevelControl(title: "Speakers", symbol: state.speakerSymbol,
                             value: $state.speakers, muted: state.muted,
                             help: state.muted ? "Unmute" : "Mute") { state.muted.toggle() }
                LevelControl(title: "Headphones", symbol: "headphones",
                             value: $state.headphones, muted: state.headphonesMuted,
                             help: state.headphonesMuted ? "Unmute headphones" : "Mute headphones",
                             slashWhenMuted: true) {
                    state.headphonesMuted.toggle()
                }
            }
            .disabled(!state.isConnected)

            SectionDivider()

            SectionTitle("Monitor")
            HStack(spacing: 6) {
                MonitorTile(title: "Mute", symbol: "speaker.slash.fill", isOn: $state.muted)
                MonitorTile(title: "Dim", symbol: "speaker.wave.1.fill", isOn: $state.dim)
                MonitorTile(title: "Talk", symbol: "mic.fill", isOn: $state.talkback)
                    .help("Talkback (the iD also dims the monitors)")
                MonitorTile(title: "Polarity", symbol: "plus.forwardslash.minus", isOn: $state.polarity)
                MonitorTile(title: "Mono", symbol: "arrow.triangle.merge", isOn: $state.mono)
                    .disabled(state.polarity)   // the iD holds Mono on while Polarity is on
                    .help(state.polarity ? "Mono stays on while Polarity is on" : "Mono")
                MonitorTile(title: "Alt", symbol: "hifispeaker.2.fill", isOn: $state.alt)
            }
            .disabled(!state.isConnected)

            SectionDivider()

            SectionTitle("Settings")
            VStack(spacing: 12) {
                HStack {
                    Text("iD button").font(.system(size: 13))
                    Spacer(minLength: 12)
                    Picker("", selection: Binding(
                        get: { state.idButton ?? .dim },
                        set: { state.idButton = $0 })
                    ) {
                        ForEach(IDButtonFunction.allCases) { f in Text(f.title).tag(f) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(state.idButton == nil)
                }
                SettingRow(title: "iD LED follows app buttons", isOn: $state.idLedFollows, indented: true)
                SettingRow(title: "Keyboard volume keys", isOn: $state.volumeKeysEnabled)
                SettingRow(title: "Only when iD is the output", isOn: $state.keysOnlyWhenAudient, indented: true)
                    .disabled(!state.volumeKeysEnabled)
                if let problem = state.keyProblem {
                    NoticeRow(message: problem.message, action: problem.action) { state.fixKeyProblem() }
                }
                SettingRow(title: "On-screen display", isOn: $state.osdEnabled)
                SettingRow(title: "Restore level at power-on", isOn: $state.restoreOnPowerUp)
                HStack {
                    Text("Menu bar icon").font(.system(size: 13))
                    Spacer(minLength: 12)
                    Picker("", selection: $state.menuBarStyle) {
                        Image(systemName: "speaker.wave.2.fill").tag(MenuBarStyle.speaker)
                        Image(systemName: "hifispeaker.fill").tag(MenuBarStyle.monitor)
                        Image(nsImage: MenuBarIcon.knob(level: 0.65, muted: false)).tag(MenuBarStyle.knob)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                SettingRow(title: "Show level in menu bar", isOn: $state.showLevelInMenuBar)
                SettingRow(title: "Meter in menu bar", isOn: $state.menuBarMeter)
                SettingRow(title: "Launch at login", isOn: $state.launchAtLogin)
            }

            SectionDivider()

            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.deviceName ?? "No iD interface")
                    .font(.system(size: 14, weight: .semibold))
                Text(state.lastError ?? (state.isConnected ? "Connected" : "Plug in your interface"))
                    .font(.system(size: 11))
                    .foregroundStyle(state.lastError == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(state.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
        }
    }

    /// Read from Info.plist (CFBundleShortVersionString) — bump it there.
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var footer: some View {
        HStack {
            Button { state.reconnect() } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            Spacer()
            Text("v\(appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help("iDVolume \(appVersion)")
            Spacer()
            Button("Quit iDVolume") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Building blocks

private struct SectionDivider: View {
    var body: some View { Divider().padding(.vertical, 14) }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.bottom, 10)
    }
}

/// Title and value on one line, icon + slider beneath — edges line up with every other row.
private struct LevelControl: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let muted: Bool
    let help: String?
    /// Draw a slash over the icon when muted (for symbols with no built-in ".slash" variant).
    var slashWhenMuted = false
    let iconAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(muted ? "Muted" : "\(Int((value * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { iconAction?() } label: {
                    ZStack {
                        Image(systemName: symbol)
                            .font(.system(size: 13))
                        if slashWhenMuted && muted { MuteSlash() }
                    }
                    .compositingGroup()
                    .foregroundStyle(slashWhenMuted && muted ? Color.secondary : Color.primary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(iconAction != nil)
                .help(help ?? "")
                Slider(value: $value, in: 0...1)
                    .controlSize(.small)
            }
        }
    }
}

/// Diagonal slash like SF Symbols' ".slash" variants: a thin line with a gap cut
/// into the icon either side so it stays readable at small sizes.
private struct MuteSlash: View {
    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 3
            let path = Path { p in
                p.move(to: CGPoint(x: inset, y: inset))
                p.addLine(to: CGPoint(x: geo.size.width - inset, y: geo.size.height - inset))
            }
            ZStack {
                path.stroke(style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
                    .blendMode(.destinationOut)          // the gap
                path.stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
    }
}

/// Control Center-style square toggle.
private struct MonitorTile: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(height: 18)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn ? Color.accentColor : Color.primary.opacity(0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Label on the left, switch pinned to the right edge.
private struct SettingRow: View {
    let title: String
    @Binding var isOn: Bool
    var indented = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct NoticeRow: View {
    let message: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action, action: perform).controlSize(.small)
        }
    }
}
