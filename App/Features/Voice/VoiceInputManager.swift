import Foundation
@preconcurrency import AVFoundation
import Accelerate
import Speech
import SwiftWhisper
import OpenWebUIKit
#if os(iOS)
import UIKit
#endif

/// Records the mic and transcribes to text using the engine chosen in Settings:
/// **native** (`SFSpeechRecognizer`) or **model** (a downloaded Whisper GGUF via
/// whisper.cpp).
///
/// Audio strategy: the tap copies *raw* mono samples at the hardware rate during
/// recording, then we resample the WHOLE recording to 16 kHz in a single pass at
/// stop. (Per-buffer resampling fragmented the converter's state and produced
/// garbage audio → Whisper guessed random languages and returned nothing.)
@MainActor
final class VoiceInputManager: ObservableObject {
    @Published var isRecording = false
    @Published var processing = false
    @Published var partialText = ""
    @Published var error: String?
    /// Live mic loudness (RMS, ~0…1) — drives energy-based endpointing for engines
    /// that have no live transcript (server / Whisper).
    @Published var level: Float = 0
    /// Live FFT magnitude bands (0…1, log-spaced) — drives the spectrum visualizer.
    @Published var spectrum: [Float] = Array(repeating: 0, count: VoiceInputManager.bandCount)

    // MARK: - FFT (Accelerate)
    // Immutable read-only setup shared with the nonisolated audio-thread FFT, so
    // it's marked nonisolated (the class is @MainActor).
    nonisolated static let bandCount = 28
    nonisolated private static let fftLog2: vDSP_Length = 10       // 1024-point FFT
    nonisolated(unsafe) private static let fftSetup: FFTSetup = vDSP_create_fftsetup(fftLog2, FFTRadix(kFFTRadix2))!
    nonisolated private static let hann: [Float] = {
        var w = [Float](repeating: 0, count: 1 << Int(fftLog2))
        vDSP_hann_window(&w, vDSP_Length(w.count), Int32(vDSP_HANN_NORM))
        return w
    }()

    // A FRESH engine is created for every recording — reusing one instance across
    // start/stop is unstable on macOS (the 2nd use hung the audio HAL on the main
    // thread and then crashed). A new engine means a clean input node + tap.
    private var engine = AVAudioEngine()
    /// Recognizer for the app's current language (was hardcoded to pt-BR, which
    /// transcribed everything else as garbage). Falls back to the device default.
    private var recognizer: SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: LanguageManager.shared.locale) ?? SFSpeechRecognizer()
    }

    private static let targetRate: Double = 16_000
    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: targetRate, channels: 1, interleaved: false)!

    // Shared with the audio thread, guarded by `lock`.
    nonisolated(unsafe) private var rawSamples: [Float] = []
    nonisolated(unsafe) private var hwRate: Double = 48_000
    nonisolated(unsafe) private var captureToModel = false
    nonisolated(unsafe) private var request: SFSpeechAudioBufferRecognitionRequest?
    nonisolated(unsafe) private var sawFinal = false
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?

    // Keep the loaded Whisper model in memory so repeated transcriptions don't
    // reload it from disk each time.
    private var cachedWhisper: Whisper?
    private var cachedModelID = ""

    /// Forces a specific STT engine for this instance, overriding the Settings
    /// choice. The live voice conversation sets this to "native" because only the
    /// on-device recognizer streams partial transcripts (live text) and supports
    /// hands-free silence endpointing; server/Whisper are record-then-transcribe.
    var engineOverride: String?
    private var sttEngine: String { engineOverride ?? UserDefaults.standard.string(forKey: "voice.stt.engine") ?? "native" }
    private var useModel: Bool { sttEngine == "model" }
    private var useServer: Bool { sttEngine == "server" }
    private var activeModelID: String { UserDefaults.standard.string(forKey: "voice.stt.model") ?? "" }

    /// Injected at startup — required for the "server" STT engine.
    var client: OpenWebUIClient?

    /// While true the mic tap discards audio (session stays alive) — drives mute.
    var muted = false

    init() {
        #if os(iOS)
        // Free the loaded Whisper model (100s of MB–1 GB+) under memory pressure.
        // It reloads from disk on the next on-device transcription.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.releaseModel() } }
        #endif
    }

    /// Drop the resident Whisper model. Safe to call anytime — the next
    /// transcription reloads it (see `transcribeWithWhisper`).
    func releaseModel() {
        guard !isRecording, !processing else { return }
        cachedWhisper = nil
        cachedModelID = ""
    }

    // MARK: - Start

    func start() async -> Bool {
        #if targetEnvironment(simulator)
        error = L("Microfone só funciona no iPhone (não no simulador).")
        return false
        #else
        // Re-entrancy guard: never start a second recording while one is active or
        // a transcription is still running (this was the 2nd-tap freeze/crash).
        guard !isRecording, !processing else { return false }
        error = nil; partialText = ""; sawFinal = false
        lock.withLock { rawSamples = [] }

        if useModel && installedModelURL() == nil {
            error = L("Nenhum modelo Whisper baixado/selecionado. Baixe um em Ajustes › Voz e modelos (ou use o motor Nativo).")
            return false
        }
        guard await requestPermissions() else {
            error = L("Permissão de microfone/voz negada (Ajustes do iPhone).")
            return false
        }
        // State may have changed while awaiting permission.
        guard !isRecording, !processing else { return false }
        // Tear down any leftover engine/tap and build a brand-new engine.
        tearDownEngine()
        engine = AVAudioEngine()

        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            self.error = L("Áudio indisponível: %@", error.localizedDescription)
            return false
        }
        #endif

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            deactivateSession()
            self.error = L("Microfone indisponível.")
            return false
        }
        hwRate = inputFormat.sampleRate
        captureToModel = useModel || useServer   // both buffer raw audio to upload/transcribe

        if !useModel && !useServer {
            guard let rec = recognizer, rec.isAvailable else {
                deactivateSession()
                error = L("Reconhecimento de voz indisponível para pt-BR neste aparelho.")
                return false
            }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
            req.addsPunctuation = true   // "?" at the end of a spoken question, commas, etc.
            request = req
            task = rec.recognitionTask(with: req) { [weak self] result, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        // Never overwrite a good transcript with an empty one — on an
                        // abrupt stop SFSpeechRecognizer often delivers an EMPTY final
                        // result, which used to wipe the live text → "didn't catch
                        // any speech" even though we clearly heard the user.
                        let s = result.bestTranscription.formattedString
                        if !s.isEmpty { self.partialText = s }
                        if result.isFinal { self.sawFinal = true }
                    }
                    if let err { self.error = L("Reconhecimento: %@", err.localizedDescription); self.sawFinal = true }
                }
            }
        }

        // Smaller buffer → the level/FFT update ~4× more often (smoother visualizer,
        // snappier endpointing). Still ≥ the 1024-sample FFT window.
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Muted: report silence and don't feed the recognizer, but keep the
            // engine running so the session stays alive (tap again to unmute).
            if self.muted {
                Task { @MainActor in self.level = 0; self.spectrum = Array(repeating: 0, count: Self.bandCount) }
                return
            }
            // Raw RMS of float PCM speech is tiny (~0.02–0.08), and `.measurement`
            // mode disables input gain — far below what the orb needs to visibly
            // react or what energy-endpointing can threshold. Boost to a usable
            // 0…1 range (perceptual: emphasise the quiet end so a normal voice
            // clearly registers).
            let lvl = min(1, Self.rms(buffer).squareRoot() * 1.6)
            let bands = Self.computeSpectrum(buffer)
            Task { @MainActor in self.level = lvl; if !bands.isEmpty { self.spectrum = bands } }
            if self.captureToModel { self.captureRaw(buffer) }
            else { self.request?.append(buffer) }
        }

        do {
            engine.prepare()
            try engine.start()
            isRecording = true
            return true
        } catch {
            input.removeTap(onBus: 0)
            deactivateSession()
            self.error = error.localizedDescription
            return false
        }
        #endif
    }

    // MARK: - Stop

    func stop() async -> String {
        guard isRecording else { return "" }
        isRecording = false
        tearDownEngine()       // stop the engine + tap first (no appends after endAudio)
        request?.endAudio()    // then let the recognizer finalize the buffered audio

        // Server/Whisper transcribe the captured raw samples — the session can go now.
        if useServer { deactivateSession(); return await transcribeWithServer() }
        if useModel { deactivateSession(); return await transcribeWithWhisper() }

        // Native: wait for the final result BEFORE deactivating the session, so the
        // recognizer can emit its last transcript.
        for _ in 0..<30 { if sawFinal { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        task?.cancel(); task = nil; request = nil
        deactivateSession()
        let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && error == nil { error = L("Não captei nenhuma fala.") }
        return text
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        tearDownEngine()
        task?.cancel(); task = nil; request = nil
        deactivateSession()
    }

    /// Stops the engine and removes its tap, tolerating a not-running engine.
    /// Removing the tap before deallocating the engine avoids dangling callbacks.
    private func tearDownEngine() {
        let e = engine
        e.inputNode.removeTap(onBus: 0)
        if e.isRunning { e.stop() }
        level = 0
    }

    /// Deactivates the audio session (iOS only — macOS has no AVAudioSession).
    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - Whisper

    private func transcribeWithWhisper() async -> String {
        guard let url = installedModelURL() else { error = L("Nenhum modelo Whisper selecionado."); return "" }
        let raw = lock.withLock { rawSamples }
        guard raw.count > Int(hwRate * 0.3) else {   // < ~0.3 s
            error = L("Áudio muito curto — toque, fale e toque de novo pra parar.")
            return ""
        }
        processing = true; defer { processing = false }

        var frames = resampleTo16k(raw, from: hwRate)
        normalize(&frames)

        // Fixed language beats "auto" (auto guesses romanian on imperfect audio).
        // Language-tuned models pin their own language; universal models follow
        // the app UI language.
        let lang: WhisperLanguage
        switch VoiceCatalog.all.first(where: { $0.id == activeModelID })?.lang {
        case .english:    lang = .english
        case .chinese:    lang = .chinese
        case .japanese:   lang = .japanese
        case .french:     lang = .french
        case .portuguese: lang = .portuguese
        default:          lang = Self.appWhisperLanguage()
        }

        do {
            let whisper: Whisper
            if let cached = cachedWhisper, cachedModelID == activeModelID {
                whisper = cached                       // reuse — skips the disk reload
            } else {
                whisper = Whisper(fromFileURL: url)
                cachedWhisper = whisper
                cachedModelID = activeModelID
            }
            whisper.params.language = lang
            let segments = try await whisper.transcribe(audioFrames: frames)
            let text = segments.map(\.text).joined()
                .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                .replacingOccurrences(of: "[ Silence ]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { error = L("Não captei nenhuma fala.") }
            return text
        } catch {
            self.error = L("Falha na transcrição: %@", error.localizedDescription)
            return ""
        }
    }

    // MARK: - Server STT

    private func transcribeWithServer() async -> String {
        guard let client else { error = L("Servidor de voz indisponível."); return "" }
        let raw = lock.withLock { rawSamples }
        guard raw.count > Int(hwRate * 0.3) else {
            error = L("Áudio muito curto — toque, fale e toque de novo pra parar.")
            return ""
        }
        processing = true; defer { processing = false }
        var frames = resampleTo16k(raw, from: hwRate)
        normalize(&frames)
        let wav = Self.wavData(frames, sampleRate: 16_000)
        do {
            let text = try await client.transcribe(audio: wav, filename: "speech.wav", mime: "audio/wav")
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { error = L("Não captei nenhuma fala.") }
            return t
        } catch {
            self.error = L("Transcrição (servidor): %@", error.localizedDescription)
            return ""
        }
    }

    /// Wraps 16-bit PCM mono samples in a minimal WAV container for upload.
    private static func wavData(_ frames: [Float], sampleRate: Int) -> Data {
        let channels = 1, bits = 16
        let blockAlign = channels * bits / 8
        let byteRate = sampleRate * blockAlign
        let dataSize = frames.count * blockAlign
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data()
        d.append(Data("RIFF".utf8)); d.append(u32(UInt32(36 + dataSize))); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); d.append(u32(16)); d.append(u16(1)); d.append(u16(UInt16(channels)))
        d.append(u32(UInt32(sampleRate))); d.append(u32(UInt32(byteRate)))
        d.append(u16(UInt16(blockAlign))); d.append(u16(UInt16(bits)))
        d.append(Data("data".utf8)); d.append(u32(UInt32(dataSize)))
        for f in frames {
            let s = Int16(max(-1, min(1, f)) * 32767)
            d.append(u16(UInt16(bitPattern: s)))
        }
        return d
    }

    /// Maps the app's UI language to a Whisper language for the universal
    /// models. Unknown/unsupported → .auto.
    private static func appWhisperLanguage() -> WhisperLanguage {
        switch LanguageManager.shared.current {
        case .ptBR:           return .portuguese
        case .en:             return .english
        case .es:             return .spanish
        case .fr:             return .french
        case .it:             return .italian
        case .de, .deAT, .deCH: return .german
        case .nl:             return .dutch
        case .pl:             return .polish
        case .cs:             return .czech
        case .sk:             return .slovak
        case .sl:             return .slovenian
        case .hr:             return .croatian
        case .bg:             return .bulgarian
        case .mk:             return .macedonian
        case .sr:             return .serbian
        case .uk:             return .ukrainian
        case .be:             return .belarusian
        case .ru:             return .russian
        case .tr:             return .turkish
        case .hu:             return .hungarian
        case .vi:             return .vietnamese
        case .ind:            return .indonesian
        case .ms:             return .malay
        case .ja:             return .japanese
        case .ko:             return .korean
        case .zhHans, .zhHant: return .chinese
        case .hi:             return .hindi
        case .bn:             return .bengali
        case .ar:             return .arabic
        case .fa:             return .persian
        case .ur:             return .urdu
        case .ps:             return .pashto
        case .lb:             return .luxembourgish
        case .lv:             return .latvian
        case .fi:             return .finnish
        case .sv:             return .swedish
        case .he:             return .hebrew
        case .th:             return .thai
        case .bo:             return .tibetan
        case .mn:             return .mongolian
        case .ug:             return .auto   // Whisper has no Uyghur model
        }
    }

    private func installedModelURL() -> URL? {
        guard let model = VoiceCatalog.all.first(where: { $0.id == activeModelID }) else { return nil }
        let url = ModelDownloadManager.shared.localURL(model)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Audio plumbing

    /// Mean RMS loudness of the first channel (cheap, runs inside the tap).
    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength); guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        return (sum / Float(n)).squareRoot()
    }

    /// Windowed FFT → `bandCount` log-spaced magnitude bands in 0…1, dB-scaled with
    /// a high-sensitivity floor so a normal voice fills the bars. Runs on the audio
    /// thread (nonisolated, pure aside from the immutable static FFT setup).
    nonisolated static func computeSpectrum(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let n = 1 << Int(fftLog2)
        guard let ch = buffer.floatChannelData?[0], Int(buffer.frameLength) >= n else { return [] }
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(ch, 1, hann, 1, &windowed, 1, vDSP_Length(n))

        let half = n / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        windowed.withUnsafeBufferPointer { wp in
            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        vDSP_fft_zrip(fftSetup, &split, 1, fftLog2, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                    }
                }
            }
        }

        // Log-spaced bands over bins [1, half); dB-scale each with a generous floor.
        var out = [Float](repeating: 0, count: bandCount)
        let minBin = 1.0, maxBin = Double(half)
        for b in 0..<bandCount {
            let lo = Int(minBin * pow(maxBin / minBin, Double(b) / Double(bandCount)))
            let hi = max(lo + 1, Int(minBin * pow(maxBin / minBin, Double(b + 1) / Double(bandCount))))
            var peak: Float = 0
            for i in lo..<min(hi, half) { peak = max(peak, mags[i]) }
            let db = 10 * log10f(peak + 1e-9)          // power → dB
            out[b] = min(1, max(0, (db + 80) / 80))    // -80 dB floor → high sensitivity
        }
        return out
    }

    /// Copies raw mono samples (hardware rate) — fast + safe inside the tap.
    nonisolated private func captureRaw(_ buffer: AVAudioPCMBuffer) {
        guard let chans = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let chCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        if chCount == 1 {
            _ = mono.withUnsafeMutableBufferPointer { memcpy($0.baseAddress!, chans[0], n * MemoryLayout<Float>.size) }
        } else {
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<chCount { s += chans[c][i] }
                mono[i] = s / Float(chCount)
            }
        }
        lock.withLock { rawSamples.append(contentsOf: mono) }
    }

    /// One-pass resample of the whole recording → 16 kHz mono (continuous, so no
    /// fragmentation artifacts).
    private func resampleTo16k(_ samples: [Float], from rate: Double) -> [Float] {
        guard rate != Self.targetRate else { return samples }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFormat, to: Self.targetFormat),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return samples
        }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        _ = samples.withUnsafeBufferPointer { memcpy(inBuf.floatChannelData![0], $0.baseAddress!, samples.count * MemoryLayout<Float>.size) }

        let outCap = AVAudioFrameCount(Double(samples.count) * Self.targetRate / rate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: outCap) else { return samples }
        var done = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true; status.pointee = .haveData; return inBuf
        }
        guard let ch = outBuf.floatChannelData?[0] else { return samples }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
    }

    /// Peak-normalizes quiet recordings so Whisper has enough signal.
    private func normalize(_ x: inout [Float]) {
        var peak: Float = 0
        for v in x { peak = max(peak, abs(v)) }
        guard peak > 0.0001, peak < 0.97 else { return }
        let gain = 0.97 / peak
        for i in x.indices { x[i] *= gain }
    }

    private func requestPermissions() async -> Bool {
        let mic = await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        guard mic else { return false }
        if useModel || useServer { return true }   // no SFSpeech auth needed
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        return speech
    }
}
