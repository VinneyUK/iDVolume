import SwiftUI

/// The Settings window: set-and-forget options, grouped by what they configure.
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var tab: Tab = .panel

    enum Tab: String, CaseIterable, Identifiable {
        case panel = "Panel", general = "General", interface = "Interface", menuBar = "Menu bar"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .panel: return "rectangle.grid.2x2"
            case .general: return "keyboard"
            case .interface: return "slider.horizontal.3"
            case .menuBar: return "menubar.rectangle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(20)
                }
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 440)
        .background(Skin.plate)
        .environment(\.colorScheme, .light)
        .tint(Skin.keyDark)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    Label(t.rawValue, systemImage: t.icon)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .foregroundStyle(tab == t ? Color.white : Skin.ink)
                        .background(RoundedRectangle(cornerRadius: 6).fill(tab == t ? Skin.keyDark : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 160)
        .background(Color(hex: 0xd9dbde))
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch tab {
        case .panel: panelTab
        case .general: generalTab
        case .interface: interfaceTab
        case .menuBar: menuBarTab
        }
    }

    private var panelTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose the layout of the menu bar panel.").font(.system(size: 13)).foregroundStyle(Skin.silk)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(PanelLayout.allCases) { l in
                    Button { state.panelLayout = l } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l.title).font(.system(size: 13, weight: .semibold))
                            Text(l.summary).font(.system(size: 11)).foregroundStyle(state.panelLayout == l ? Color.white.opacity(0.8) : Skin.silkDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .foregroundStyle(state.panelLayout == l ? Color.white : Skin.ink)
                        .background(RoundedRectangle(cornerRadius: 8).fill(state.panelLayout == l ? AnyShapeStyle(Skin.keyOn) : AnyShapeStyle(Skin.keyLight)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(state.panelLayout == l ? Color(hex: 0x2f3236) : Skin.edge))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(state.panelLayout == l ? .isSelected : [])
                }
            }
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Keyboard volume keys", hint: "Volume up, down and mute control the iD", isOn: $state.volumeKeysEnabled)
            row("Only when the iD is the output", hint: "Keys work normally for AirPods and built-in speakers",
                isOn: $state.keysOnlyWhenAudient)
                .disabled(!state.volumeKeysEnabled)
            if let problem = state.keyProblem {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(problem.message).font(.system(size: 12))
                    Spacer()
                    Button(problem.action) { state.fixKeyProblem() }.controlSize(.small)
                }
            }
            row("On-screen display", hint: "Shows the level when you use the keys, scroll or the knob", isOn: $state.osdEnabled)
            row("Open at login", isOn: $state.launchAtLogin)
        }
    }

    private var interfaceTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                labelBlock("iD button", hint: "What the iD button on the interface does")
                Spacer()
                Picker("", selection: Binding(get: { state.idButton ?? .dim }, set: { state.idButton = $0 })) {
                    ForEach(IDButtonFunction.allCases) { f in Text(f.title).tag(f) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .disabled(state.idButton == nil)
            }
            row("iD LED follows app buttons", hint: "Lights the iD LED for whichever switch you last turned on in the app",
                isOn: $state.idLedFollows)
            row("Restore level at power-on", hint: "The iD starts up silent; this puts your level back", isOn: $state.restoreOnPowerUp)
        }
    }

    private var menuBarTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                labelBlock("Icon", hint: nil)
                Spacer()
                Picker("", selection: $state.menuBarStyle) {
                    Text("Speaker").tag(MenuBarStyle.speaker)
                    Text("Monitor").tag(MenuBarStyle.monitor)
                    Text("Knob").tag(MenuBarStyle.knob)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            row("Show level next to the icon", isOn: $state.showLevelInMenuBar)
            row("Level meter in the menu bar", hint: "Two small bars showing the speaker output", isOn: $state.menuBarMeter)
            Text("Right-click the menu bar icon for Settings and Quit.").font(.system(size: 12)).foregroundStyle(Skin.silkDim)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            LEDView(color: state.isConnected ? Skin.green : Skin.red)
            Text(state.isConnected ? "\(state.deviceName ?? "iD") connected" : "No iD interface found")
                .font(.system(size: 12)).foregroundStyle(Skin.silk)
            if let err = state.lastError { Text(err).font(.system(size: 11)).foregroundStyle(Skin.red).lineLimit(1) }
            Spacer()
            Button("Reconnect") { state.reconnect() }.controlSize(.small)
            Button("Quit iDVolume") { NSApp.terminate(nil) }.controlSize(.small)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                .font(.system(size: 11)).foregroundStyle(Skin.silkDim)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Helpers

    private func labelBlock(_ title: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 13))
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(Skin.silkDim) }
        }
        .foregroundStyle(Skin.ink)
    }

    private func row(_ title: String, hint: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            labelBlock(title, hint: hint)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}
