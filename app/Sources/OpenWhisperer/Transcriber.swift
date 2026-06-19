import Foundation

/// A speech-to-text backend. Conformers are actors so the one-time model load and
/// `transcribe` calls serialize on the single ANE/compute unit. `samples` is 16 kHz
/// mono normalized Float PCM ([-1, 1)); `language` nil/"auto" means autodetect.
protocol Transcriber: Sendable {
    func prepare() async throws
    func transcribe(samples: [Float], language: String?) async throws -> String
}
