import Foundation

/// Which speech-to-text backend drives dictation. The `rawValue` is the string
/// written to the `stt_engine` pref file, so it must stay stable.
public enum STTEngine: String, CaseIterable, Sendable {
    /// WhisperKit (CoreML) — Whisper large-v3-turbo, ~99 languages.
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"
    /// FluidAudio Parakeet TDT v3 — 25 European languages, fast, no Turkish.
    case parakeetV3 = "parakeet-v3"
    /// FluidAudio Nemotron-3.5 multilingual — ~40 languages incl. Turkish.
    case nemotronMultilingual = "nemotron-multilingual"

    public var label: String {
        switch self {
        case .whisperLargeV3Turbo: return "Whisper large-v3-turbo"
        case .parakeetV3: return "Parakeet v3 (European)"
        case .nemotronMultilingual: return "Nemotron multilingual"
        }
    }

    /// First-run default (no pref file present) — see the 2026-06-20 design.
    public static let defaultEngine: STTEngine = .nemotronMultilingual

    /// Parse a pref string, falling back to `defaultEngine` on nil/blank/unknown.
    public static func parse(_ raw: String?) -> STTEngine {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let engine = STTEngine(rawValue: trimmed) else { return defaultEngine }
        return engine
    }
}
