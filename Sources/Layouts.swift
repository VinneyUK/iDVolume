import SwiftUI

// The ten panel layouts. Each is "controls only" — settings live in the Settings window.

// MARK: - Shared bits

/// Header on every layout: device name, connection LED, settings gear.
struct PanelHeader: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updater: Updater
    var body: some View {
        HStack {
            Text(state.deviceName ?? "No iD interface")
                .font(Skin.readoutFont(16))
                .foregroundStyle(Skin.ink)
            Spacer()
            LEDView(color: state.isConnected ? Skin.green : Skin.red)
                .help(state.lastError ?? (state.isConnected ? "Connected" : "Not connected"))
            Button {
                if updater.availableRelease != nil { state.settingsTab = .updates }
                state.openSettings?()
            } label: {
                Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(Skin.silk)
                    .padding(4).contentShape(Rectangle())
                    .overlay(alignment: .topTrailing) {
                        if updater.availableRelease != nil {
                            Circle().fill(Skin.amber).frame(width: 7, height: 7).offset(x: -1, y: 2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(updater.availableRelease.map { "Version \($0.version) is available — open Settings" } ?? "Settings  ⌘,")
            .accessibilityLabel("Settings")
        }
        .padding(.bottom, 12)
    }
}

/// The five monitor switches (Mute is placed separately by each layout).
struct SwitchGrid: View {
    @EnvironmentObject var state: AppState
    var columns = 5
    var compact = true
    var backlit = false
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            HWKey(label: "Dim", isOn: state.dim, backlit: backlit, compact: compact) { state.dim.toggle() }
            HWKey(label: "Talk", isOn: state.talkback, backlit: backlit, compact: compact) { state.talkback.toggle() }
                .help("Talkback (the iD also dims the monitors)")
            HWKey(label: "Ø Pol", isOn: state.polarity, backlit: backlit, compact: compact) { state.polarity.toggle() }
            HWKey(label: "Mono", isOn: state.mono, backlit: backlit, compact: compact) { state.mono.toggle() }
                .disabled(state.polarity).help(state.polarity ? "Mono stays on while Polarity is on" : "Mono")
            HWKey(label: "Alt", isOn: state.alt, backlit: backlit, compact: compact) { state.alt.toggle() }
        }
    }
}

private func levelText(_ v: Double, muted: Bool) -> String { muted ? "Muted" : "\(dBText(v)) dB" }

// MARK: 1 — Console strip

struct ConsoleStripLayout: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader()
            HWKnob(value: $state.targetLevel, size: 132, dimmed: state.targetMuted,
                   label: state.knobTarget == .speakers ? "Speakers" : "Headphones")
            Readout(text: levelText(state.targetLevel, muted: state.targetMuted), size: 22).padding(.top, 4).padding(.bottom, 14)
            HStack(spacing: 8) {
                HWKey(label: "Dim", isOn: state.dim) { state.dim.toggle() }
                HWKey(label: "Alt", isOn: state.alt) { state.alt.toggle() }
            }.padding(.bottom, 8)
            HStack(spacing: 8) {
                HWKey(label: "Talk", isOn: state.talkback) { state.talkback.toggle() }
                HWKey(label: "Ø", isOn: state.polarity) { state.polarity.toggle() }
                HWKey(label: "Mono", isOn: state.mono) { state.mono.toggle() }.disabled(state.polarity)
            }.padding(.bottom, 12)
            HStack(spacing: 8) {
                outputKey(.speakers, "Speakers", "speaker.wave.2", muted: state.muted)
                outputKey(.headphones, "Phones", "headphones", muted: state.headphonesMuted)
            }
        }
        .frame(width: 218)
    }

    /// Click to select which output the knob controls; click the selected one again to mute it.
    private func outputKey(_ t: KnobTarget, _ label: String, _ icon: String, muted: Bool) -> some View {
        HWKey(label: label, icon: icon, isOn: state.knobTarget == t,
              indicator: muted ? Skin.red : (state.knobTarget == t ? Skin.ledOn : nil), flash: muted) {
            if state.knobTarget == t {
                if t == .speakers { state.muted.toggle() } else { state.headphonesMuted.toggle() }
            } else {
                state.knobTarget = t
            }
        }
        .help(state.knobTarget == t ? "Click to \(muted ? "unmute" : "mute")" : "Control \(label.lowercased()) with the knob")
    }
}

// MARK: 2 — Faceplate

struct FaceplateLayout: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader()
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 4) {
                    HWKnob(value: $state.speakers, size: 150, ring: .segments, dimmed: state.muted, label: "Speakers")
                    SilkText("Speakers")
                    Readout(text: levelText(state.speakers, muted: state.muted), size: 20)
                }
                VStack(spacing: 7) {
                    HWKey(label: "Mute", isOn: state.muted, led: Skin.red, flash: true, horizontal: true, compact: true) { state.muted.toggle() }
                    HWKey(label: "Dim", isOn: state.dim, horizontal: true, compact: true) { state.dim.toggle() }
                    HWKey(label: "Talk", isOn: state.talkback, horizontal: true, compact: true) { state.talkback.toggle() }
                    HWKey(label: "Ø Polarity", isOn: state.polarity, horizontal: true, compact: true) { state.polarity.toggle() }
                    HWKey(label: "Mono", isOn: state.mono, horizontal: true, compact: true) { state.mono.toggle() }.disabled(state.polarity)
                    HWKey(label: "Alt", isOn: state.alt, horizontal: true, compact: true) { state.alt.toggle() }
                }
            }
            Divider().padding(.vertical, 12)
            HStack(spacing: 12) {
                HWKnob(value: $state.headphones, size: 46, dimmed: state.headphonesMuted, label: "Headphones")
                VStack(alignment: .leading, spacing: 1) {
                    SilkText("Headphones")
                    Readout(text: levelText(state.headphones, muted: state.headphonesMuted), size: 15)
                }
                Spacer()
                HWKey(label: "Mute", isOn: state.headphonesMuted, led: Skin.red, flash: true) { state.headphonesMuted.toggle() }
                    .frame(width: 64)
            }
        }
        .frame(width: 298)
    }
}

// MARK: 3 — Twin knobs

struct TwinKnobsLayout: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 14) {
            PanelHeader().padding(.bottom, -14)
            HStack(alignment: .top, spacing: 14) {
                column(level: $state.speakers, muted: state.muted, label: "Speakers", icon: "speaker.wave.2") { state.muted.toggle() }
                column(level: $state.headphones, muted: state.headphonesMuted, label: "Phones", icon: "headphones") { state.headphonesMuted.toggle() }
            }
            SwitchGrid()
        }
        .frame(width: 268)
    }

    private func column(level: Binding<Double>, muted: Bool, label: String, icon: String, mute: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            HWKnob(value: level, size: 104, dimmed: muted, label: label)
            Readout(text: levelText(level.wrappedValue, muted: muted), size: 17)
            HWKey(label: label, icon: icon, isOn: muted, led: Skin.red, flash: true, action: mute)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: 4 — Fader bank

struct FaderBankLayout: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader()
            HStack(alignment: .top, spacing: 14) {
                strip(level: $state.speakers, muted: state.muted, label: "Spk") { state.muted.toggle() }
                strip(level: $state.headphones, muted: state.headphonesMuted, label: "Phones") { state.headphonesMuted.toggle() }
                VStack(spacing: 7) {
                    HWKey(label: "Dim", isOn: state.dim) { state.dim.toggle() }
                    HWKey(label: "Talk", isOn: state.talkback) { state.talkback.toggle() }
                    HWKey(label: "Ø Pol", isOn: state.polarity) { state.polarity.toggle() }
                    HWKey(label: "Mono", isOn: state.mono) { state.mono.toggle() }.disabled(state.polarity)
                    HWKey(label: "Alt", isOn: state.alt) { state.alt.toggle() }
                }
                .padding(.top, 22)
            }
        }
        .frame(width: 268)
    }

    private func strip(level: Binding<Double>, muted: Bool, label: String, mute: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Readout(text: muted ? "—" : dBText(level.wrappedValue), size: 15)
            HWFader(value: level, height: 196, label: label)
            SilkText(label)
            HWKey(label: "Mute", isOn: muted, led: Skin.red, flash: true, compact: true, action: mute).frame(width: 58)
        }
    }
}

// MARK: 5 — Ring focus

struct RingFocusLayout: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader()
            HWSegmented(options: [SegOption(KnobTarget.speakers, "Speakers", icon: "speaker.wave.2", alert: state.muted),
                                  SegOption(KnobTarget.headphones, "Phones", icon: "headphones", alert: state.headphonesMuted)],
                        selection: $state.knobTarget)
            ZStack(alignment: .bottom) {
                HWKnob(value: $state.targetLevel, size: 196, ring: .segments, segments: 31, dimmed: state.targetMuted,
                       label: state.knobTarget == .speakers ? "Speakers" : "Headphones")
                Button { state.toggleTargetMute() } label: {
                    Readout(text: levelText(state.targetLevel, muted: state.targetMuted), size: 20, alert: state.targetMuted)
                }
                .buttonStyle(.plain)
                .help(state.targetMuted ? "Unmute" : "Mute")
            }
            .padding(.vertical, 10)
            HStack {
                ledSwitch("Dim", state.dim) { state.dim.toggle() }
                ledSwitch("Talk", state.talkback) { state.talkback.toggle() }
                ledSwitch("Ø", state.polarity) { state.polarity.toggle() }
                ledSwitch("Mono", state.mono) { state.mono.toggle() }.disabled(state.polarity)
                ledSwitch("Alt", state.alt) { state.alt.toggle() }
            }
        }
        .frame(width: 248)
    }

    private func ledSwitch(_ label: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                LEDView(color: on ? Skin.ledOn : nil, size: 9)
                Text(label.uppercased()).font(Skin.silkFont(11)).tracking(1.4).foregroundStyle(on ? Skin.ink : Skin.silkDim)
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "On" : "Off")
    }
}

// MARK: 6 — Rack unit

struct RackUnitLayout: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 16) {
            screws
            VStack(spacing: 2) {
                HWKnob(value: $state.speakers, size: 84, dimmed: state.muted, label: "Speakers")
                Readout(text: levelText(state.speakers, muted: state.muted), size: 14)
            }
            VStack(spacing: 10) {
                PanelHeader().padding(.bottom, -12)
                HWStereoMeter(levels: state.panelLevels, segments: 30)
                HStack(spacing: 6) {
                    HWKey(label: "Mute", isOn: state.muted, led: Skin.red, flash: true, compact: true) { state.muted.toggle() }
                    HWKey(label: "Dim", isOn: state.dim, compact: true) { state.dim.toggle() }
                    HWKey(label: "Talk", isOn: state.talkback, compact: true) { state.talkback.toggle() }
                    HWKey(label: "Ø", isOn: state.polarity, compact: true) { state.polarity.toggle() }
                    HWKey(label: "Mono", isOn: state.mono, compact: true) { state.mono.toggle() }.disabled(state.polarity)
                    HWKey(label: "Alt", isOn: state.alt, compact: true) { state.alt.toggle() }
                }
            }
            .frame(width: 262)
            VStack(spacing: 3) {
                HWKnob(value: $state.headphones, size: 52, ring: .ticks, dimmed: state.headphonesMuted, label: "Headphones")
                SilkText("Phones", dim: true)
                HWKey(label: "Mute", isOn: state.headphonesMuted, led: Skin.red, flash: true, compact: true) { state.headphonesMuted.toggle() }
                    .frame(width: 60)
            }
            screws
        }
    }

    private var screws: some View {
        VStack { screw; Spacer(); screw }.frame(height: 84)
    }
    private var screw: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(hex: 0xfdfdfd), Color(hex: 0x9ea2a8)], center: .init(x: 0.35, y: 0.35), startRadius: 0, endRadius: 6))
            .overlay(Rectangle().fill(Color(hex: 0x6c7077)).frame(width: 6, height: 1).rotationEffect(.degrees(35)))
            .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            .frame(width: 9, height: 9)
    }
}

// MARK: 7 — Compact

struct CompactLayout: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 10) {
            PanelHeader().padding(.bottom, -10)
            HStack(spacing: 8) {
                Button { state.toggleTargetMute() } label: {
                    Image(systemName: muteIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(state.targetMuted ? Skin.red : Skin.silk)
                        .frame(width: 30, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Skin.keyLight))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Skin.edge, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(state.targetMuted ? "Unmute" : "Mute")
                HWSlider(value: $state.targetLevel, thin: true)
                Readout(text: state.targetMuted ? "—" : dBText(state.targetLevel), size: 14).frame(width: 38, alignment: .trailing)
            }
            HWSegmented(options: [SegOption(KnobTarget.speakers, "Speakers", alert: state.muted),
                                  SegOption(KnobTarget.headphones, "Phones", alert: state.headphonesMuted)],
                        selection: $state.knobTarget)
            SwitchGrid()
        }
        .frame(width: 228)
    }

    private var muteIcon: String {
        if state.targetMuted { return state.knobTarget == .speakers ? "speaker.slash.fill" : "headphones" }
        return state.knobTarget == .speakers ? "speaker.wave.2" : "headphones"
    }
}

// MARK: 8 — Meter bridge

struct MeterBridgeLayout: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 10) {
            PanelHeader().padding(.bottom, -10)
            VStack(spacing: 8) {
                HWStereoMeter(levels: state.panelLevels, segments: 32)
                HStack {
                    ForEach(["−48", "−24", "−12", "−6", "0"], id: \.self) { t in
                        if t != "−48" { Spacer() }
                        SilkText(t, dim: true, size: 9)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Skin.groove.opacity(0.6)))
            HStack(alignment: .firstTextBaseline) {
                SilkText("Speakers")
                Spacer()
                Text(state.muted ? "Muted" : dBText(state.speakers))
                    .font(Skin.readoutFont(40)).foregroundStyle(state.muted ? Skin.red : Skin.ink)
                if !state.muted { Text("dB").font(Skin.readoutFont(16)).foregroundStyle(Skin.silkDim) }
            }
            HWSlider(value: $state.speakers, label: "Speakers")
            HStack(spacing: 8) {
                Image(systemName: "headphones").foregroundStyle(Skin.silkDim)
                HWSlider(value: $state.headphones, thin: true, label: "Headphones")
                HWKey(label: "Mute", isOn: state.headphonesMuted, led: Skin.red, flash: true, compact: true) { state.headphonesMuted.toggle() }
                    .frame(width: 62)
            }
            HStack(spacing: 6) {
                HWKey(label: "Mute", isOn: state.muted, led: Skin.red, flash: true, compact: true) { state.muted.toggle() }
                HWKey(label: "Dim", isOn: state.dim, compact: true) { state.dim.toggle() }
                HWKey(label: "Talk", isOn: state.talkback, compact: true) { state.talkback.toggle() }
                HWKey(label: "Ø", isOn: state.polarity, compact: true) { state.polarity.toggle() }
                HWKey(label: "Mono", isOn: state.mono, compact: true) { state.mono.toggle() }.disabled(state.polarity)
                HWKey(label: "Alt", isOn: state.alt, compact: true) { state.alt.toggle() }
            }
        }
        .frame(width: 268)
    }
}

// MARK: 9 — Split surface

struct SplitSurfaceLayout: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 12) {
            PanelHeader().padding(.bottom, -12)
            HStack(spacing: 14) {
                HWKnob(value: $state.speakers, size: 96, dimmed: state.muted, label: "Speakers")
                VStack(alignment: .leading, spacing: 8) {
                    SilkText("Speakers")
                    Readout(text: levelText(state.speakers, muted: state.muted), size: 24)
                    HWKey(label: "Mute", icon: "speaker.wave.2", isOn: state.muted, led: Skin.red, flash: true, horizontal: true) { state.muted.toggle() }
                }
            }
            SwitchGrid()
            HStack(spacing: 12) {
                HWKnob(value: $state.headphones, size: 54, dimmed: state.headphonesMuted, label: "Headphones")
                VStack(alignment: .leading, spacing: 1) {
                    SilkText("Headphones")
                    Readout(text: levelText(state.headphones, muted: state.headphonesMuted), size: 16)
                }
                Spacer()
                HWKey(label: "Mute", icon: "headphones", isOn: state.headphonesMuted, led: Skin.red, flash: true, horizontal: true) { state.headphonesMuted.toggle() }
                    .frame(width: 96)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Skin.well)
            .padding(.horizontal, -16)
            .padding(.bottom, -16)
        }
        .frame(width: 268)
    }
}

// MARK: 10 — Illuminated keys

struct IlluminatedKeysLayout: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 12) {
            PanelHeader().padding(.bottom, -12)
            fader("Speakers", level: $state.speakers, muted: state.muted)
            fader("Headphones", level: $state.headphones, muted: state.headphonesMuted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                HWKey(label: "Mute", isOn: state.muted, backlit: true, mutedStyle: true) { state.muted.toggle() }
                HWKey(label: "Dim", isOn: state.dim, backlit: true) { state.dim.toggle() }
                HWKey(label: "Talk", isOn: state.talkback, backlit: true) { state.talkback.toggle() }
                HWKey(label: "Ø Pol", isOn: state.polarity, backlit: true) { state.polarity.toggle() }
                HWKey(label: "Mono", isOn: state.mono, backlit: true) { state.mono.toggle() }.disabled(state.polarity)
                HWKey(label: "Alt", isOn: state.alt, backlit: true) { state.alt.toggle() }
            }
            HStack {
                Spacer()
                HWKey(label: "Phones mute", icon: "headphones", isOn: state.headphonesMuted, led: Skin.red, flash: true, horizontal: true, compact: true) {
                    state.headphonesMuted.toggle()
                }
                .frame(width: 140)
            }
        }
        .frame(width: 268)
    }

    private func fader(_ label: String, level: Binding<Double>, muted: Bool) -> some View {
        VStack(spacing: 2) {
            HStack {
                SilkText(label)
                Spacer()
                Readout(text: levelText(level.wrappedValue, muted: muted), size: 14, alert: muted)
            }
            HWSlider(value: level, label: label)
            HStack {
                ForEach(["−∞", "−48", "−32", "−16", "0"], id: \.self) { t in
                    if t != "−∞" { Spacer() }
                    SilkText(t, dim: true, size: 9)
                }
            }
            .padding(.horizontal, 6)
        }
    }
}
