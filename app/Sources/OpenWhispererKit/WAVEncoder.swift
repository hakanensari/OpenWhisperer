import Foundation

/// Wraps mono Float32 PCM samples ([-1, 1)) in a 16-bit PCM WAV container. Used by TTS
/// backends that emit raw samples (e.g. Supertonic3) to serve the blocking
/// `/v1/audio/speech` endpoint, which returns a self-contained WAV. Pure, so it's
/// unit-tested.
public enum WAVEncoder {
    public static func wavData(samples: [Float], sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * blockAlign
        let dataSize = samples.count * bytesPerSample

        var data = Data(capacity: 44 + dataSize)
        func appendLE32(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendLE16(_ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendLE32(UInt32(36 + dataSize))   // chunk size = file size - 8
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        appendLE32(16)                       // PCM fmt chunk size
        appendLE16(1)                        // audio format = PCM
        appendLE16(UInt16(channels))
        appendLE32(UInt32(sampleRate))
        appendLE32(UInt32(byteRate))
        appendLE16(UInt16(blockAlign))
        appendLE16(UInt16(bitsPerSample))

        data.append(contentsOf: Array("data".utf8))
        appendLE32(UInt32(dataSize))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            appendLE16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        return data
    }
}
