import SwiftUI

/// The popover: the chosen layout on a silver plate. Settings live in their own window.
struct PanelView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        layout
            .padding(16)
            .background(PlateBackground(brushed: brushed))
            .overlay(alignment: .top) {
                if !state.isConnected { disconnectedBanner }
            }
            .overlay(alignment: .bottom) {
                if state.isConnected, let problem = state.keyProblem { keysBanner(problem.message) }
            }
            .background(shortcuts)
    }

    @ViewBuilder private var layout: some View {
        switch state.panelLayout {
        case .consoleStrip: ConsoleStripLayout()
        case .faceplate: FaceplateLayout()
        case .twinKnobs: TwinKnobsLayout()
        case .faderBank: FaderBankLayout()
        case .ringFocus: RingFocusLayout()
        case .rackUnit: RackUnitLayout()
        case .compact: CompactLayout()
        case .meterBridge: MeterBridgeLayout()
        case .splitSurface: SplitSurfaceLayout()
        case .illuminatedKeys: IlluminatedKeysLayout()
        }
    }

    private var brushed: Bool {
        [.consoleStrip, .faceplate, .rackUnit].contains(state.panelLayout)
    }

    private var disconnectedBanner: some View {
        HStack(spacing: 8) {
            Text("No iD interface found").font(.system(size: 12, weight: .medium))
            Button("Reconnect") { state.reconnect() }.controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Skin.plateTop))
        .foregroundStyle(Skin.ink)
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .padding(.top, 44)
    }

    /// The volume keys stopped working (usually Accessibility permission lost after an update).
    private func keysBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard.badge.exclamationmark").foregroundStyle(.orange)
            Text("Volume keys: \(message.lowercased())").font(.system(size: 11, weight: .medium))
            Button("Fix…") { state.fixKeyProblem() }   // macOS's prompt then links to the right settings page
            .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Skin.plateTop))
        .foregroundStyle(Skin.ink)
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .padding(.bottom, 10)
    }

    /// ⌘, opens Settings and ⌘Q quits while the panel has focus.
    private var shortcuts: some View {
        ZStack {
            Button("") { state.openSettings?() }.keyboardShortcut(",", modifiers: .command)
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
