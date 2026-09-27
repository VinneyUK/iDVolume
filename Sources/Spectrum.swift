import Accelerate
import AppKit
import CoreAudio
import os
import SwiftUI

// MARK: - Styles

enum VisualiserMode: String, CaseIterable, Identifiable {
    case spectrum, bars, spectrogram, waveform, oscilloscope, stereometer, loudness, vu
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spectrum: return "Spectrum"
        case .bars: return "Bars"
        case .spectrogram: return "Spectrogram"
        case .waveform: return "Waveform"
        case .oscilloscope: return "Oscilloscope"
        case .stereometer: return "Stereometer"
        case .loudness: return "Loudness"
        case .vu: return "VU"
        }
    }
    var needsSpectrum: Bool { self == .spectrum || self == .bars || self == .spectrogram }
    var needsSamples: Bool { self == .oscilloscope || self == .stereometer }
    var next: VisualiserMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Everything a style might draw, for one frame. Fields a style doesn't need stay empty.
struct VisFrame {
    var live: [Float] = []           // spectrum, 0…1 per log-frequency point
    var average: [Float] = []
    var left: [Float] = []           // recent samples (oscilloscope, stereometer)
    var right: [Float] = []
    var blockPeak: Float = 0         // peak since the previous frame, linear 0…1 (waveform)
    var truePeakDB = -120.0          // held true peak, dBTP (BS.1770-4, 4× oversampled)
    var momentary = -120.0           // LUFS, 400 ms
    var shortTerm = -120.0           // LUFS, 3 s
    var integrated = -120.0          // LUFS, gated, since the last reset
    var rmsFastDB = -120.0           // 300 ms RMS (per-channel power)
    var vu = -20.0                   // VU units, 0 VU = −18 dBFS
    var correlation: Float = 0       // −1…+1
}

// MARK: - BS.1770-4 loudness

/// Biquad filter (transposed direct form II).
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
    mutating func reset() { z1 = 0; z2 = 0 }

    /// The two K-weighting stages from ITU-R BS.1770-4, for any sample rate.
    static func kWeighting(sampleRate fs: Double) -> (Biquad, Biquad) {
        // Stage 1: high-frequency shelf (+4 dB above ~1.7 kHz), models the head.
        var f0 = 1681.974450955533, q = 0.7071752369554196
        let gain = 3.999843853973347
        var k = tan(.pi * f0 / fs)
        let vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        var shelf = Biquad()
        shelf.b0 = (vh + vb * k / q + k * k) / a0
        shelf.b1 = 2 * (k * k - vh) / a0
        shelf.b2 = (vh - vb * k / q + k * k) / a0
        shelf.a1 = 2 * (k * k - 1) / a0
        shelf.a2 = (1 - k / q + k * k) / a0
        // Stage 2: low cut (~38 Hz).
        f0 = 38.13547087602444; q = 0.5003270373238773
        k = tan(.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        var highPass = Biquad()
        highPass.b0 = 1; highPass.b1 = -2; highPass.b2 = 1
        highPass.a1 = 2 * (k * k - 1) / a0
        highPass.a2 = (1 - k / q + k * k) / a0
        return (shelf, highPass)
    }
}

/// Momentary, short-term and gated integrated loudness plus true peak, per BS.1770-4.
/// Fed sample by sample; energy is kept in 100 ms steps.
struct LoudnessMeter {
    private var kL: (Biquad, Biquad), kR: (Biquad, Biquad)
    private let stepSamples: Int
    private var stepEnergy = 0.0, stepCount = 0
    private var steps: [Double] = []          // mean-square energy of recent 100 ms steps
    private var gatingBlocks: [Double] = []   // 400 ms block energies above the absolute gate
    private var historyL = [Double](repeating: 0, count: 12), historyR = [Double](repeating: 0, count: 12)
    private var historyPos = 0
    private(set) var truePeak = 0.0

    // BS.1770-4 Annex 2: 4-phase, 12-tap interpolation filter for true-peak (4× oversampling).
    private static let phases: [[Double]] = [
        [0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
         0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500],
        [-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
         0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375],
        [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
         0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875],
        [-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
         0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750],
    ]

    init(sampleRate: Double) {
        kL = Biquad.kWeighting(sampleRate: sampleRate)
        kR = kL
        stepSamples = max(1, Int(sampleRate / 10))
    }

    mutating func reset() {
        kL.0.reset(); kL.1.reset(); kR.0.reset(); kR.1.reset()
        stepEnergy = 0; stepCount = 0
        steps.removeAll(); gatingBlocks.removeAll()
        historyL = Array(repeating: 0, count: 12); historyR = historyL
        truePeak = 0
    }

    mutating func resetIntegrated() { gatingBlocks.removeAll() }

    /// Peak hold falls ~20 dB/s so the readout stays readable.
    mutating func decayPeak() { truePeak *= 0.85 }

    mutating func process(_ l: Float, _ r: Float) {
        let x = Double(l), y = Double(r)
        // Loudness: K-weighted energy of both channels (channel weights 1.0).
        let zl = kL.1.process(kL.0.process(x)), zr = kR.1.process(kR.0.process(y))
        stepEnergy += zl * zl + zr * zr
        stepCount += 1
        if stepCount == stepSamples {
            steps.append(stepEnergy / Double(stepCount))
            if steps.count > 30 { steps.removeFirst(steps.count - 30) }
            stepEnergy = 0; stepCount = 0
            // A 400 ms gating block every 100 ms (75% overlap).
            if steps.count >= 4 {
                let block = steps.suffix(4).reduce(0, +) / 4
                if Self.lufs(block) > -70 { gatingBlocks.append(block) }   // absolute gate
            }
        }
        // True peak: the sample itself and three interpolated points between samples.
        historyL[historyPos] = x; historyR[historyPos] = y
        historyPos = (historyPos + 1) % 12
        var peak = max(abs(x), abs(y))
        for phase in Self.phases {
            var sl = 0.0, sr = 0.0
            for t in 0..<12 {
                let idx = (historyPos + 11 - t) % 12       // newest sample first
                sl += phase[t] * historyL[idx]
                sr += phase[t] * historyR[idx]
            }
            peak = max(peak, abs(sl), abs(sr))
        }
        truePeak = max(truePeak, peak)
    }

    static func lufs(_ energy: Double) -> Double { energy > 1e-12 ? -0.691 + 10 * log10(energy) : -120 }

    var momentary: Double { steps.count >= 4 ? Self.lufs(steps.suffix(4).reduce(0, +) / 4) : -120 }
    var shortTerm: Double { steps.count >= 30 ? Self.lufs(steps.suffix(30).reduce(0, +) / 30) : momentary }

    /// Gated integrated loudness: absolute gate −70 LUFS, then relative gate 10 LU below.
    var integrated: Double {
        guard !gatingBlocks.isEmpty else { return -120 }
        let ungated = gatingBlocks.reduce(0, +) / Double(gatingBlocks.count)
        let threshold = Self.lufs(ungated) - 10
        let kept = gatingBlocks.filter { Self.lufs($0) > threshold }
        return kept.isEmpty ? -120 : Self.lufs(kept.reduce(0, +) / Double(kept.count))
    }
}

// MARK: - Analyser

/// Taps what the Mac is playing (a Core Audio process tap, macOS 14.2+) and prepares
/// whatever the selected style needs. The audio is analysed in memory and never recorded,
/// saved or sent anywhere. Runs only while the visualiser is on screen.
final class SpectrumAnalyzer: ObservableObject {
    enum Status: Equatable { case off, running, unsupported, failed(String) }

    static let points = 120
    @Published private(set) var status: Status = .off
    weak var renderer: VisualiserNSView?
    var mode: VisualiserMode = .spectrum

    private let n = 4096
    private let ringSize = 65_536          // ~1.4 s at 48 kHz, per channel
    private var ringL: [Float]
    private var ringR: [Float]
    private var ringPos = 0
    private var lastReadPos = 0
    private let lock = OSAllocatedUnfairLock()
    private var sampleRate = 48_000.0
    private var live = [Float](repeating: 0, count: points)
    private var average = [Float](repeating: 0, count: points)
    private var window: [Float]
    private var dft: vDSP_DFT_Setup?
    private var timer: Timer?
    private var silentFrames = 0
    private var msFast = 0.0, heldPeak = 0.0
    private var loudness: LoudnessMeter?
    private var integratedCache = -120.0, integratedCountdown = 0

    /// Start integrated loudness again (click the Loudness display).
    func resetIntegrated() { loudness?.resetIntegrated(); integratedCache = -120 }

    private var tapChannels = 2
    private var tapInterleaved = true
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init() {
        ringL = [Float](repeating: 0, count: ringSize)
        ringR = [Float](repeating: 0, count: ringSize)
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    deinit { stop() }

    var isSilent: Bool { silentFrames > 60 }

    func start() {
        guard status != .running else { return }
        guard #available(macOS 14.2, *) else { status = .unsupported; return }
        do {
            try startTap()
            status = .running
            silentFrames = 0
            // Run in the "common" modes, so it keeps going while a knob or fader is being dragged
            // (macOS pauses default-mode timers during mouse tracking).
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.analyse() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } catch {
            stopTap()
            status = .failed("\(error)")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopTap()
        if status == .running { status = .off }
        live = [Float](repeating: 0, count: Self.points)
        average = live
        msFast = 0; heldPeak = 0
        loudness = nil
        renderer?.render(VisFrame(), hint: nil)
    }

    // MARK: Tap

    struct TapError: Error, CustomStringConvertible {
        let step: String, code: OSStatus
        var description: String { "\(step) failed (\(code))" }
    }

    @available(macOS 14.2, *)
    private func startTap() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { throw TapError(step: "Creating the audio tap", code: err) }
        tapID = tap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            sampleRate = format.mSampleRate
        }
        tapChannels = max(1, Int(format.mChannelsPerFrame))
        tapInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "iDVolume Visualiser",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        if let outUID = Self.defaultOutputUID() {
            description[kAudioAggregateDeviceMainSubDeviceKey] = outUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outUID]]
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard err == noErr else { throw TapError(step: "Creating the capture device", code: err) }
        aggregateID = aggregate

        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) { [weak self] _, input, _, _, _ in
            self?.ingest(input)
        }
        guard err == noErr, let proc else { throw TapError(step: "Starting capture", code: err) }
        procID = proc
        err = AudioDeviceStart(aggregateID, proc)
        guard err == noErr else { throw TapError(step: "Starting capture", code: err) }
    }

    private func stopTap() {
        if let proc = procID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func defaultOutputUID() -> String? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr, let u = uid else { return nil }
        return u.takeRetainedValue() as String
    }

    /// Real-time audio thread: store left and right into the ring buffers. No allocation.
    /// The capture device lists the output interface's own inputs first and the Mac's
    /// playback (the tap) last, so read from the end.
    private func ingest(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let count = buffers.count
        guard count > 0 else { return }
        lock.withLock {
            let mask = ringSize - 1
            if tapInterleaved {
                let b = buffers[count - 1]
                guard let data = b.mData else { return }
                let ch = max(1, Int(b.mNumberChannels))
                let p = data.assumingMemoryBound(to: Float.self)
                let frames = Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch)
                for f in 0..<frames {
                    ringL[ringPos] = p[f * ch]
                    ringR[ringPos] = ch > 1 ? p[f * ch + 1] : p[f * ch]
                    ringPos = (ringPos + 1) & mask
                }
            } else {
                let li = max(0, count - tapChannels)
                let ri = min(count - 1, li + 1)
                guard let ld = buffers[li].mData, let rd = buffers[ri].mData else { return }
                let l = ld.assumingMemoryBound(to: Float.self), r = rd.assumingMemoryBound(to: Float.self)
                let frames = Int(buffers[li].mDataByteSize) / MemoryLayout<Float>.size
                for f in 0..<frames {
                    ringL[ringPos] = l[f]
                    ringR[ringPos] = r[f]
                    ringPos = (ringPos + 1) & mask
                }
            }
        }
    }

    // MARK: Analysis (main thread, 30×/s)

    private func analyse() {
        let mask = ringSize - 1
        var frame = VisFrame()
        var newL = [Float](), newR = [Float]()
        var fftL = [Float](), fftR = [Float]()
        let wantRecent = mode.needsSamples ? 2048 : 0
        lock.withLock {
            // Samples that arrived since the last frame (levels, waveform, VU).
            let fresh = min((ringPos - lastReadPos + ringSize) & mask, ringSize / 2)
            newL = (0..<fresh).map { ringL[(ringPos - fresh + $0 + ringSize) & mask] }
            newR = (0..<fresh).map { ringR[(ringPos - fresh + $0 + ringSize) & mask] }
            lastReadPos = ringPos
            if mode.needsSpectrum {
                fftL = (0..<n).map { ringL[(ringPos - n + $0 + ringSize) & mask] }
                fftR = (0..<n).map { ringR[(ringPos - n + $0 + ringSize) & mask] }
            }
            if wantRecent > 0 {
                frame.left = (0..<wantRecent).map { ringL[(ringPos - wantRecent + $0 + ringSize) & mask] }
                frame.right = (0..<wantRecent).map { ringR[(ringPos - wantRecent + $0 + ringSize) & mask] }
            }
        }

        // Levels: 300 ms RMS from each channel's power (per-sample smoothing over the fresh block).
        let aFast = 1 - exp(-1 / (0.3 * sampleRate))
        var blockPeak: Float = 0
        for i in 0..<newL.count {
            let l = Double(newL[i]), r = Double(newR[i])
            msFast += ((l * l + r * r) * 0.5 - msFast) * aFast
            blockPeak = max(blockPeak, abs(newL[i]), abs(newR[i]))
        }
        heldPeak = max(Double(blockPeak), heldPeak * 0.97)
        func db(_ x: Double) -> Double { x > 1e-9 ? 20 * log10(x) : -120 }
        frame.blockPeak = blockPeak
        frame.rmsFastDB = db(sqrt(msFast))
        frame.vu = min(3, max(-20, frame.rmsFastDB + 18))

        if mode == .loudness {
            if loudness == nil { loudness = LoudnessMeter(sampleRate: sampleRate) }
            loudness!.decayPeak()
            for i in 0..<newL.count { loudness!.process(newL[i], newR[i]) }
            frame.truePeakDB = db(loudness!.truePeak)
            frame.momentary = loudness!.momentary
            frame.shortTerm = loudness!.shortTerm
            if integratedCountdown <= 0 {                 // gating over the whole session: every ~0.3 s
                integratedCache = loudness!.integrated
                integratedCountdown = 10
            }
            integratedCountdown -= 1
            frame.integrated = integratedCache
        } else if loudness != nil {
            loudness = nil                                // not shown: stop measuring
            integratedCache = -120
        }

        if mode == .stereometer, !frame.left.isEmpty {
            var lr: Float = 0, ll: Float = 0, rr: Float = 0
            vDSP_dotpr(frame.left, 1, frame.right, 1, &lr, vDSP_Length(frame.left.count))
            vDSP_svesq(frame.left, 1, &ll, vDSP_Length(frame.left.count))
            vDSP_svesq(frame.right, 1, &rr, vDSP_Length(frame.right.count))
            frame.correlation = ll * rr > 1e-12 ? lr / sqrt(ll * rr) : 0
        }

        if mode.needsSpectrum, !fftL.isEmpty { spectrum(from: fftL, fftR) }
        frame.live = mode.needsSpectrum ? live : []
        frame.average = mode.needsSpectrum ? average : []

        silentFrames = blockPeak < 0.001 ? silentFrames + 1 : 0
        if silentFrames > 0, silentFrames % 150 == 0, #available(macOS 14.2, *) {
            stopTap()
            do { try startTap() } catch { status = .failed("\(error)") }
        }
        renderer?.render(frame, hint: nil)   // no nagging when nothing is playing
    }

    private func spectrum(from l: [Float], _ r: [Float]) {
        var mono = [Float](repeating: 0, count: n)
        vDSP_vadd(l, 1, r, 1, &mono, 1, vDSP_Length(n))
        var half: Float = 0.5
        vDSP_vsmul(mono, 1, &half, &mono, 1, vDSP_Length(n))
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(mono, 1, window, 1, &windowed, 1, vDSP_Length(n))
        if dft == nil { dft = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD) }
        guard let dft else { return }
        let h = n / 2
        var inR = [Float](repeating: 0, count: h), inI = [Float](repeating: 0, count: h)
        for i in 0..<h { inR[i] = windowed[2 * i]; inI[i] = windowed[2 * i + 1] }
        var outR = [Float](repeating: 0, count: h), outI = [Float](repeating: 0, count: h)
        vDSP_DFT_Execute(dft, inR, inI, &outR, &outI)
        var mags = [Float](repeating: 0, count: h)
        outR.withUnsafeMutableBufferPointer { rp in
            outI.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(h))
            }
        }
        let binHz = sampleRate / Double(n)
        let norm = 4 / Float(n * n)
        for p in 0..<Self.points {
            let f0 = 20 * pow(1000.0, Double(p) / Double(Self.points))
            let f1 = 20 * pow(1000.0, Double(p + 1) / Double(Self.points))
            let b0 = max(1, Int(f0 / binHz)), b1 = min(h - 1, max(b0, Int(f1 / binHz)))
            var peak: Float = 0
            for b in b0...b1 { peak = max(peak, mags[b]) }
            let tilt = Float(4.5 * log2(sqrt(f0 * f1) / 1000))
            let v = min(1, max(0, (10 * log10(max(peak * norm, 1e-12)) + tilt + 84) / 84))
            live[p] = v > live[p] ? v : live[p] * 0.82 + v * 0.18
            average[p] = average[p] * 0.96 + v * 0.04
        }
    }
}

// MARK: - SwiftUI wrapper

struct SpectrumView: NSViewRepresentable {
    @ObservedObject var analyzer: SpectrumAnalyzer
    let mode: VisualiserMode
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> VisualiserNSView {
        let v = VisualiserNSView()
        v.mode = mode
        v.onDoubleClick = onDoubleClick
        v.onClick = { [weak analyzer] in if analyzer?.mode == .loudness { analyzer?.resetIntegrated() } }
        analyzer.renderer = v
        v.setStatus(analyzer.status)
        return v
    }

    func updateNSView(_ view: VisualiserNSView, context: Context) {
        analyzer.renderer = view
        view.onDoubleClick = onDoubleClick
        if view.mode != mode { view.mode = mode }
        view.setStatus(analyzer.status)
    }
}

// MARK: - Screen

protocol VisRenderer: AnyObject {
    func install(in layer: CALayer, scale: CGFloat)
    func layout(in bounds: CGRect)
    func render(_ f: VisFrame, in bounds: CGRect)
}

/// The visualiser's dark screen. Hosts one style at a time; double-click cycles styles.
final class VisualiserNSView: NSView {
    var mode: VisualiserMode = .spectrum {
        didSet { if mode != oldValue || renderer == nil { installRenderer(); flashTitle() } }
    }
    var onDoubleClick: (() -> Void)?
    var onClick: (() -> Void)?
    private var renderer: VisRenderer?
    private let content = CALayer()
    private let message = CATextLayer()
    private let title = CATextLayer()
    private var scale: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.03, alpha: 1).cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.addSublayer(content)
        for t in [message, title] {
            t.foregroundColor = NSColor(white: 1, alpha: 0.6).cgColor
            t.contentsScale = scale
            layer?.addSublayer(t)
        }
        message.fontSize = 9
        message.font = NSFont.systemFont(ofSize: 9)
        message.alignmentMode = .center
        message.isWrapped = true
        message.isHidden = true
        title.fontSize = 8
        title.font = NSFont.systemFont(ofSize: 8, weight: .semibold)
        title.alignmentMode = .right
        title.opacity = 0
        installRenderer()
        toolTip = "Double-click to change the visualiser"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scale = window?.backingScaleFactor ?? 2
        [message, title].forEach { $0.contentsScale = scale }
        installRenderer()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else if event.clickCount == 1 { onClick?() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        message.frame = bounds.insetBy(dx: 10, dy: max(0, bounds.height / 2 - 14))
        title.frame = CGRect(x: bounds.width - 110, y: bounds.height - 13, width: 104, height: 11)
        renderer?.layout(in: bounds)
        CATransaction.commit()
    }

    private func installRenderer() {
        content.sublayers?.forEach { $0.removeFromSuperlayer() }
        let r: VisRenderer
        switch mode {
        case .spectrum: r = SpectrumLineRenderer()
        case .bars: r = BarsRenderer()
        case .spectrogram: r = SpectrogramRenderer()
        case .waveform: r = WaveformRenderer()
        case .oscilloscope: r = ScopeRenderer()
        case .stereometer: r = StereoRenderer()
        case .loudness: r = LoudnessRenderer()
        case .vu: r = VURenderer()
        }
        r.install(in: content, scale: scale)
        renderer = r
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        r.layout(in: bounds)
        CATransaction.commit()
    }

    private func flashTitle() {
        title.string = mode.title
        title.opacity = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            self?.title.opacity = 0
            CATransaction.commit()
        }
    }

    func setStatus(_ status: SpectrumAnalyzer.Status) {
        switch status {
        case .unsupported: showMessage("The visualiser needs macOS 14.2 or later.")
        case .failed(let why): showMessage("Couldn't start the visualiser (\(why)).")
        default: break
        }
    }

    private func showMessage(_ text: String?) {
        message.string = text
        message.isHidden = text == nil
    }

    func render(_ frame: VisFrame, hint: String?) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer?.render(frame, in: bounds)
        showMessage(hint)
        CATransaction.commit()
    }
}

// MARK: - Shared drawing helpers

private enum Vis {
    static let line = NSColor(calibratedRed: 0.80, green: 0.87, blue: 1.0, alpha: 0.95).cgColor
    static let dim = NSColor(white: 0.6, alpha: 0.55).cgColor
    static let grid = NSColor(white: 1, alpha: 0.11).cgColor
    static let label = NSColor(white: 1, alpha: 0.38).cgColor
    static let green = NSColor(Skin.green).cgColor
    static let amber = NSColor(Skin.amber).cgColor
    static let red = NSColor(Skin.red).cgColor

    static func shape(_ stroke: CGColor?, fill: CGColor? = nil, width: CGFloat = 1) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.strokeColor = stroke
        l.fillColor = fill
        l.lineWidth = width
        l.lineJoin = .round
        return l
    }

    static func text(_ s: String, size: CGFloat, scale: CGFloat, weight: NSFont.Weight = .medium,
                     color: CGColor = label, align: CATextLayerAlignmentMode = .left) -> CATextLayer {
        let t = CATextLayer()
        t.string = s
        t.fontSize = size
        t.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        t.foregroundColor = color
        t.alignmentMode = align
        t.contentsScale = scale
        return t
    }

    /// x of a frequency on the 20 Hz – 20 kHz log scale.
    static func x(_ f: Double, _ w: CGFloat) -> CGFloat { CGFloat(log10(f / 20) / 3) * w }

    static func frequencyGrid(_ w: CGFloat, _ h: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for decade in [10.0, 100, 1000, 10000] {
            for k in 1...9 {
                let f = decade * Double(k)
                guard f >= 20, f <= 20_000 else { continue }
                let px = x(f, w).rounded() + 0.5
                p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: h))
            }
        }
        return p
    }

    static func levelColor(_ t: Double) -> CGColor { t > 0.9 ? red : t > 0.75 ? amber : green }
}

// MARK: - Styles

/// Line spectrum: bright live curve, dim slow average.
final class SpectrumLineRenderer: VisRenderer {
    private let grid = Vis.shape(Vis.grid)
    private let avg = Vis.shape(Vis.dim, width: 1.2)
    private let live = Vis.shape(Vis.line, width: 1.4)
    private var labels: [CATextLayer] = []

    func install(in layer: CALayer, scale: CGFloat) {
        [grid, avg, live].forEach(layer.addSublayer)
        labels = ["100Hz", "1kHz", "10kHz"].map { Vis.text($0, size: 8, scale: scale) }
        labels.forEach(layer.addSublayer)
    }

    func layout(in b: CGRect) {
        [grid, avg, live].forEach { $0.frame = b }
        grid.path = Vis.frequencyGrid(b.width, b.height)
        for (t, f) in zip(labels, [100.0, 1000, 10000]) { t.frame = CGRect(x: Vis.x(f, b.width) + 2, y: b.height - 12, width: 40, height: 10) }
    }

    func render(_ f: VisFrame, in b: CGRect) {
        live.path = curve(f.live, b)
        avg.path = curve(f.average, b)
    }

    private func curve(_ v: [Float], _ b: CGRect) -> CGPath {
        let p = CGMutablePath()
        guard !v.isEmpty else { return p }
        for (i, x) in v.enumerated() {
            let pt = CGPoint(x: (CGFloat(i) + 0.5) / CGFloat(v.count) * b.width, y: 2 + CGFloat(x) * (b.height - 4))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// Frequency bars with falling peak caps.
final class BarsRenderer: VisRenderer {
    private let count = 30
    private var bars: [CALayer] = []
    private var caps: [CALayer] = []
    private var capValues: [Float] = []

    func install(in layer: CALayer, scale: CGFloat) {
        bars = (0..<count).map { _ in let l = CALayer(); l.cornerRadius = 1; layer.addSublayer(l); return l }
        caps = (0..<count).map { _ in let l = CALayer(); l.backgroundColor = NSColor(white: 1, alpha: 0.8).cgColor; layer.addSublayer(l); return l }
        capValues = Array(repeating: 0, count: count)
    }

    func layout(in b: CGRect) {}

    func render(_ f: VisFrame, in b: CGRect) {
        guard !f.live.isEmpty else { return }
        let gap: CGFloat = 2
        let w = (b.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let per = f.live.count / count
        for i in 0..<count {
            let v = f.live[(i * per)..<min(f.live.count, (i + 1) * per)].max() ?? 0
            capValues[i] = max(v, capValues[i] - 0.012)
            let h = CGFloat(v) * (b.height - 6)
            let x = CGFloat(i) * (w + gap)
            bars[i].frame = CGRect(x: x, y: 2, width: w, height: max(1, h))
            bars[i].backgroundColor = Vis.levelColor(Double(v))
            caps[i].frame = CGRect(x: x, y: 2 + CGFloat(capValues[i]) * (b.height - 6) + 1, width: w, height: 1.5)
        }
    }
}

/// Scrolling spectrogram: frequency (bottom = bass) against time, as a heat map.
final class SpectrogramRenderer: VisRenderer {
    private let image = CALayer()
    private var width = 0, height = 0
    private var pixels: [UInt32] = []
    private let space = CGColorSpaceCreateDeviceRGB()

    func install(in layer: CALayer, scale: CGFloat) {
        image.magnificationFilter = .nearest
        layer.addSublayer(image)
    }

    func layout(in b: CGRect) {
        image.frame = b
        width = max(1, Int(b.width))
        height = max(1, Int(b.height))
        pixels = Array(repeating: 0xFF000000, count: width * height)
    }

    /// Black → blue → magenta → orange → yellow.
    private func color(_ t: Float) -> UInt32 {
        let stops: [(Float, Float, Float)] = [(0, 0, 0), (0.1, 0.1, 0.5), (0.6, 0.1, 0.6), (1, 0.5, 0.1), (1, 0.95, 0.5)]
        let x = min(0.9999, max(0, t)) * Float(stops.count - 1)
        let i = Int(x), k = x - Float(i)
        let a = stops[i], c = stops[i + 1]
        let r = UInt32((a.0 + (c.0 - a.0) * k) * 255), g = UInt32((a.1 + (c.1 - a.1) * k) * 255), bl = UInt32((a.2 + (c.2 - a.2) * k) * 255)
        return 0xFF000000 | (bl << 16) | (g << 8) | r
    }

    func render(_ f: VisFrame, in b: CGRect) {
        guard !f.live.isEmpty, width > 1, pixels.count == width * height else { return }
        // Scroll left by one column, then paint the newest column on the right.
        pixels.withUnsafeMutableBufferPointer { px in
            for row in 0..<height {
                let base = px.baseAddress! + row * width
                memmove(base, base + 1, (width - 1) * MemoryLayout<UInt32>.size)
                let t = 1 - Float(row) / Float(height - 1)       // row 0 = top = treble
                let v = f.live[min(f.live.count - 1, Int(t * Float(f.live.count - 1)))]
                base[width - 1] = color(v * v * 1.15)
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        guard let provider = CGDataProvider(data: data),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        image.contents = img
    }
}

/// Scrolling waveform (level history), mirrored around the centre line.
final class WaveformRenderer: VisRenderer {
    private let wave = Vis.shape(nil, fill: Vis.line)
    private let mid = Vis.shape(Vis.grid)
    private var history: [Float] = []

    func install(in layer: CALayer, scale: CGFloat) {
        wave.opacity = 0.85
        [mid, wave].forEach(layer.addSublayer)
    }

    func layout(in b: CGRect) {
        [mid, wave].forEach { $0.frame = b }
        let p = CGMutablePath(); p.move(to: CGPoint(x: 0, y: b.midY)); p.addLine(to: CGPoint(x: b.width, y: b.midY))
        mid.path = p
        history = Array(repeating: 0, count: max(2, Int(b.width / 2)))
    }

    func render(_ f: VisFrame, in b: CGRect) {
        guard history.count > 1 else { return }
        history.removeFirst()
        history.append(min(1, sqrt(f.blockPeak)))         // sqrt: quieter detail stays visible
        let step = b.width / CGFloat(history.count - 1)
        let half = b.height / 2 - 2
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: b.midY))
        for (i, v) in history.enumerated() { p.addLine(to: CGPoint(x: CGFloat(i) * step, y: b.midY + CGFloat(v) * half)) }
        for (i, v) in history.enumerated().reversed() { p.addLine(to: CGPoint(x: CGFloat(i) * step, y: b.midY - CGFloat(v) * half)) }
        p.closeSubpath()
        wave.path = p
    }
}

/// Oscilloscope, locked to a rising zero-crossing so the picture holds still.
final class ScopeRenderer: VisRenderer {
    private let trace = Vis.shape(Vis.line, width: 1.3)
    private let mid = Vis.shape(Vis.grid)

    func install(in layer: CALayer, scale: CGFloat) { [mid, trace].forEach(layer.addSublayer) }

    func layout(in b: CGRect) {
        [mid, trace].forEach { $0.frame = b }
        let p = CGMutablePath(); p.move(to: CGPoint(x: 0, y: b.midY)); p.addLine(to: CGPoint(x: b.width, y: b.midY))
        mid.path = p
    }

    func render(_ f: VisFrame, in b: CGRect) {
        let count = min(f.left.count, f.right.count)
        guard count > 1024 else { trace.path = nil; return }
        let mono = (0..<count).map { (f.left[$0] + f.right[$0]) * 0.5 }
        let span = 768
        var start = count - span - 1
        var i = count - span - 1
        while i > 1 {                                   // latest rising zero-crossing with room after it
            if mono[i - 1] < 0 && mono[i] >= 0 { start = i; break }
            i -= 1
        }
        let peak = max(0.05, mono[start..<(start + span)].map { abs($0) }.max() ?? 0.05)
        let gain = (b.height / 2 - 3) / CGFloat(peak)
        let p = CGMutablePath()
        for k in 0..<span {
            let pt = CGPoint(x: CGFloat(k) / CGFloat(span - 1) * b.width, y: b.midY + CGFloat(mono[start + k]) * gain)
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        trace.path = p
    }
}

/// Stereometer: rotated L/R dot cloud (mono = vertical line) plus a correlation meter.
final class StereoRenderer: VisRenderer {
    private let guides = Vis.shape(Vis.grid)
    private let dots = Vis.shape(nil, fill: Vis.line)
    private let track = CALayer(), marker = CALayer()
    private var value: CATextLayer!, scaleLabel: CATextLayer!
    private var shown: Float = 0

    func install(in layer: CALayer, scale: CGFloat) {
        dots.opacity = 0.7
        track.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        track.cornerRadius = 2
        marker.cornerRadius = 1.5
        value = Vis.text("+0.00", size: 11, scale: scale, weight: .semibold, color: NSColor(white: 1, alpha: 0.85).cgColor, align: .center)
        scaleLabel = Vis.text("−1        0        +1", size: 7, scale: scale, align: .center)
        for l: CALayer in [guides, dots, track, marker, value!, scaleLabel!] { layer.addSublayer(l) }
    }

    private func square(_ b: CGRect) -> CGRect { CGRect(x: 4, y: 2, width: b.height - 4, height: b.height - 4) }

    func layout(in b: CGRect) {
        let sq = square(b)
        guides.frame = b; dots.frame = b
        let p = CGMutablePath()
        p.addEllipse(in: sq)
        p.move(to: CGPoint(x: sq.midX, y: sq.minY)); p.addLine(to: CGPoint(x: sq.midX, y: sq.maxY))          // mono (M)
        p.move(to: CGPoint(x: sq.minX + sq.width * 0.15, y: sq.minY + sq.height * 0.15))
        p.addLine(to: CGPoint(x: sq.maxX - sq.width * 0.15, y: sq.maxY - sq.height * 0.15))                   // R
        p.move(to: CGPoint(x: sq.minX + sq.width * 0.15, y: sq.maxY - sq.height * 0.15))
        p.addLine(to: CGPoint(x: sq.maxX - sq.width * 0.15, y: sq.minY + sq.height * 0.15))                   // L
        guides.path = p
        let right = CGRect(x: sq.maxX + 12, y: 0, width: b.width - sq.maxX - 18, height: b.height)
        value.frame = CGRect(x: right.minX, y: b.height / 2 + 4, width: right.width, height: 14)
        track.frame = CGRect(x: right.minX, y: b.height / 2 - 4, width: right.width, height: 4)
        scaleLabel.frame = CGRect(x: right.minX, y: b.height / 2 - 16, width: right.width, height: 9)
    }

    func render(_ f: VisFrame, in b: CGRect) {
        let sq = square(b)
        let count = min(f.left.count, f.right.count)
        let p = CGMutablePath()
        if count > 0 {
            var peak: Float = 0.05
            for i in stride(from: 0, to: count, by: 2) { peak = max(peak, abs(f.left[i]), abs(f.right[i])) }
            let k = CGFloat(0.5 / peak) * sq.width / 2 * 0.95
            for i in stride(from: 0, to: count, by: 2) {
                let side = CGFloat(f.right[i] - f.left[i]) * k, midv = CGFloat(f.left[i] + f.right[i]) * k
                p.addRect(CGRect(x: sq.midX + side - 0.5, y: sq.midY + midv - 0.5, width: 1, height: 1))
            }
        }
        dots.path = p
        shown += (f.correlation - shown) * 0.25
        value.string = String(format: "%+.2f", shown)
        let t = track.frame
        let x = t.minX + CGFloat((shown + 1) / 2) * t.width
        marker.frame = CGRect(x: x - 1.5, y: t.minY - 3, width: 3, height: t.height + 6)
        marker.backgroundColor = shown < 0 ? Vis.red : shown < 0.3 ? Vis.amber : Vis.green
    }
}

/// Loudness (BS.1770-4): true peak, momentary, short-term and integrated, as numbers and bars.
/// Click to reset the integrated value.
final class LoudnessRenderer: VisRenderer {
    private var names: [CATextLayer] = [], values: [CATextLayer] = []
    private var tracks: [CALayer] = [], fills: [CALayer] = []
    private let rows = [("TRUE PEAK", "dBTP"), ("MOMENTARY", "LUFS"), ("SHORT-TERM", "LUFS"), ("INTEGRATED", "LUFS")]

    func install(in layer: CALayer, scale: CGFloat) {
        for (n, _) in rows {
            let name = Vis.text(n, size: 7, scale: scale, weight: .semibold)
            let value = Vis.text("−∞", size: 9, scale: scale, weight: .semibold, color: NSColor(white: 1, alpha: 0.88).cgColor, align: .right)
            let track = CALayer(); track.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor; track.cornerRadius = 1
            let fill = CALayer(); fill.cornerRadius = 1
            for l: CALayer in [name, value, track, fill] { layer.addSublayer(l) }
            names.append(name); values.append(value); tracks.append(track); fills.append(fill)
        }
    }

    func layout(in b: CGRect) {
        let rowH = (b.height - 4) / CGFloat(rows.count)
        for i in 0..<rows.count {
            let mid = b.height - 2 - rowH * (CGFloat(i) + 0.5)
            names[i].frame = CGRect(x: 7, y: mid - 5, width: 62, height: 10)
            values[i].frame = CGRect(x: b.width - 76, y: mid - 6, width: 70, height: 12)
            tracks[i].frame = CGRect(x: 70, y: mid - 1, width: b.width - 70 - 82, height: 2.5)
        }
    }

    func render(_ f: VisFrame, in b: CGRect) {
        let readings = [f.truePeakDB, f.momentary, f.shortTerm, f.integrated]
        for i in 0..<rows.count {
            let v = readings[i]
            values[i].string = v <= -70 ? "−∞ \(rows[i].1)" : String(format: "%.1f %@", v, rows[i].1)
            let t = min(1, max(0, (v + 60) / 60))
            let track = tracks[i].frame
            fills[i].frame = CGRect(x: track.minX, y: track.minY, width: track.width * CGFloat(t), height: track.height)
            // True peak turns red at −1 dBTP (a common ceiling); loudness bars stay neutral.
            fills[i].backgroundColor = i == 0 ? (v > -1 ? Vis.red : v > -6 ? Vis.amber : Vis.green) : Vis.line
        }
    }
}

/// Classic needle VU meter: −20 to +3 VU, 0 VU = −18 dBFS, with a red zone above 0.
final class VURenderer: VisRenderer {
    private let scaleArc = Vis.shape(NSColor(white: 1, alpha: 0.45).cgColor, width: 1.2)
    private let redArc = Vis.shape(Vis.red, width: 2)
    private let needle = CALayer()
    private var labels: [CATextLayer] = []
    private var vuLabel: CATextLayer!
    private var shown = -20.0
    private let marks: [Double] = [-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3]

    func install(in layer: CALayer, scale: CGFloat) {
        needle.backgroundColor = NSColor(calibratedRed: 1, green: 0.55, blue: 0.3, alpha: 1).cgColor
        needle.anchorPoint = CGPoint(x: 0.5, y: 0)
        labels = ["-20", "-10", "-5", "0", "+3"].map { Vis.text($0, size: 7, scale: scale, align: .center) }
        vuLabel = Vis.text("VU", size: 9, scale: scale, weight: .semibold, align: .center)
        layer.addSublayer(scaleArc)
        layer.addSublayer(redArc)
        labels.forEach { layer.addSublayer($0) }
        layer.addSublayer(vuLabel)
        layer.addSublayer(needle)
    }

    /// VU value → angle in degrees from vertical (−50 … +50).
    private func angle(_ vu: Double) -> Double {
        let t = (pow(10, vu / 20) - pow(10, -20 / 20.0)) / (pow(10, 3 / 20.0) - pow(10, -20 / 20.0))   // VU scales are linear in voltage
        return -50 + 100 * t
    }

    private var pivot = CGPoint.zero, radius: CGFloat = 0

    func layout(in b: CGRect) {
        [scaleArc, redArc].forEach { $0.frame = b }
        pivot = CGPoint(x: b.midX, y: -b.height * 0.55)
        radius = b.height * 1.35
        func pt(_ deg: Double, _ r: CGFloat) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: pivot.x + r * CGFloat(sin(a)), y: pivot.y + r * CGFloat(cos(a)))
        }
        let arc = CGMutablePath(), red = CGMutablePath()
        for (i, m) in marks.enumerated() {
            let a = angle(m)
            arc.move(to: pt(a, radius - 5)); arc.addLine(to: pt(a, radius + (m == 0 ? 2 : 0)))
            if i == 0 { arc.move(to: pt(a, radius)) }
        }
        for s in stride(from: -50.0, through: 50, by: 2) {
            if s == -50 { arc.move(to: pt(s, radius)) } else { arc.addLine(to: pt(s, radius)) }
        }
        for s in stride(from: angle(0), through: 50, by: 2) {
            if s == angle(0) { red.move(to: pt(s, radius + 1.5)) } else { red.addLine(to: pt(s, radius + 1.5)) }
        }
        scaleArc.path = arc
        redArc.path = red
        for (t, m) in zip(labels, [-20.0, -10, -5, 0, 3]) {
            let p = pt(angle(m), radius + 8)
            t.frame = CGRect(x: p.x - 12, y: min(b.height - 10, p.y - 4), width: 24, height: 9)
        }
        vuLabel.frame = CGRect(x: b.midX - 15, y: 4, width: 30, height: 11)
        needle.bounds = CGRect(x: 0, y: 0, width: 1.5, height: radius + 2)
        needle.position = pivot
    }

    func render(_ f: VisFrame, in b: CGRect) {
        shown += (f.vu - shown) * 0.3                                  // needle inertia
        needle.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(-angle(shown) * .pi / 180)))
    }
}
