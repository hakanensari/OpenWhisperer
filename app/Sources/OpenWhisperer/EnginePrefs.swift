import Foundation
import OpenWhispererKit

/// Flat-file load/save for the engine prefs, mirroring `InteractionMode`. The pure
/// enum + parsing lives in `OpenWhispererKit`; this app-target extension wires it to
/// `Paths`. `load()` returns the default when the file is absent (first-run behavior).
extension STTEngine {
    static func load() -> STTEngine {
        STTEngine.parse(try? String(contentsOf: Paths.sttEngine, encoding: .utf8))
    }

    func save() {
        try? rawValue.write(to: Paths.sttEngine, atomically: true, encoding: .utf8)
    }
}

extension TTSEngine {
    static func load() -> TTSEngine {
        TTSEngine.parse(try? String(contentsOf: Paths.ttsEngine, encoding: .utf8))
    }

    func save() {
        try? rawValue.write(to: Paths.ttsEngine, atomically: true, encoding: .utf8)
    }
}
