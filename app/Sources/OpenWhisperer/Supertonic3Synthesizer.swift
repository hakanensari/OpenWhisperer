import Foundation
import FluidAudio
import OpenWhispererKit

/// In-process multilingual text-to-speech via FluidAudio's Supertonic3 (CoreML / ANE). One of
/// the `SpeechSynthesizer` backends; renders at 44.1 kHz. Actor-isolated so the one-time model
/// load can't race and synthesis serializes on the compute unit. Offline-first: Supertonic3's
/// model store reuses the shared FluidAudio cache.
///
/// v1 uses Supertonic3's default voice and a fixed output language ("en"). The engine supports
/// 31 languages (incl. Turkish), but the app doesn't detect the reply language yet, so
/// per-reply language/voice selection is deliberately out of scope (see the 2026-06-20 design).
actor Supertonic3Synthesizer: SpeechSynthesizer {
    enum Supertonic3SynthError: LocalizedError {
        case loadFailed(String)
        case notLoaded
        var errorDescription: String? {
            switch self {
            case .loadFailed(let why): return "TTS model failed to load: \(why)"
            case .notLoaded: return "TTS model is not loaded"
            }
        }
    }

    /// Supertonic3 renders at 44.1 kHz mono.
    nonisolated let outputSampleRate = Supertonic3Constants.sampleRate

    /// v1 fixed output language (one of `Supertonic3Constants.availableLanguages`).
    private static let language = "en"

    private var manager: Supertonic3Manager?
    private var style: Supertonic3VoiceStyle?
    private var loadTask: Task<Void, Error>?

    var isReady: Bool { manager != nil && style != nil }

    /// Download (first run) + load the Supertonic3 stages and default voice style. Idempotent:
    /// concurrent callers await the same in-flight load.
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
            throw Supertonic3SynthError.loadFailed(error.localizedDescription)
        }
    }

    private func load() async throws {
        let mgr = try await Supertonic3Manager.downloadAndCreate()
        style = try await Supertonic3ResourceDownloader.loadVoiceStyle(Supertonic3Voice.default)
        manager = mgr
    }

    /// Synthesize `text` → raw 44.1 kHz mono fp32 PCM samples. Expands numerics to spoken words
    /// first (mirrors the Kokoro path). Loads the model on first use.
    func synthesizeSamples(_ text: String, voice: String = "") async throws
        -> (samples: [Float], sampleRate: Int) {
        if !isReady { try await prepare() }
        guard let manager, let style else { throw Supertonic3SynthError.notLoaded }
        let spoken = NumberNormalizer.normalize(text)
        let (samples, _) = try await manager.synthesize(text: spoken, language: Self.language, style: style)
        return (samples, outputSampleRate)
    }

    /// Synthesize `text` → a self-contained 44.1 kHz WAV `Data` (for `/v1/audio/speech`).
    func synthesize(_ text: String, voice: String = "") async throws -> Data {
        let (samples, sampleRate) = try await synthesizeSamples(text, voice: voice)
        return WAVEncoder.wavData(samples: samples, sampleRate: sampleRate)
    }
}
