import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

final class AppState: ObservableObject {
    private enum K {
        static let speakers = "speakers", headphones = "headphones"
        static let keys = "volumeKeys", onlyAudient = "keysOnlyWhenAudient", osd = "osdEnabled"
        static let dim = "dim", mono = "mono", alt = "alt"
        static let style = "menuBarStyle", showLevel = "showLevelInMenuBar"
    }
    private let defaults = UserDefaults.standard
    private let writer = USBWriter()
    private let keyTap = MediaKeyTap()
    private let hud = VolumeHUD()
    private var timer: Timer?

    // MARK: Device status
    @Published var deviceName: String?
    @Published var lastError: String?
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var tapRunning = false

    // MARK: Levels
    @Published var speakers: Double {
        didSet {
            defaults.set(speakers, forKey: K.speakers)
            if muted { muted = false } else { pushSpeakers() }  // un-muting pushes too
        }
    }
    @Published var muted = false {
        didSet { pushSpeakers() }
    }
    @Published var headphones: Double {
        didSet {
            defaults.set(headphones, forKey: K.headphones)
            writer.send(.headphones, value: aud_raw_from_position(headphones, AUD_DEFAULT_FLOOR_DB))
        }
    }

    // MARK: Monitor switches
    @Published var dim: Bool {
        didSet { defaults.set(dim, forKey: K.dim); writer.send(.dim, value: dim ? 1 : 0) }
    }
    @Published var mono: Bool {
        didSet { defaults.set(mono, forKey: K.mono); writer.send(.mono, value: mono ? 1 : 0) }
    }
    @Published var alt: Bool {
        didSet { defaults.set(alt, forKey: K.alt); writer.send(.alt, value: alt ? 1 : 0) }
    }

    // MARK: Settings
    @Published var volumeKeysEnabled: Bool {
        didSet {
            defaults.set(volumeKeysEnabled, forKey: K.keys)
            if volumeKeysEnabled && !AXIsProcessTrusted() { requestAccessibility() }
            updateKeyTap()
        }
    }
    @Published var keysOnlyWhenAudient: Bool {
        didSet { defaults.set(keysOnlyWhenAudient, forKey: K.onlyAudient) }
    }
    @Published var osdEnabled: Bool {
        didSet {
            defaults.set(osdEnabled, forKey: K.osd)
            if osdEnabled { showHUD() }  // quick preview
        }
    }
    @Published var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: K.style) }
    }
    @Published var showLevelInMenuBar: Bool {
        didSet { defaults.set(showLevelInMenuBar, forKey: K.showLevel) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            let enabled = SMAppService.mainApp.status == .enabled
            guard launchAtLogin != enabled else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Login item: \(error.localizedDescription)"
            }
        }
    }

    init() {
        speakers = defaults.object(forKey: K.speakers) as? Double ?? 0.5
        headphones = defaults.object(forKey: K.headphones) as? Double ?? 0.5
        dim = defaults.bool(forKey: K.dim)
        mono = defaults.bool(forKey: K.mono)
        alt = defaults.bool(forKey: K.alt)
        volumeKeysEnabled = defaults.object(forKey: K.keys) as? Bool ?? true
        keysOnlyWhenAudient = defaults.object(forKey: K.onlyAudient) as? Bool ?? true
        osdEnabled = defaults.object(forKey: K.osd) as? Bool ?? true
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: K.style) ?? "") ?? .knob
        showLevelInMenuBar = defaults.bool(forKey: K.showLevel)
        launchAtLogin = SMAppService.mainApp.status == .enabled

        writer.onResult = { [weak self] status, pid in self?.handle(status: status, pid: pid) }

        keyTap.handler = { [weak self] key, down, flags in
            guard let self else { return false }
            let out = AudioOutput.current()
            let take = out.isAudient || !self.keysOnlyWhenAudient
            if down {
                NSLog("iDVolume key %@ taken=%d output=%@", "\(key)", take ? 1 : 0, out.name)
                if take { self.handleKey(key, flags: flags) }
            }
            return take
        }

        // Rebuild the tap when the Accessibility list changes, so a grant works without relaunching.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self?.restartKeyTap() }
        }

        refresh()
        updateKeyTap()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: - Display helpers

    var isConnected: Bool { deviceName != nil }

    var speakerSymbol: String {
        if muted || speakers <= 0.005 { return "speaker.slash.fill" }
        if speakers < 0.34 { return "speaker.wave.1.fill" }
        if speakers < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var tooltip: String {
        guard let name = deviceName else { return "iDVolume — no interface found" }
        return "\(name) — Speakers \(muted ? "muted" : "\(Int((speakers * 100).rounded()))%")"
    }

    /// A problem with key capture the panel should surface, with a fix.
    var keyProblem: (message: String, action: String)? {
        guard volumeKeysEnabled else { return nil }
        if !accessibilityGranted { return ("Needs Accessibility permission", "Grant…") }
        if !tapRunning { return ("Key capture isn't running", "Restart") }
        return nil
    }

    func fixKeyProblem() {
        if !accessibilityGranted { requestAccessibility() } else { restartKeyTap() }
    }

    // MARK: - Actions

    func refresh() { writer.probe { [weak self] pid in self?.handle(status: 0, pid: pid) } }
    func reconnect() { writer.reconnect { [weak self] pid in self?.handle(status: 0, pid: pid) } }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(opts)
    }

    func restartKeyTap() {
        keyTap.stop()
        updateKeyTap()
    }

    /// Scroll wheel / trackpad over the menu bar icon. Up = louder, whatever the scroll direction setting.
    func scroll(_ event: NSEvent) {
        guard isConnected else { return }
        var delta = Double(event.scrollingDeltaY)
        if event.isDirectionInvertedFromDevice { delta = -delta }
        guard delta != 0 else { return }
        let step = event.hasPreciseScrollingDeltas ? delta * 0.0035 : (delta > 0 ? 1.0 : -1.0) / 32
        speakers = min(1, max(0, speakers + step))
        showHUD()
    }

    private func pushSpeakers() {
        let raw = muted ? Int16.min : aud_raw_from_position(speakers, AUD_DEFAULT_FLOOR_DB)
        writer.send(.speakers, value: raw)
    }

    private func applyMonitorSwitches() {
        writer.send(.dim, value: dim ? 1 : 0)
        writer.send(.mono, value: mono ? 1 : 0)
        writer.send(.alt, value: alt ? 1 : 0)
    }

    private func handleKey(_ key: MediaKey, flags: NSEvent.ModifierFlags) {
        let step = flags.contains([.option, .shift]) ? 1.0 / 64 : 1.0 / 16  // quarter steps, like macOS
        switch key {
        case .up: speakers = min(1, speakers + step)
        case .down: speakers = max(0, speakers - step)
        case .mute: muted.toggle()
        }
        showHUD()
    }

    private func showHUD() {
        guard osdEnabled else { return }
        hud.show(level: speakers, muted: muted,
                 title: dim ? "Speakers · Dim" : "Speakers", symbol: speakerSymbol)
    }

    private func handle(status: Int32, pid: Int32) {
        let wasConnected = isConnected
        deviceName = pid >= 0 ? String(cString: aud_product_name(pid)) : nil
        // The iD can't report its switch state, so push ours on (re)connect to keep the UI truthful.
        if !wasConnected && isConnected { applyMonitorSwitches() }
        lastError = status == 0 ? nil : String(format: "USB request failed (0x%08X)", UInt32(bitPattern: status))
    }

    private func updateKeyTap() {
        accessibilityGranted = AXIsProcessTrusted()
        if volumeKeysEnabled && accessibilityGranted { _ = keyTap.start() } else { keyTap.stop() }
        tapRunning = keyTap.isRunning
    }

    private func tick() {
        if !isConnected { refresh() }
        if volumeKeysEnabled, !keyTap.isRunning || accessibilityGranted != AXIsProcessTrusted() {
            restartKeyTap()
        }
    }
}

// MARK: - USB writer (serial queue, coalesces slider drags)

enum USBTarget: Hashable { case speakers, headphones, dim, mono, alt }

final class USBWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "idvolume.usb")
    private var pending: [USBTarget: Int16] = [:]
    private var scheduled = false
    var onResult: ((Int32, Int32) -> Void)?

    func send(_ target: USBTarget, value: Int16) {
        queue.async {
            self.pending[target] = value
            guard !self.scheduled else { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + .milliseconds(12)) { self.flush() }
        }
    }

    func probe(_ done: @escaping (Int32) -> Void) {
        queue.async { let pid = aud_probe(); DispatchQueue.main.async { done(pid) } }
    }

    func reconnect(_ done: @escaping (Int32) -> Void) {
        queue.async { let pid = aud_connect(); DispatchQueue.main.async { done(pid) } }
    }

    private func flush() {
        let work = pending
        pending.removeAll()
        scheduled = false
        var status: Int32 = 0
        for (target, v) in work {
            let r: Int32
            switch target {
            case .speakers: r = aud_set_speaker_raw(v)
            case .headphones: r = aud_set_headphone_raw(v)
            case .dim: r = aud_set_monitor_switch(AUD_SW_DIM, Int32(v))
            case .mono: r = aud_set_monitor_switch(AUD_SW_MONO, Int32(v))
            case .alt: r = aud_set_monitor_switch(AUD_SW_ALT, Int32(v))
            }
            if r != 0 { status = r }
        }
        let pid = aud_current_pid()
        DispatchQueue.main.async { self.onResult?(status, pid) }
    }
}
