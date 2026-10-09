import FluidAudio
import Foundation

actor LocalTranscriber {
    let modelsRoot: URL
    /// Where the voice activity model lives (downloaded there once, ~2 MB), or nil to skip it.
    let vadRoot: URL?
    private var manager: AsrManager?
    private var vad: VadManager?
    private(set) var modelLoadCount = 0

    init(modelsRoot: URL, vadRoot: URL? = nil) {
        self.modelsRoot = modelsRoot
        self.vadRoot = vadRoot
    }

    /// Speech shorter than this is a cough or a click, not words.
    static let minimumSpeech: TimeInterval = 0.2
    /// Kept around the detected speech, so first and last syllables are never clipped.
    static let speechPadding: TimeInterval = 0.3

    nonisolated var modelsAreInstalled: Bool {
        let ready = modelsRoot.appendingPathComponent("ready.json")
        let asr = modelsRoot.appendingPathComponent(AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent)
        return FileManager.default.fileExists(atPath: ready.path) && AsrModels.modelsExist(at: asr, version: .v3, encoderPrecision: .int8)
    }

    /// Downloads NVIDIA Parakeet TDT 0.6b v3 (Core ML, ~500 MB) from Hugging Face into
    /// `modelsRoot`, then marks it ready.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !modelsAreInstalled else { return }
        ModelHub.offlineMode = false
        defer { ModelHub.offlineMode = true }
        let directory = modelsRoot.appendingPathComponent(AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent)
        _ = try await AsrModels.download(to: directory, version: .v3, encoderPrecision: .int8) { update in
            progress(update.fractionCompleted)
        }
        try Data(#"{"model":"parakeet-tdt-0.6b-v3"}"#.utf8)
            .write(to: modelsRoot.appendingPathComponent("ready.json"), options: .atomic)
    }

    func prepare() async throws {
        try Task.checkCancellation()
        if manager != nil { return }
        guard modelsAreInstalled else {
            throw DictationError.message("The speech model is not installed yet.")
        }
        ModelHub.offlineMode = true
        let directory = modelsRoot.appendingPathComponent(AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent)
        let models = try await AsrModels.downloadAndLoad(to: directory, version: .v3, encoderPrecision: .int8)
        try Task.checkCancellation()
        let value = AsrManager(config: ASRConfig(melChunkContext: false, dualDecodeArbitration: true))
        try await value.loadModels(models)
        try Task.checkCancellation()
        manager = value; modelLoadCount += 1
        await loadVad()
    }

    /// Optional: without it, every recording goes to the speech model as is.
    private func loadVad() async {
        guard vad == nil, let vadRoot else { return }
        ModelHub.offlineMode = false
        defer { ModelHub.offlineMode = true }
        vad = try? await VadManager(config: VadConfig(defaultThreshold: 0.5), modelDirectory: vadRoot)
    }

    func transcribe(_ audio: URL) async throws -> String {
        try await prepare()
        try Task.checkCancellation()
        guard let manager else { throw DictationError.message("The local speech model did not load.") }
        var samples = try AudioConverter().resampleAudioFile(audio)
        // Parakeet hears words ("Yeah", "Thank you") in clips that hold only noise. The voice
        // activity model decides whether anyone spoke, and the silence around the words is cut.
        if let vad {
            let segments = try await vad.segmentSpeech(samples)
            guard let range = Self.speechRange(segments, sampleCount: samples.count) else { throw Self.noSpeech }
            samples = Array(samples[range])
        }
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: VadManager.sampleRate)
        if samples.count < minimum { samples += [Float](repeating: 0, count: minimum - samples.count) }
        try Task.checkCancellation()
        var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoder)
        try Task.checkCancellation()
        let text = Self.clean(result.text)
        guard !text.isEmpty else { throw Self.noSpeech }
        return text
    }

    private static let noSpeech = DictationError.message(
        "No speech was detected. Check the selected microphone and try again.")

    /// The samples from the first word to the last, padded; nil when there is too little speech.
    static func speechRange(_ segments: [VadSegment], sampleCount: Int) -> Range<Int>? {
        let rate = VadManager.sampleRate
        guard let first = segments.first, let last = segments.last,
              segments.reduce(0, { $0 + $1.duration }) >= minimumSpeech else { return nil }
        let padding = Int(speechPadding * Double(rate))
        let start = max(0, first.startSample(sampleRate: rate) - padding)
        let end = min(sampleCount, last.endSample(sampleRate: rate) + padding)
        return start < end ? start..<end : nil
    }

    static func clean(_ text: String) -> String { DictationText.clean(text) }
}
