import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

final class AppState: ObservableObject {
    private enum K {
        static let speakers = "speakers", headphones = "headphones"
        static let keys = "volumeKeys", onlyAudient = "keysOnlyWhenAudient", osd = "osdEnabled"
        static let style = "menuBarStyle", showLevel = "showLevelInMenuBar", restore = "restoreOnPowerUp"
    }
    private let defaults = UserDefaults.standard
    private let writer = USBWriter()
    private let keyTap = MediaKeyTap()
    private let hud = VolumeHUD()
    private var timer: Timer?

    // Knob sync bookkeeping
    private var applyingFromDevice = false          // true while we mirror the hardware → don't write back
    private var lastLocalChange: [USBTarget: Date] = [:]
    private var lastDeviceSpeakerRaw: Int16?
    private var awaitingFirstPoll = false

    // MARK: Device status
    @Published var deviceName: String?
    @Published var lastError: String?
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var tapRunning = false

    // MARK: Levels
    @Published var speakers: Double {
        didSet {
            defaults.set(speakers, forKey: K.speakers)
            guard !applyingFromDevice else { return }
            if muted { muted = false }  // moving the level un-mutes, like macOS
            write(.speakers, aud_raw_from_position(speakers, AUD_DEFAULT_FLOOR_DB))
        }
    }
    /// The iD's hardware mute — the same one pressing the knob toggles.
    @Published var muted = false {
        didSet { if !applyingFromDevice { write(.mute, muted ? 1 : 0) } }
    }
    /// Headphone mute (feature unit 0x0a ch 5/6) — also toggled by the knob press in headphone mode.
    @Published var headphonesMuted = false {
        didSet { if !applyingFromDevice { write(.phonesMute, headphonesMuted ? 1 : 0) } }
    }
    @Published var headphones: Double {
        didSet {
            defaults.set(headphones, forKey: K.headphones)
            write(.headphones, aud_raw_from_position(headphones, AUD_DEFAULT_FLOOR_DB))
        }
    }

    // MARK: Monitor switches (read back from the interface)
    @Published var dim = false { didSet { if !applyingFromDevice { write(.dim, dim ? 1 : 0) } } }
    @Published var mono = false { didSet { if !applyingFromDevice { write(.mono, mono ? 1 : 0) } } }
    @Published var alt = false { didSet { if !applyingFromDevice { write(.alt, alt ? 1 : 0) } } }

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
    @Published var restoreOnPowerUp: Bool {
        didSet { defaults.set(restoreOnPowerUp, forKey: K.restore) }
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
        volumeKeysEnabled = defaults.object(forKey: K.keys) as? Bool ?? true
        keysOnlyWhenAudient = defaults.object(forKey: K.onlyAudient) as? Bool ?? true
        osdEnabled = defaults.object(forKey: K.osd) as? Bool ?? true
        restoreOnPowerUp = defaults.object(forKey: K.restore) as? Bool ?? true
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: K.style) ?? "") ?? .knob
        showLevelInMenuBar = defaults.bool(forKey: K.showLevel)
        launchAtLogin = SMAppService.mainApp.status == .enabled

        writer.onResult = { [weak self] status, pid in self?.handle(status: status, pid: pid) }
        writer.onSnapshot = { [weak self] snap in self?.applyFromDevice(snap) }

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
        writer.startPolling()
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

    // MARK: - Knob sync

    private func write(_ target: USBTarget, _ value: Int16) {
        lastLocalChange[target] = Date()
        writer.send(target, value: value)
    }

    /// Mirror what the interface reports (knob turns, knob press, front-panel buttons).
    private func applyFromDevice(_ snap: DeviceSnapshot) {
        let now = Date()
        // Ignore readings for a moment after we've written, so a drag isn't yanked back by a stale poll.
        func settled(_ t: USBTarget) -> Bool {
            guard let last = lastLocalChange[t] else { return true }
            return now.timeIntervalSince(last) > 0.8
        }

        if awaitingFirstPoll, let raw = snap.speakerRaw {
            awaitingFirstPoll = false
            // The iD powers up silent. Put the last level back instead of adopting silence.
            if raw == Int16.min && restoreOnPowerUp && speakers > 0.005 {
                lastDeviceSpeakerRaw = raw
                write(.speakers, aud_raw_from_position(speakers, AUD_DEFAULT_FLOOR_DB))
                return
            }
        }

        applyingFromDevice = true
        defer { applyingFromDevice = false }

        if let raw = snap.speakerRaw, settled(.speakers), raw != lastDeviceSpeakerRaw {
            let fromKnob = lastDeviceSpeakerRaw != nil  // first reading is just catching up
            lastDeviceSpeakerRaw = raw
            let position = aud_position_from_raw(raw, AUD_DEFAULT_FLOOR_DB)
            if abs(position - speakers) > 0.002 {
                speakers = position
                if fromKnob { showHUD() }
            }
        }
        if let m = snap.mute, settled(.mute), m != muted {
            muted = m
            showHUD()
        }
        if let h = snap.phonesMute, settled(.phonesMute), h != headphonesMuted { headphonesMuted = h }
        if let d = snap.dim, settled(.dim), d != dim { dim = d }
        if let m = snap.mono, settled(.mono), m != mono { mono = m }
        if let a = snap.alt, settled(.alt), a != alt { alt = a }
    }

    // MARK: - Private

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
        if !wasConnected && isConnected {
            awaitingFirstPoll = true      // decide on power-up restore once we've read the level
            lastDeviceSpeakerRaw = nil
        }
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

// MARK: - USB access (one serial queue: writes coalesced, reads polled)

enum USBTarget: Hashable { case speakers, headphones, phonesMute, mute, dim, mono, alt }

struct DeviceSnapshot {
    var speakerRaw: Int16?
    var mute: Bool?
    var phonesMute: Bool?
    var dim: Bool?
    var mono: Bool?
    var alt: Bool?
}

final class USBWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "idvolume.usb")
    private var pending: [USBTarget: Int16] = [:]
    private var scheduled = false
    private var pollTimer: DispatchSourceTimer?
    private var pollFailures = 0
    var onResult: ((Int32, Int32) -> Void)?
    var onSnapshot: ((DeviceSnapshot) -> Void)?

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

    /// Read the level and switches ~7 times a second so the app follows the hardware.
    func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(400), repeating: .milliseconds(150))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        pollTimer = t
    }

    private func poll() {
        guard aud_current_pid() >= 0, pending.isEmpty, !scheduled else { return }
        var snap = DeviceSnapshot()
        var raw: Int16 = 0
        if aud_read_speaker_raw(&raw) == 0 {
            snap.speakerRaw = raw
            pollFailures = 0
        } else {
            pollFailures += 1
            if pollFailures >= 5 {  // unplugged, powered off, or not answering
                pollFailures = 0
                let pid = aud_probe()
                DispatchQueue.main.async { self.onResult?(0, pid) }
            }
            return
        }
        func readSwitch(_ which: Int32) -> Bool? {
            var v: Int32 = 0
            return aud_read_monitor_switch(which, &v) == 0 ? v != 0 : nil
        }
        snap.mute = readSwitch(AUD_SW_MUTE)
        var hp: Int32 = 0
        snap.phonesMute = aud_read_headphone_mute(&hp) == 0 ? hp != 0 : nil
        snap.dim = readSwitch(AUD_SW_DIM)
        snap.mono = readSwitch(AUD_SW_MONO)
        snap.alt = readSwitch(AUD_SW_ALT)
        DispatchQueue.main.async { self.onSnapshot?(snap) }
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
            case .phonesMute: r = aud_set_headphone_mute(Int32(v))
            case .mute: r = aud_set_monitor_switch(AUD_SW_MUTE, Int32(v))
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
