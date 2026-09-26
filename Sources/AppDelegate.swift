import AppKit
import Combine
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var instance: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        instance = delegate  // NSApplication.delegate is weak
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var state: AppState!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var scrollMonitor: Any?
    private var iconObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = AppState()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
        }

        let host = NSHostingController(rootView: PanelView().environmentObject(state))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        updateIcon()
        iconObserver = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }

        // Scroll over the menu bar icon to change the speaker level.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let button = self.statusItem.button, event.window === button.window else { return event }
            self.state.scroll(event)
            return nil
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            state.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        switch state.menuBarStyle {
        case .speaker: button.image = MenuBarIcon.speaker(symbol: state.speakerSymbol)
        case .monitor: button.image = MenuBarIcon.monitor(muted: state.muted)
        case .knob: button.image = MenuBarIcon.knob(level: state.speakers, muted: state.muted)
        }
        button.appearsDisabled = !state.isConnected

        if state.showLevelInMenuBar && state.isConnected {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.title = state.muted ? " Muted" : " \(Int((state.speakers * 100).rounded()))%"
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
        button.toolTip = state.tooltip
    }
}
