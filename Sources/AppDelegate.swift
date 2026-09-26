import AppKit
import Combine
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
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
    private var barLevels = (left: -120.0, right: -120.0)
    private let barMeter = MenuBarMeter()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = AppState()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])   // right-click shows a menu
            button.imagePosition = .imageOnly
            barMeter.attach(to: button)
        }

        let host = NSHostingController(rootView: PanelView().environmentObject(state))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .aqua)   // the silver skin is a light design
        popover.delegate = self
        state.openSettings = { [weak self] in self?.openSettings() }

        updateIcon()
        iconObserver = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        state.onBarMeter = { [weak self] left, right in
            self?.barLevels = (left, right)
            self?.updateMeter()
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
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            state.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidShow(_ notification: Notification) { state.panelOpen = true }
    func popoverDidClose(_ notification: Notification) { state.panelOpen = false }

    // MARK: Settings window and menu

    @objc private func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(state))
            let window = NSWindow(contentViewController: host)
            window.title = "iDVolume Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let reconnect = NSMenuItem(title: "Reconnect", action: #selector(reconnectAction), keyEquivalent: "")
        reconnect.target = self
        menu.addItem(reconnect)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit iDVolume", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu              // attach just for this click…
        statusItem.button?.performClick(nil)
        statusItem.menu = nil               // …so left-click still opens the panel
    }

    @objc private func reconnectAction() { state.reconnect() }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        var image: NSImage
        switch state.menuBarStyle {
        case .speaker: image = MenuBarIcon.speaker(symbol: state.speakerSymbol)
        case .monitor: image = MenuBarIcon.monitor(muted: state.muted)
        case .knob: image = MenuBarIcon.knob(level: state.speakers, muted: state.muted)
        }
        let showMeter = state.menuBarMeter && state.isConnected
        if showMeter { image = MenuBarIcon.padded(image, extra: MenuBarMeter.width) }
        button.image = image
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
        updateMeter()
    }

    private func updateMeter() {
        guard let button = statusItem.button else { return }
        guard state.menuBarMeter && state.isConnected else { barMeter.hide(); return }
        barMeter.update(on: button, left: barLevels.left, right: barLevels.right)
    }
}
