import Foundation

/// Which text-to-speech backend speaks replies. The `rawValue` is the string
/// written to the `tts_engine` pref file, so it must stay stable.
public enum TTSEngine: String, CaseIterable, Sendable {
    /// FluidAudio Kokoro — the shipped engine; English voice + voice picker.
    case kokoro = "kokoro"
    /// FluidAudio Supertonic3 — multilingual (includes Turkish output).
    case supertonic3 = "supertonic3"

    public var label: String {
        switch self {
        case .kokoro: return "Kokoro"
        case .supertonic3: return "Supertonic3 (multilingual)"
        }
    }

    /// First-run default (no pref file present) — see the 2026-06-20 design.
    public static let defaultEngine: TTSEngine = .kokoro

    /// Parse a pref string, falling back to `defaultEngine` on nil/blank/unknown.
    public static func parse(_ raw: String?) -> TTSEngine {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let engine = TTSEngine(rawValue: trimmed) else { return defaultEngine }
        return engine
    }
}
