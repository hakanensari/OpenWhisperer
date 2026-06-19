import Foundation
import OpenWhispererKit

func wavEncoderFailures() -> [String] {
    var failures: [String] = []

    let samples: [Float] = [0, 0.5, -0.5, 1, -1]
    let wav = WAVEncoder.wavData(samples: samples, sampleRate: 24_000)

    // header: RIFF....WAVEfmt
    func ascii(_ range: Range<Int>) -> String { String(decoding: wav[range], as: UTF8.self) }
    if ascii(0..<4) != "RIFF" { failures.append("WAV: missing RIFF magic") }
    if ascii(8..<12) != "WAVE" { failures.append("WAV: missing WAVE magic") }
    if ascii(12..<16) != "fmt " { failures.append("WAV: missing fmt chunk") }
    if ascii(36..<40) != "data" { failures.append("WAV: missing data chunk") }

    // total length = 44-byte header + 2 bytes/sample
    let expected = 44 + samples.count * 2
    if wav.count != expected { failures.append("WAV: length \(wav.count) != \(expected)") }

    // sample rate little-endian at offset 24
    let sr = UInt32(wav[24]) | (UInt32(wav[25]) << 8) | (UInt32(wav[26]) << 16) | (UInt32(wav[27]) << 24)
    if sr != 24_000 { failures.append("WAV: sample rate \(sr) != 24000") }

    // empty input still yields a valid 44-byte header
    if WAVEncoder.wavData(samples: [], sampleRate: 16_000).count != 44 {
        failures.append("WAV: empty should be 44-byte header")
    }

    return failures
}
