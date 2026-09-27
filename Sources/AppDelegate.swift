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
    private let updater = Updater()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var iconObserver: AnyCancellable?
    private var localScroll: Any?
    private var globalScroll: Any?
    private var barLevels = (left: -120.0, right: -120.0)
    private var iconSignature = ""
    private let barMeter = MenuBarMeter()
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy may run. Two can start together at login (a login item plus macOS
        // reopening apps, or copies in different folders); the one that started first stays.
        if let id = Bundle.main.bundleIdentifier {
            let me = NSRunningApplication.current
            let older = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0 != me && $0.processIdentifier < me.processIdentifier && !$0.isTerminated }
            if !older.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }
        state = AppState()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])   // right-click shows a menu
            button.imagePosition = .imageOnly
            barMeter.attach(to: button)
        }

        let host = NSHostingController(rootView: PanelView().environmentObject(state).environmentObject(updater))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = state.appearance.nsAppearance
        popover.delegate = self
        state.openSettings = { [weak self] in self?.openSettings() }
        state.toggleSettings = { [weak self] in
            guard let self else { return }
            if self.settingsIsOpen { self.settingsWindow?.performClose(nil) } else { self.openSettings() }
        }

        updateIcon()
        iconObserver = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateIcon()
                self?.applyAppearance()
                self?.updateWelcome()
            }
        }
        state.onBarMeter = { [weak self] left, right in
            self?.barLevels = (left, right)
            self?.updateMeter()
        }

        // Scroll over the menu bar icon to change the speaker level. macOS may deliver scrolls
        // over the menu bar to this app or to another process, so watch both and decide by
        // where the pointer is on screen rather than by which window got the event.
        localScroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.pointerIsOverIcon() else { return event }
            self.handleScroll(event, source: "local")
            return nil
        }
        globalScroll = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.pointerIsOverIcon() else { return }
            self.handleScroll(event, source: "global")
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
            popover.behavior = settingsIsOpen ? .applicationDefined : .transient
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverWillShow(_ notification: Notification) { state.panelOpen = true }   // start meters before the animation
    func popoverDidClose(_ notification: Notification) { state.panelOpen = false }

    // MARK: Settings window and menu

    @objc private func openSettings() {
        // Keep the panel open alongside Settings, so changes show up in it as you make them.
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(state).environmentObject(updater))
            let window = NSWindow(contentViewController: host)
            window.title = "iDVolume Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.appearance = state.appearance.nsAppearance
            // Size the window to its content now, so the first centring uses the real size
            // (otherwise it's centred at a placeholder size and then grows from the corner).
            host.view.layoutSubtreeIfNeeded()
            window.setContentSize(host.view.fittingSize)
            // When Settings closes, the panel goes back to closing on an outside click.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.popover.behavior = .transient
            }
            settingsWindow = window
        }
        popover.behavior = .applicationDefined   // don't close when Settings takes focus
        centreSettings()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.centreSettings() }   // after any final layout pass
    }

    private var settingsIsOpen: Bool { settingsWindow?.isVisible ?? false }

    /// Middle of the main screen (the one with the menu bar).
    private func centreSettings() {
        guard let w = settingsWindow, let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let area = screen.visibleFrame, size = w.frame.size
        w.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded()))
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let updates = NSMenuItem(title: updater.availableRelease.map { "Update to \($0.version)…" } ?? "Check for Updates…",
                                 action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
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

    /// First connection of a model that isn't fully supported: ask what to do.
    private func updateWelcome() {
        if state.showWelcome, welcomeWindow == nil {
            let host = NSHostingController(rootView: WelcomeView().environmentObject(state))
            let w = NSWindow(contentViewController: host)
            w.title = "iDVolume"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.appearance = state.appearance.nsAppearance
            w.center()
            welcomeWindow = w
            // Closing the window without choosing counts as "Not now".
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                guard let self else { return }
                if self.state.showWelcome { self.state.welcomeChoice(.later) }
                self.welcomeWindow = nil
            }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        } else if !state.showWelcome, let w = welcomeWindow {
            welcomeWindow = nil
            w.close()
        }
    }

    private func pointerIsOverIcon() -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let onScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        return onScreen.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private func handleScroll(_ event: NSEvent, source: String) {
        state.scroll(event)
    }

    @objc private func checkForUpdates() {
        state.settingsTab = .updates
        openSettings()
        if updater.availableRelease == nil { updater.check(userInitiated: true) }
    }

    /// Light / Dark / Auto for the panel and the Settings window (nil = follow the system).
    private func applyAppearance() {
        let wanted = state.appearance.nsAppearance
        if popover.appearance?.name != wanted?.name { popover.appearance = wanted }
        if let w = settingsWindow, w.appearance?.name != wanted?.name { w.appearance = wanted }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let showMeter = state.menuBarMeter && state.isConnected
        let showLevel = state.showLevelInMenuBar && state.isConnected
        // Everything the icon's look depends on. Drawing a new image is the expensive part,
        // so only do it when this changes.
        let signature = [state.menuBarStyle.rawValue, state.speakerSymbol, "\(state.muted)",
                         state.menuBarStyle == .knob ? "\(Int(state.speakers * 64))" : "",
                         "\(showMeter)", "\(showLevel)", "\(state.isConnected)",
                         showLevel ? "\(Int((state.speakers * 100).rounded()))" : ""].joined(separator: "|")
        if signature != iconSignature {
            iconSignature = signature
            var image: NSImage
            switch state.menuBarStyle {
            case .speaker: image = MenuBarIcon.speaker(symbol: state.speakerSymbol)
            case .monitor: image = MenuBarIcon.monitor(muted: state.muted)
            case .knob: image = MenuBarIcon.knob(level: state.speakers, muted: state.muted)
            }
            if showMeter { image = MenuBarIcon.padded(image, extra: MenuBarMeter.width) }
            button.image = image
            button.appearsDisabled = !state.isConnected

            if showLevel {
                button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                button.title = state.muted ? " Muted" : " \(Int((state.speakers * 100).rounded()))%"
                button.imagePosition = .imageLeading
            } else {
                button.title = ""
                button.imagePosition = .imageOnly
            }
        }
        let tip = state.tooltip
        if button.toolTip != tip { button.toolTip = tip }
        updateMeter()
    }

    private func updateMeter() {
        guard let button = statusItem.button else { return }
        guard state.menuBarMeter && state.isConnected else { barMeter.hide(); return }
        barMeter.update(on: button, left: barLevels.left, right: barLevels.right, mono: state.mono)
    }
}
