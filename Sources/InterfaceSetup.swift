import AppKit
import SwiftUI

// MARK: - Monitor functions and what the user can hear

/// The monitor switches iDVolume knows about, with the selector each uses on the iD14 MKII.
enum MonitorFunction: String, Codable, CaseIterable, Identifiable {
    case mute, dim, mono, polarity, talkback, alt
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mute: return "Mute"
        case .dim: return "Dim"
        case .mono: return "Mono"
        case .polarity: return "Polarity"
        case .talkback: return "Talkback"
        case .alt: return "Alt speakers"
        }
    }
    var which: Int32 {
        switch self {
        case .mute: return AUD_SW_MUTE
        case .dim: return AUD_SW_DIM
        case .mono: return AUD_SW_MONO
        case .polarity: return AUD_SW_POLARITY
        case .talkback: return AUD_SW_TALKBACK
        case .alt: return AUD_SW_ALT
        }
    }
    var defaultSelector: Int {
        switch self {
        case .mute: return 0x04
        case .dim: return 0x05
        case .mono: return 0x00
        case .polarity: return 0x03
        case .talkback: return 0x07
        case .alt: return 0x0c
        }
    }
}

/// What the user heard during a switch test.
enum SwitchEffect: String, Codable, CaseIterable, Identifiable {
    case quieter, silent, mono, phase, otherSpeakers, talkback, nothing, unsure
    var id: String { rawValue }
    var label: String {
        switch self {
        case .quieter: return "It got quieter"
        case .silent: return "It went silent"
        case .mono: return "It sounded narrower or more central (mono)"
        case .phase: return "It sounded hollow or phasey"
        case .otherSpeakers: return "It switched to other speakers"
        case .talkback: return "A microphone came on"
        case .nothing: return "Nothing I could hear"
        case .unsure: return "Not sure"
        }
    }
    var function: MonitorFunction? {
        switch self {
        case .quieter: return .dim
        case .silent: return .mute
        case .mono: return .mono
        case .phase: return .polarity
        case .otherSpeakers: return .alt
        case .talkback: return .talkback
        case .nothing, .unsure: return nil
        }
    }
}

/// What happened during a level or mute test.
enum OutputEffect: String, Codable, CaseIterable, Identifiable {
    case speakers, headphones, both, nothing, unsure
    var id: String { rawValue }
    var label: String {
        switch self {
        case .speakers: return "The speakers went silent"
        case .headphones: return "The headphones went silent"
        case .both: return "Both went silent"
        case .nothing: return "Nothing I could hear"
        case .unsure: return "Not sure"
        }
    }
}

// MARK: - What was learned about one model

struct ModelProfile: Codable, Equatable {
    var pid: Int32
    var model: String
    var firmware: String
    var speakerLevel: OutputEffect?
    var headphoneFirstChannel: Int?              // nil = not found
    var headphoneMute: OutputEffect?
    var switchEffects: [String: SwitchEffect] = [:]   // "0x05" → what was heard
    var switchMap: [String: Int] = [:]                // function → selector found
    var ledUpdates: Bool?
    var switchInterface: Int?                    // -1 spare interface, 0 interface 0, nil automatic
    var entities: [String]
    var date: Date

    private static func key(_ pid: Int32) -> String { "modelProfile.v2.\(pid)" }

    static func load(pid: Int32) -> ModelProfile? {
        guard let data = UserDefaults.standard.data(forKey: key(pid)) else { return nil }
        return try? JSONDecoder().decode(ModelProfile.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key(pid)) }
    }

    static func delete(pid: Int32) { UserDefaults.standard.removeObject(forKey: key(pid)) }

    // An interface-0 test is "pending" while it runs; if the app finds it on launch, the
    // interface hung during it, so interface 0 is never used for this model again.
    static func pendingKey(_ pid: Int32) -> String { "setup.pendingInterface0.\(pid)" }

    static func recoverFromInterruptedTest(pid: Int32) {
        let d = UserDefaults.standard
        guard d.bool(forKey: pendingKey(pid)) else { return }
        d.removeObject(forKey: pendingKey(pid))
        var p = load(pid: pid) ?? ModelProfile(pid: pid, model: String(cString: aud_product_name(pid)), firmware: "?",
                                               entities: [], date: Date())
        p.switchInterface = -1
        p.ledUpdates = false
        p.save()
    }

    /// Assign each function the selector whose effect matched it. If several matched, the
    /// function's usual selector wins (talkback also dims, polarity also forces mono).
    mutating func computeSwitchMap() {
        var map: [String: Int] = [:]
        for f in MonitorFunction.allCases {
            let matches = switchEffects.compactMap { key, effect -> Int? in
                effect.function == f ? Int(key.dropFirst(2), radix: 16) : nil
            }.sorted()
            if matches.contains(f.defaultSelector) { map[f.rawValue] = f.defaultSelector }
            else if let first = matches.first(where: { sel in !map.values.contains(sel) }) { map[f.rawValue] = first }
        }
        switchMap = map
    }

    var summaryLines: [String] {
        var lines: [String] = []
        lines.append("Speaker level: " + (speakerLevel == .speakers || speakerLevel == .both ? "works" : speakerLevel == nil ? "not tested" : "didn't work"))
        lines.append("Headphone level: " + (headphoneFirstChannel.map { "works (channels \($0) and \($0 + 1))" } ?? "not found"))
        lines.append("Headphone mute: " + (headphoneMute == .headphones ? "works" : headphoneMute == nil ? "not tested" : "didn't work"))
        let found = MonitorFunction.allCases.filter { switchMap[$0.rawValue] != nil }.map(\.title)
        let missing = MonitorFunction.allCases.filter { switchMap[$0.rawValue] == nil }.map(\.title)
        if !switchEffects.isEmpty {
            lines.append("Switches found: " + (found.isEmpty ? "none" : found.joined(separator: ", ")))
            if !missing.isEmpty { lines.append("Not confirmed (using defaults): " + missing.joined(separator: ", ")) }
        }
        lines.append("Front-panel LEDs: " + (ledUpdates == nil ? "not tested"
            : ledUpdates! ? "update (via \(switchInterface == 0 ? "interface 0" : "the spare interface"))" : "don't update"))
        return lines
    }

    func reportURL() -> URL? {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let json = (try? JSONEncoder.pretty.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let effects = switchEffects.sorted { $0.key < $1.key }.map { "- selector \($0.key): \($0.value.label)" }
        let body = """
        **Model:** \(model) (USB product ID 0x\(String(format: "%04x", Int(pid)))), firmware release \(firmware)
        **iDVolume:** \(version) · macOS \(os)

        **Results**
        \(summaryLines.map { "- \($0)" }.joined(separator: "\n"))

        **What each switch command did**
        \(effects.isEmpty ? "- not tested" : effects.joined(separator: "\n"))

        **Audio units reported by the interface**
        \(entities.map { "- \($0)" }.joined(separator: "\n"))

        <details><summary>Profile</summary>

        ```json
        \(json)
        ```
        </details>
        """
        var comps = URLComponents(string: "https://github.com/\(Updater.repo)/issues/new")!
        comps.queryItems = [URLQueryItem(name: "title", value: "Interface profile: \(model) (firmware \(firmware))"),
                            URLQueryItem(name: "body", value: body)]
        return comps.url
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

// MARK: - The assistant's logic

/// Guided discovery. Only ever *sends* commands and asks what the user heard or saw —
/// nothing is read from the interface.
final class InterfaceSetup: ObservableObject {
    enum Step: Equatable {
        case intro, speakerLevel, headphoneLevel, headphoneMute, switchProbe(Int), ledRetry, review
    }

    /// Selectors tried during discovery, in an order that isn't the tiles' order, and labelled
    /// neutrally ("Switch 1 of 6") so the user isn't told what to expect.
    static let probeSelectors = [0x05, 0x0c, 0x04, 0x00, 0x07, 0x03]

    @Published var step: Step = .intro
    @Published var profile: ModelProfile
    @Published private(set) var playing = false
    @Published private(set) var candidates: [Int] = []
    @Published private(set) var candidateIndex = 0
    @Published var outputChoice: OutputEffect?
    @Published var switchChoice: SwitchEffect?
    @Published var ledChanged = false
    @Published private(set) var ledSeen = false
    @Published private(set) var ledRetryPlayed = false
    private unowned let state: AppState

    init(state: AppState) {
        self.state = state
        let pid = state.devicePID ?? -1
        profile = ModelProfile(pid: pid, model: state.deviceName ?? "iD", firmware: "?", entities: [], date: Date())
        identify()
        state.perform { aud_set_switch_interface(-1) }   // discovery always starts on the safe route
    }

    var currentChannel: Int? { candidateIndex < candidates.count ? candidates[candidateIndex] : nil }
    var stepNumber: Int {
        switch step {
        case .intro: return 0
        case .speakerLevel: return 1
        case .headphoneLevel: return 2
        case .headphoneMute: return 3
        case .switchProbe: return 4
        case .ledRetry: return 5
        case .review: return 6
        }
    }

    private func identify() {
        let pid = profile.pid
        state.perform { [weak self] in
            var buf = [AudEntity](repeating: AudEntity(), count: 64)
            let n = Int(aud_list_audio_entities(&buf, 64))
            let release = aud_device_release()
            let units = n > 0 ? Array(buf[0..<n]) : []
            DispatchQueue.main.async {
                guard let self else { return }
                self.profile.firmware = String(format: "%x.%02x", Int(release >> 8), Int(release & 0xff))
                self.profile.entities = units.map { u in
                    String(format: "0x%02x ", Int(u.id)) + Self.name(ofSubtype: u.subtype)
                        + (u.channels > 0 ? " (\(u.channels) channels)" : "")
                }
                let fuChannels = Int(units.first(where: { $0.id == 0x0a && $0.subtype == 0x06 })?.channels ?? 0)
                var order = (pid == 0x0002 || fuChannels < 6) ? [3, 5, 1] : [5, 3, 1]
                if fuChannels >= 2 { order = order.filter { $0 + 1 <= fuChannels } }
                self.candidates = order.isEmpty ? [3, 5, 1] : order
            }
        }
    }

    static func name(ofSubtype s: UInt8) -> String {
        switch s {
        case 0x02: return "input terminal"
        case 0x03: return "output terminal"
        case 0x04: return "mixer unit"
        case 0x05: return "selector unit"
        case 0x06: return "feature unit"
        case 0x07, 0x08: return "processing unit"
        case 0x09: return "extension unit"
        case 0x0a: return "clock source"
        case 0x0b: return "clock selector"
        default: return String(format: "unit type 0x%02x", Int(s))
        }
    }

    // MARK: Playing tests

    private func pulse(_ on: @escaping () -> Void, _ off: @escaping () -> Void, hold: Double, times: Int = 1) {
        playing = true
        func round(_ left: Int) {
            state.perform(on)
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                self.state.perform(off)
                if left > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { round(left - 1) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.playing = false }
                }
            }
        }
        round(times)
    }

    private var headphoneRaw: Int16 { aud_raw_from_position(state.headphones, AUD_DEFAULT_FLOOR_DB) }
    private var speakerRaw: Int16 { aud_raw_from_position(state.speakers, AUD_DEFAULT_FLOOR_DB) }

    func play() {
        switch step {
        case .speakerLevel:
            let back = speakerRaw
            pulse({ _ = aud_set_speaker_raw(Int16.min) }, { _ = aud_set_speaker_raw(back) }, hold: 0.7, times: 2)
        case .headphoneLevel:
            guard let ch = currentChannel else { return }
            let back = headphoneRaw
            pulse({ aud_set_hp_channel_override(Int32(ch)); _ = aud_set_headphone_raw(Int16.min) },
                  { _ = aud_set_headphone_raw(back) }, hold: 0.7, times: 2)
        case .headphoneMute:
            let was: Int32 = state.headphonesMuted ? 1 : 0
            pulse({ _ = aud_set_headphone_mute(1) }, { _ = aud_set_headphone_mute(was) }, hold: 1.2)
        case .switchProbe(let i):
            let sel = Int32(Self.probeSelectors[i])
            pulse({ _ = aud_send_monitor_selector(sel, 1) }, { _ = aud_send_monitor_selector(sel, 0) }, hold: 2.0)
        case .ledRetry:
            ledRetryPlayed = true
            UserDefaults.standard.set(true, forKey: ModelProfile.pendingKey(profile.pid))
            let sel = Int32(profile.switchMap[MonitorFunction.mute.rawValue] ?? MonitorFunction.mute.defaultSelector)
            pulse({ aud_set_switch_interface(0); _ = aud_send_monitor_selector(sel, 1) },
                  { _ = aud_send_monitor_selector(sel, 0) }, hold: 1.5)
        case .intro, .review:
            break
        }
    }

    // MARK: Answers

    var canContinue: Bool {
        switch step {
        case .speakerLevel, .headphoneLevel, .headphoneMute: return outputChoice != nil && !playing
        case .switchProbe: return switchChoice != nil && !playing
        default: return !playing
        }
    }

    /// Hint shown after an unexpected answer, before moving on.
    var hint: String? {
        switch (step, outputChoice) {
        case (.headphoneLevel, .speakers?):
            return "Those channels control the speakers on this model — Next will try another pair."
        case (.headphoneLevel, .nothing?):
            return candidateIndex + 1 < candidates.count ? "Next will try another pair of channels." : nil
        case (.speakerLevel, .headphones?):
            return "Interesting — that's the headphones. This will be noted in the results."
        default:
            return nil
        }
    }

    func next() {
        switch step {
        case .intro:
            step = .speakerLevel
        case .speakerLevel:
            profile.speakerLevel = outputChoice
            advance(to: .headphoneLevel)
        case .headphoneLevel:
            switch outputChoice {
            case .headphones?, .both?:
                profile.headphoneFirstChannel = currentChannel
                advance(to: .headphoneMute)
            case .unsure?:
                outputChoice = nil                              // play it again
            default:                                            // speakers, or nothing: try the next pair
                if candidateIndex + 1 < candidates.count {
                    candidateIndex += 1
                    outputChoice = nil
                } else {
                    profile.headphoneFirstChannel = nil
                    state.perform { aud_set_hp_channel_override(0) }
                    advance(to: .switchProbe(0))
                }
            }
        case .headphoneMute:
            profile.headphoneMute = outputChoice
            advance(to: .switchProbe(0))
        case .switchProbe(let i):
            let key = String(format: "0x%02x", Self.probeSelectors[i])
            if let c = switchChoice { profile.switchEffects[key] = c }
            if ledChanged { ledSeen = true }
            if i + 1 < Self.probeSelectors.count {
                advance(to: .switchProbe(i + 1))
            } else {
                profile.computeSwitchMap()
                if ledSeen {
                    profile.ledUpdates = true
                    profile.switchInterface = -1
                    advance(to: .review)
                } else {
                    advance(to: .ledRetry)
                }
            }
        case .ledRetry, .review:
            break
        }
    }

    func answerLED(_ changed: Bool?) {
        UserDefaults.standard.removeObject(forKey: ModelProfile.pendingKey(profile.pid))
        if changed == true {
            profile.ledUpdates = true
            profile.switchInterface = 0
        } else {
            profile.ledUpdates = changed == false ? false : nil
            profile.switchInterface = -1
            state.perform { aud_set_switch_interface(-1) }
        }
        advance(to: .review)
    }

    func skip() {
        switch step {
        case .speakerLevel: advance(to: .headphoneLevel)
        case .headphoneLevel: advance(to: .headphoneMute)
        case .headphoneMute: advance(to: .switchProbe(0))
        case .switchProbe(let i):
            if i + 1 < Self.probeSelectors.count { advance(to: .switchProbe(i + 1)) }
            else { profile.computeSwitchMap(); advance(to: ledSeen ? .review : .ledRetry) }
        case .ledRetry: answerLED(nil)
        case .intro, .review: break
        }
    }

    private func advance(to s: Step) {
        outputChoice = nil
        switchChoice = nil
        ledChanged = false
        step = s
    }

    func finish() {
        profile.date = Date()
        state.saveProfile(profile)
    }
}

// MARK: - Assistant view (embedded in Settings → Setup)

struct InterfaceSetupView: View {
    @ObservedObject var setup: InterfaceSetup
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if setup.stepNumber > 0 {
                        Text("Step \(setup.stepNumber) of 6").font(.system(size: 11)).foregroundStyle(Skin.silkDim)
                    }
                }
                Spacer()
                Button("Cancel", action: close).controlSize(.small)
            }
            ProgressView(value: Double(setup.stepNumber), total: 6).tint(Skin.keyDark)
            content
        }
        .foregroundStyle(Skin.ink)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Skin.well))
    }

    private var title: String {
        switch setup.step {
        case .intro: return "Set up your \(setup.profile.model)"
        case .speakerLevel: return "Speaker level"
        case .headphoneLevel: return "Headphone level"
        case .headphoneMute: return "Headphone mute"
        case .switchProbe(let i): return "Switch \(i + 1) of \(InterfaceSetup.probeSelectors.count)"
        case .ledRetry: return "Optional: front-panel LEDs"
        case .review: return "Results"
        }
    }

    @ViewBuilder private var content: some View {
        switch setup.step {
        case .intro:
            VStack(alignment: .leading, spacing: 12) {
                para("Each test changes one thing for a moment, then puts it back. You say what you heard, and iDVolume works out which controls do what on your interface.")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Before you start").font(.system(size: 13, weight: .semibold))
                    bullet("Play some music — from Spotify, Apple Music or anything else — at a comfortable level.")
                    bullet("Make sure you can hear it through your speakers, and plug in headphones so you can hear it through those too.")
                    bullet("Set iDVolume's Speakers and Headphones sliders to a comfortable level. Each test goes back to those levels afterwards.")
                }

                safetyPanel

                Text("Found: \(setup.profile.model), firmware \(setup.profile.firmware), \(setup.profile.entities.count) audio units")
                    .font(.system(size: 11)).foregroundStyle(Skin.silkDim)
                Button("Start") { setup.next() }.keyboardShortcut(.defaultAction)
            }
        case .speakerLevel:
            outputTest("Listen to the speakers and headphones, then play the test.",
                       detail: "The main level is set to silent twice, then put back.")
        case .headphoneLevel:
            outputTest("Play the test and listen.",
                       detail: setup.currentChannel.map { "Trying the headphone level on channels \($0) and \($0 + 1)." })
        case .headphoneMute:
            outputTest("Play the test and listen.", detail: "The headphone mute switches on for a moment.")
        case .switchProbe:
            VStack(alignment: .leading, spacing: 10) {
                playButton
                para("What happened while it played? (It lasts 2 seconds.)")
                options(SwitchEffect.allCases, selection: $setup.switchChoice)
                Toggle("An LED on the interface changed", isOn: $setup.ledChanged).toggleStyle(.checkbox)
                nav
            }
        case .ledRetry:
            VStack(alignment: .leading, spacing: 10) {
                para("No LEDs changed during the switch tests. iDVolume can try sending mute the way Audient's own app does, which is what makes the LEDs update on the iD14 MKII.")
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("This step is optional and carries a small risk: it sends mute by a different route that hasn't been tested on your model. If the interface stops responding, unplug it for a few seconds — iDVolume will remember not to try this again. Skipping it is completely fine: everything else keeps working, only the LEDs won't follow the app.")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                if setup.ledRetryPlayed {
                    playButton
                    para("Did the mute LED light or flash?")
                    HStack {
                        Button("Yes") { setup.answerLED(true) }
                        Button("No") { setup.answerLED(false) }
                        Button("Not sure") { setup.answerLED(nil) }
                    }
                    .disabled(setup.playing)
                } else {
                    HStack {
                        Button("Try It") { setup.play() }
                        Button("Skip This Step") { setup.skip() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        case .review:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(setup.profile.summaryLines, id: \.self) { Text("• " + $0).font(.system(size: 12)) }
                para("Saving applies these to your interface straight away. Sending them helps build support for your model into iDVolume for everyone.")
                    .padding(.top, 4)
                HStack {
                    Button("Save") { setup.finish(); close() }.keyboardShortcut(.defaultAction)
                    Button("Save and Send Results…") {
                        setup.finish()
                        if let url = setup.profile.reportURL() { NSWorkspace.shared.open(url) }
                        close()
                    }
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var safetyPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill").font(.system(size: 18)).foregroundStyle(Skin.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("This setup is safe").font(.system(size: 13, weight: .semibold))
                Text("It only sends commands — the same kind iDVolume's own buttons send — and never reads anything from your interface. Reading is what can freeze an untested interface, so this won't. One optional step near the end has a small risk, and it asks first.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Skin.green.opacity(0.1)))
    }

    private var playButton: some View {
        Button { setup.play() } label: {
            Label(setup.playing ? "Playing…" : "Play Test", systemImage: "play.fill")
        }
        .disabled(setup.playing)
    }

    private var nav: some View {
        HStack {
            Button("Next") { setup.next() }.keyboardShortcut(.defaultAction).disabled(!setup.canContinue)
            Button("Skip") { setup.skip() }.disabled(setup.playing)
        }
    }

    private func outputTest(_ lead: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            para(lead)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Skin.silkDim) }
            playButton
            options(OutputEffect.allCases, selection: $setup.outputChoice)
            if let hint = setup.hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(Skin.silk).fixedSize(horizontal: false, vertical: true)
            }
            nav
        }
    }

    private func options<T: Identifiable & Equatable>(_ all: [T], selection: Binding<T?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(all) { option in
                Button { selection.wrappedValue = option } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selection.wrappedValue == option ? "largecircle.fill.circle" : "circle")
                        Text(label(for: option)).font(.system(size: 13))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(setup.playing)
            }
        }
    }

    private func label<T>(for option: T) -> String {
        if let o = option as? OutputEffect { return o.label }
        if let s = option as? SwitchEffect { return s.label }
        return "\(option)"
    }

    private func para(_ s: String) -> some View {
        Text(s).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Settings → Setup

/// A large two-line choice button, used for "which interface do you have?".
struct ModeChoice: View {
    let title: String
    let detail: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.system(size: 15))
                Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).opacity(0.8).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .foregroundStyle(selected ? Color.white : Skin.ink)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? AnyShapeStyle(Skin.keyOn) : AnyShapeStyle(Skin.keyLight)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Skin.edgeOn : Skin.edge))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SetupTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !state.isConnected {
                Text("Connect your iD interface.").font(.system(size: 13))
            } else if state.modelIsVerified {
                Label("Your \(state.deviceName ?? "iD14 MKII") is fully supported — there's nothing to set up.",
                      systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13))
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.shield.fill").font(.system(size: 20)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(state.deviceName ?? "This interface") isn't supported yet")
                            .font(.system(size: 14, weight: .semibold))
                        Text("iDVolume currently works with the iD14 MKII only. Commands that are safe on the MKII can lock up other models (the original iD14 treats them as the start of a firmware update), so iDVolume sends this interface no commands at all.")
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Text("Sending its details (read from its standard USB description; nothing is sent to it) helps work out safe support in future.")
                            .font(.system(size: 12)).foregroundStyle(Skin.silk).fixedSize(horizontal: false, vertical: true)
                        Button("Send Details to the Developer…") { state.sendUnsupportedReport() }.padding(.top, 4)
                    }
                }
            }
        }
        .foregroundStyle(Skin.ink)
    }
}

// MARK: - First connection of an interface that isn't supported

struct WelcomeView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill").font(.system(size: 22)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(state.deviceName ?? "This interface") isn't supported yet").font(.system(size: 16, weight: .semibold))
                    Text("iDVolume currently works with the iD14 MKII only").font(.system(size: 12)).foregroundStyle(Skin.silkDim)
                }
            }
            Text("To keep your interface safe, iDVolume won't send it any commands, so its controls are switched off. Sending its details (read-only) helps work out support for it in future.")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Send Details to the Developer…") { state.welcomeChoice(.sendDetails) }
                Spacer()
                Button("OK") { state.welcomeChoice(.ok) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .foregroundStyle(Skin.ink)
        .background(Skin.plate)
    }
}
