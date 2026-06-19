import Foundation
import FluidAudio
import OpenWhispererKit

/// In-process speech-to-text via FluidAudio's CoreML ASR models, on the ANE. Backs the
/// `.parakeetV3` (batch) and `.nemotronMultilingual` (streaming, fed a finite clip) STT
/// engines. Actor-isolated so model load + transcribe serialize on the compute unit.
/// Offline-first by construction: FluidAudio reuses its `~/.cache/fluidaudio` cache when
/// present, so an already-downloaded model survives a blocked/slow Hub.
actor FluidAudioTranscriber: Transcriber {
    enum FluidAudioTranscriberError: LocalizedError {
        case unsupportedEngine(STTEngine)
        case loadFailed(String)
        case notLoaded
        var errorDescription: String? {
            switch self {
            case .unsupportedEngine(let e): return "FluidAudio cannot drive STT engine \(e.rawValue)"
            case .loadFailed(let why): return "Speech model failed to load: \(why)"
            case .notLoaded: return "Speech model is not loaded"
            }
        }
    }

    private let engine: STTEngine

    /// Parakeet TDT v3 — batch transcription.
    private var parakeet: AsrManager?
    /// Nemotron 3.5 multilingual — streaming manager fed the whole clip then finished.
    private var nemotron: StreamingNemotronMultilingualAsrManager?

    private var loadTask: Task<Void, Error>?

    /// `engine` must be `.parakeetV3` or `.nemotronMultilingual`.
    init(engine: STTEngine) {
        self.engine = engine
    }

    var isReady: Bool { parakeet != nil || nemotron != nil }

    /// Download (first run) + load the chosen model. Idempotent: concurrent callers await
    /// the same in-flight load.
    func prepare() async throws {
        if isReady { return }
        if let loadTask { try await loadTask.value; return }

        let task = Task<Void, Error> { try await self.load() }
        loadTask = task
        do {
            try await task.value
            loadTask = nil
        } catch {
            loadTask = nil
            throw FluidAudioTranscriberError.loadFailed(error.localizedDescription)
        }
    }

    private func load() async throws {
        switch engine {
        case .parakeetV3:
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(models)
            parakeet = mgr
        case .nemotronMultilingual:
            let shared = try await StreamingNemotronMultilingualAsrManager
                .downloadAndPreloadShared(languageCode: "auto", chunkMs: 2240)
            let mgr = StreamingNemotronMultilingualAsrManager()
            try await mgr.loadFromShared(shared)
            nemotron = mgr
        case .whisperLargeV3Turbo:
            throw FluidAudioTranscriberError.unsupportedEngine(engine)
        }
    }

    /// Transcribe 16 kHz mono normalized Float PCM ([-1, 1)). `language` nil/"auto" means
    /// autodetect (Parakeet always autodetects; Nemotron honors the hint when given).
    func transcribe(samples: [Float], language: String?) async throws -> String {
        if !isReady { try await prepare() }
        switch engine {
        case .parakeetV3:
            guard let mgr = parakeet else { throw FluidAudioTranscriberError.notLoaded }
            var decoderState = TdtDecoderState.make(decoderLayers: await mgr.decoderLayerCount)
            let result = try await mgr.transcribe(samples, decoderState: &decoderState)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .nemotronMultilingual:
            guard let mgr = nemotron else { throw FluidAudioTranscriberError.notLoaded }
            let lang = (language?.isEmpty == false && language != "auto") ? language : nil
            await mgr.setLanguage(lang)
            _ = try await mgr.process(samples: samples)
            let text = try await mgr.finish()
            await mgr.reset()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .whisperLargeV3Turbo:
            throw FluidAudioTranscriberError.unsupportedEngine(engine)
        }
    }
}
