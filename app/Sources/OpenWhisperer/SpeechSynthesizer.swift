import Foundation

/// A text-to-speech backend. Conformers are actors so the one-time model load and synthesis
/// serialize on the single ANE/compute unit. `outputSampleRate` is the fixed rate of the PCM
/// returned by `synthesizeSamples`, so the playback engine can be configured up front.
protocol SpeechSynthesizer: Sendable {
    /// Hz of the mono Float PCM returned by `synthesizeSamples`. Constant per backend
    /// (Kokoro 24 kHz, Supertonic3 44.1 kHz).
    var outputSampleRate: Int { get }

    func prepare() async throws

    /// Synthesize `text` → mono Float PCM (no WAV wrapper) for in-process streaming playback.
    func synthesizeSamples(_ text: String, voice: String) async throws -> (samples: [Float], sampleRate: Int)

    /// Synthesize `text` → a self-contained WAV `Data` (used by the blocking
    /// `/v1/audio/speech` endpoint).
    func synthesize(_ text: String, voice: String) async throws -> Data
}
