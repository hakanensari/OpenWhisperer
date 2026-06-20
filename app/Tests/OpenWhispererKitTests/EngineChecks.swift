import OpenWhispererKit

func engineFailures() -> [String] {
    var failures: [String] = []

    // rawValue round-trips for every case
    for engine in STTEngine.allCases where STTEngine(rawValue: engine.rawValue) != engine {
        failures.append("STTEngine round-trip failed for \(engine.rawValue)")
    }
    for engine in TTSEngine.allCases where TTSEngine(rawValue: engine.rawValue) != engine {
        failures.append("TTSEngine round-trip failed for \(engine.rawValue)")
    }

    // first-run defaults match the design (Whisper for STT — best English + multilingual)
    if STTEngine.defaultEngine != .whisperLargeV3Turbo {
        failures.append("STTEngine.defaultEngine should be Whisper")
    }
    if TTSEngine.defaultEngine != .kokoro {
        failures.append("TTSEngine.defaultEngine should be Kokoro")
    }

    // parse falls back on nil/blank/unknown, trims, and matches known values
    if STTEngine.parse(nil) != .whisperLargeV3Turbo { failures.append("STT parse(nil) should default") }
    if STTEngine.parse("garbage") != .whisperLargeV3Turbo { failures.append("STT parse(unknown) should default") }
    if STTEngine.parse("  parakeet-v3 \n") != .parakeetV3 { failures.append("STT parse should trim + match") }
    if STTEngine.parse("whisper-large-v3-turbo") != .whisperLargeV3Turbo { failures.append("STT parse whisper failed") }
    if TTSEngine.parse("supertonic3") != .supertonic3 { failures.append("TTS parse supertonic3 failed") }
    if TTSEngine.parse("") != .kokoro { failures.append("TTS parse(blank) should default") }

    return failures
}
