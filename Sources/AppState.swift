import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

/// What the iD's front-panel "iD" button does. Raw values are the iD's own function codes.
enum IDButtonFunction: Int, CaseIterable, Identifiable {
    case dim = 0x05, mono = 0x00, monoPolarity = 0x03, alt = 0x0c, talkback = 0x07
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .dim: return "Dim"
        case .mono: return "Mono"
        case .monoPolarity: return "Mono + Polarity"
        case .alt: return "Alt speakers"
        case .talkback: return "Talkback"
        }
    }
}

/// The ten panel designs.
enum PanelLayout: String, CaseIterable, Identifiable {
    case consoleStrip, faceplate, twinKnobs, faderBank, ringFocus, rackUnit, compact, meterBridge, splitSurface, illuminatedKeys
    var id: String { rawValue }
    var title: String {
        switch self {
        case .consoleStrip: return "Console strip"
        case .faceplate: return "Faceplate"
        case .twinKnobs: return "Twin knobs"
        case .faderBank: return "Fader bank"
        case .ringFocus: return "Ring focus"
        case .rackUnit: return "Rack unit"
        case .compact: return "Compact"
        case .meterBridge: return "Meter bridge"
        case .splitSurface: return "Split surface"
        case .illuminatedKeys: return "Illuminated keys"
        }
    }
    var summary: String {
        switch self {
        case .consoleStrip: return "One knob for the selected output, button matrix below"
        case .faceplate: return "LED-ring knob with a switch column; headphones on a trim knob"
        case .twinKnobs: return "Equal knobs for speakers and headphones"
        case .faderBank: return "Two long-throw faders with a switch column"
        case .ringFocus: return "One large LED-ring knob, switches as LEDs"
        case .rackUnit: return "Wide 1U strip with a stereo meter"
        case .compact: return "Smallest: one slider and a key grid"
        case .meterBridge: return "Stereo meter and a large readout"
        case .splitSurface: return "Speakers on top, headphones on a lower plate"
        case .illuminatedKeys: return "Backlit keys and long horizontal faders"
        }
    }
    var usesMeter: Bool { self == .rackUnit || self == .meterBridge }
}

/// Light, Dark, or follow the system.
enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, auto
    var id: String { rawValue }
    var title: String {
        switch self { case .light: return "Light"; case .dark: return "Dark"; case .auto: return "Auto" }
    }
    /// nil = follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .auto: return nil
        }
    }
}

/// Which output a single-knob layout is controlling (the app's own choice — the iD doesn't report its knob mode).
enum KnobTarget: String { case speakers, headphones }

/// Speaker output levels for the panel's meters (dBFS, with fall-back).
final class PanelLevels: ObservableObject {
    @Published var left = -120.0
    @Published var right = -120.0
    func reset() { left = -120; right = -120 }
}

final class AppState: ObservableObject {
    private enum K {
        static let speakers = "speakers", headphones = "headphones"
        static let keys = "volumeKeys", onlyAudient = "keysOnlyWhenAudient", osd = "osdEnabled"
        static let style = "menuBarStyle", showLevel = "showLevelInMenuBar", restore = "restoreOnPowerUp"
        static let barMeter = "menuBarMeter", idFollows = "idLedFollows"
        static let layout = "panelLayout", knobTarget = "knobTarget", appearance = "appearance"
    }
    private let defaults = UserDefaults.standard
    private let writer = USBWriter()
    private let keyTap = MediaKeyTap()
    private let hud = VolumeHUD()
    /// Opens the Settings window (set by the app delegate).
    var openSettings: (() -> Void)?
    /// The Settings window's selected section.
    @Published var settingsTab: SettingsView.Tab = .panel

    /// Set by the app delegate when the popover opens/closes.
    var panelOpen = false { didSet { updateMeterPolling() } }
    let panelLevels = PanelLevels()

    @Published var panelLayout: PanelLayout {
        didSet { defaults.set(panelLayout.rawValue, forKey: K.layout); updateMeterPolling() }
    }
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: K.appearance) }
    }
    @Published var knobTarget: KnobTarget {
        didSet { defaults.set(knobTarget.rawValue, forKey: K.knobTarget) }
    }

    /// Menu bar meter feed: speaker L/R in dBFS.
    var onBarMeter: ((Double, Double) -> Void)?
    private static let silence = -120.0
    private var barLeft = AppState.silence
    private var barRight = AppState.silence

    /// Meter value → dBFS. The iD reports linear peak where 65535 = 0 dBFS.
    private static func dB(_ raw: UInt16) -> Double {
        raw == 0 ? silence : 20 * log10(Double(raw) / 65535)
    }
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
    @Published var dim = false {
        didSet { if !applyingFromDevice { write(.dim, dim ? 1 : 0); followLED(.dim, on: dim) } }
    }
    /// Polarity check. The iD forces Mono on while Polarity is on (and releases it after), so
    /// following the LED uses the "Mono + Polarity" assignment, which matches that exactly.
    @Published var polarity = false {
        didSet {
            guard !applyingFromDevice else { return }
            write(.polarity, polarity ? 1 : 0)
            if polarity { mono = true } else if mono { applyingFromDevice = true; mono = false; applyingFromDevice = false }
            followLED(.monoPolarity, on: polarity)
        }
    }
    /// Talkback. The iD switches Dim on with it (and off after); that comes back via the change queue.
    @Published var talkback = false {
        didSet { if !applyingFromDevice { write(.talkback, talkback ? 1 : 0); followLED(.talkback, on: talkback) } }
    }
    @Published var mono = false {
        didSet { if !applyingFromDevice { write(.mono, mono ? 1 : 0); followLED(.mono, on: mono) } }
    }
    @Published var alt = false {
        didSet { if !applyingFromDevice { write(.alt, alt ? 1 : 0); followLED(.alt, on: alt) } }
    }

    /// The iD button's chosen function (the dropdown) — nil until read from the interface.
    @Published var idButton: IDButtonFunction? = nil {
        didSet {
            guard !applyingFromDevice, let f = idButton, f != oldValue else { return }
            temporaryIDButton = nil
            write(.idButton, Int16(f.rawValue))
        }
    }
    /// When on, switching Dim/Mono/Alt on in the app temporarily assigns the iD button to that
    /// function, because its LED can only show the function it's assigned to.
    @Published var idLedFollows: Bool {
        didSet {
            defaults.set(idLedFollows, forKey: K.idFollows)
            if !idLedFollows { restoreIDButton() }
        }
    }
    private var temporaryIDButton: IDButtonFunction?

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
    @Published var menuBarMeter: Bool {
        didSet {
            defaults.set(menuBarMeter, forKey: K.barMeter)
            updateMeterPolling()
        }
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
        menuBarMeter = defaults.bool(forKey: K.barMeter)
        idLedFollows = defaults.object(forKey: K.idFollows) as? Bool ?? true
        panelLayout = PanelLayout(rawValue: defaults.string(forKey: K.layout) ?? "") ?? .consoleStrip
        knobTarget = KnobTarget(rawValue: defaults.string(forKey: K.knobTarget) ?? "") ?? .speakers
        appearance = AppAppearance(rawValue: defaults.string(forKey: K.appearance) ?? "") ?? .light
        launchAtLogin = SMAppService.mainApp.status == .enabled

        writer.onResult = { [weak self] status, pid in self?.handle(status: status, pid: pid) }
        writer.onSnapshot = { [weak self] snap in self?.applyFromDevice(snap) }
        writer.onMeters = { [weak self] outs in self?.handleMeters(outs) }

        keyTap.handler = { [weak self] key, down, flags in
            guard let self else { return false }
            let out = AudioOutput.current()
            let take = out.isAudient || !self.keysOnlyWhenAudient
            if down {
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
        updateMeterPolling()
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

    /// Scroll wheel / trackpad over the menu bar icon: whole 1 dB steps (see ScrollStepper).
    private let iconScroll = ScrollStepper()
    func scroll(_ event: NSEvent) {
        guard isConnected else { return }
        let n = iconScroll.steps(for: event)
        guard n != 0 else { return }
        speakers = min(1, max(0, speakers + Double(n) / 64))
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
        if let p = snap.polarity, settled(.polarity), p != polarity { polarity = p }
        if let t = snap.talkback, settled(.talkback), t != talkback { talkback = t }
        if let code = snap.idButton, settled(.idButton), temporaryIDButton == nil,
           let f = IDButtonFunction(rawValue: code), f != idButton {
            idButton = f
        }
        // The followed function was switched off (e.g. by pressing the iD button): hand the
        // button back to the dropdown's choice.
        if let t = temporaryIDButton, !isOn(t) { restoreIDButton() }
    }

    // MARK: - iD LED follow

    private func isOn(_ f: IDButtonFunction) -> Bool {
        switch f {
        case .dim: return dim
        case .mono: return mono
        case .alt: return alt
        case .monoPolarity: return mono && polarity
        case .talkback: return talkback
        }
    }

    private func followLED(_ f: IDButtonFunction, on: Bool) {
        guard idLedFollows, isConnected else { return }
        if on {
            guard f != (temporaryIDButton ?? idButton) else { return }
            temporaryIDButton = f
            write(.idButton, Int16(f.rawValue))
        } else if temporaryIDButton == f {
            restoreIDButton()
        }
    }

    private func restoreIDButton() {
        guard temporaryIDButton != nil else { return }
        temporaryIDButton = nil
        if let pref = idButton { write(.idButton, Int16(pref.rawValue)) }
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

    private func updateMeterPolling() {
        let panelMeter = panelOpen && panelLayout.usesMeter
        writer.setMetering(menuBarMeter || panelMeter)
        if !menuBarMeter {
            barLeft = Self.silence
            barRight = Self.silence
        }
        if !panelMeter { panelLevels.reset() }
    }

    private func handleMeters(_ outs: [UInt16]) {
        guard outs.count >= 2 else { return }
        let l = Self.dB(outs[0]), r = Self.dB(outs[1])
        if menuBarMeter {
            barLeft = max(l, max(Self.silence, barLeft - 1.3))    // smooth fall
            barRight = max(r, max(Self.silence, barRight - 1.3))
            onBarMeter?(barLeft, barRight)
        }
        if panelOpen && panelLayout.usesMeter {   // only while someone can see it
            panelLevels.left = max(l, max(Self.silence, panelLevels.left - 1.3))
            panelLevels.right = max(r, max(Self.silence, panelLevels.right - 1.3))
        }
    }

    // MARK: - Convenience for the panels

    /// Level of whichever output a single-knob layout controls.
    var targetLevel: Double {
        get { knobTarget == .speakers ? speakers : headphones }
        set { if knobTarget == .speakers { speakers = newValue } else { headphones = newValue } }
    }
    var targetMuted: Bool { knobTarget == .speakers ? muted : headphonesMuted }
    func toggleTargetMute() { if knobTarget == .speakers { muted.toggle() } else { headphonesMuted.toggle() } }

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

enum USBTarget: Hashable { case speakers, headphones, phonesMute, mute, dim, polarity, talkback, mono, alt, idButton }

struct DeviceSnapshot {
    var speakerRaw: Int16?
    var mute: Bool?
    var phonesMute: Bool?
    var dim: Bool?
    var polarity: Bool?
    var talkback: Bool?
    var mono: Bool?
    var alt: Bool?
    var idButton: Int?
}

final class USBWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "idvolume.usb")
    private var pending: [USBTarget: Int16] = [:]
    private var scheduled = false
    private var pollTimer: DispatchSourceTimer?
    private var pollFailures = 0
    var onResult: ((Int32, Int32) -> Void)?
    var onSnapshot: ((DeviceSnapshot) -> Void)?
    var onMeters: (([UInt16]) -> Void)?
    private var meterTimer: DispatchSourceTimer?

    /// Read the output meters 20×/s while the menu bar meter is on.
    func setMetering(_ on: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if on, self.meterTimer == nil {
                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now(), repeating: .milliseconds(50))
                t.setEventHandler { [weak self] in self?.readMeters() }
                t.resume()
                self.meterTimer = t
            } else if !on, let t = self.meterTimer {
                t.cancel()
                self.meterTimer = nil
            }
        }
    }

    private func readMeters() {
        guard aud_current_pid() >= 0, pending.isEmpty, !scheduled else { return }
        var outs = [UInt16](repeating: 0, count: 6)
        guard aud_read_output_meters(&outs) == 0 else { return }
        DispatchQueue.main.async { self.onMeters?(outs) }
    }

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

    /// Watch the iD's change queue ~25×/s and only read a control when it reports a change —
    /// the same approach Audient's own app uses. A full read every 2 s is the safety net.
    func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(400), repeating: .milliseconds(40))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        pollTimer = t
    }

    private var lastFullRead = Date.distantPast
    private var idButtonRead = false   // read once per connection (plus on change events)

    private func poll() {
        guard aud_current_pid() >= 0, pending.isEmpty, !scheduled else { return }
        if Date().timeIntervalSince(lastFullRead) > 2.0 {
            fullRead()
            return
        }

        // Drain the queue. Each entry names a control (entity << 8 | selector) that changed.
        var changed = Set<Int>()
        for _ in 0..<16 {
            var cs: UInt8 = 0, cn: UInt8 = 0, entity: UInt8 = 0
            let r = aud_read_change_event(&cs, &cn, &entity)
            if r == 1 { changed.insert(Int(entity) << 8 | Int(cs)); continue }
            if r < 0 { noteFailure(); return }
            break
        }
        pollFailures = 0
        guard !changed.isEmpty else { return }

        var snap = DeviceSnapshot()
        if changed.contains(0x3612) {
            var raw: Int16 = 0
            if aud_read_speaker_raw(&raw) == 0 { snap.speakerRaw = raw }
        }
        if changed.contains(0x3604) { snap.mute = readSwitch(AUD_SW_MUTE) }
        if changed.contains(0x3605) { snap.dim = readSwitch(AUD_SW_DIM) }
        if changed.contains(0x3600) { snap.mono = readSwitch(AUD_SW_MONO) }
        if changed.contains(0x3603) { snap.polarity = readSwitch(AUD_SW_POLARITY) }
        if changed.contains(0x3607) { snap.talkback = readSwitch(AUD_SW_TALKBACK) }
        if changed.contains(0x360c) { snap.alt = readSwitch(AUD_SW_ALT) }
        if changed.contains(0x0a01) { snap.phonesMute = readPhonesMute() }
        if changed.contains(0x3610) { snap.idButton = readIDButton() }
        // Anything we don't recognise: pull a full read forward.
        let known: Set<Int> = [0x3612, 0x3604, 0x3605, 0x3600, 0x360c, 0x0a01, 0x0a02, 0x3610, 0x3603, 0x3607]
        if !changed.isSubset(of: known) { lastFullRead = .distantPast }
        DispatchQueue.main.async { self.onSnapshot?(snap) }
    }

    private func fullRead() {
        lastFullRead = Date()
        var snap = DeviceSnapshot()
        var raw: Int16 = 0
        guard aud_read_speaker_raw(&raw) == 0 else { noteFailure(); return }
        pollFailures = 0
        snap.speakerRaw = raw
        snap.mute = readSwitch(AUD_SW_MUTE)
        snap.phonesMute = readPhonesMute()
        snap.dim = readSwitch(AUD_SW_DIM)
        snap.mono = readSwitch(AUD_SW_MONO)
        snap.polarity = readSwitch(AUD_SW_POLARITY)
        snap.talkback = readSwitch(AUD_SW_TALKBACK)
        snap.alt = readSwitch(AUD_SW_ALT)
        if !idButtonRead {
            snap.idButton = readIDButton()
            idButtonRead = snap.idButton != nil
        }
        DispatchQueue.main.async { self.onSnapshot?(snap) }
    }

    private func readIDButton() -> Int? {
        var v: Int32 = 0
        return aud_read_id_button(&v) == 0 ? Int(v) : nil
    }

    private func readSwitch(_ which: Int32) -> Bool? {
        var v: Int32 = 0
        return aud_read_monitor_switch(which, &v) == 0 ? v != 0 : nil
    }

    private func readPhonesMute() -> Bool? {
        var v: Int32 = 0
        return aud_read_headphone_mute(&v) == 0 ? v != 0 : nil
    }

    private func noteFailure() {
        idButtonRead = false   // re-read after a reconnect
        pollFailures += 1
        if pollFailures >= 5 {  // unplugged, powered off, or not answering
            pollFailures = 0
            let pid = aud_probe()
            DispatchQueue.main.async { self.onResult?(0, pid) }
        }
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
            case .polarity: r = aud_set_monitor_switch(AUD_SW_POLARITY, Int32(v))
            case .talkback: r = aud_set_monitor_switch(AUD_SW_TALKBACK, Int32(v))
            case .alt: r = aud_set_monitor_switch(AUD_SW_ALT, Int32(v))
            case .idButton: r = aud_set_id_button(Int32(v))
            }
            if r != 0 { status = r }
        }
        let pid = aud_current_pid()
        DispatchQueue.main.async { self.onResult?(status, pid) }
    }
}
