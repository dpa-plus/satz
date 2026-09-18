import Foundation

/// Writes 16-bit PCM WAV bytes.
///
/// The transcription endpoint takes a file upload, so the captured float
/// samples have to become a real WAV before they go anywhere. This is kept
/// separate from the recorder because it is pure: given samples, it produces
/// bytes, which makes it the one part of the audio path that is cheap to test.
public enum WAVEncoder {

    /// Bytes of a mono 16-bit PCM WAV containing `samples`.
    /// - Parameter samples: normalised audio in -1...1. Values outside are clamped.
    public static func encode(samples: [Float], sampleRate: Int) -> Data {
        let bitsPerSample = 16
        let channels = 1
        let bytesPerSample = bitsPerSample / 8
        let dataSize = samples.count * bytesPerSample * channels
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample

        var data = Data(capacity: 44 + dataSize)
        data.append(ascii: "RIFF")
        data.append(littleEndian: UInt32(36 + dataSize))
        data.append(ascii: "WAVE")

        data.append(ascii: "fmt ")
        data.append(littleEndian: UInt32(16))        // PCM header length
        data.append(littleEndian: UInt16(1))         // 1 == uncompressed PCM
        data.append(littleEndian: UInt16(channels))
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(byteRate))
        data.append(littleEndian: UInt16(blockAlign))
        data.append(littleEndian: UInt16(bitsPerSample))

        data.append(ascii: "data")
        data.append(littleEndian: UInt32(dataSize))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            // -1 maps to Int16.min and 1 to Int16.max, so scale by 32767 and
            // let the clamp above keep the result in range.
            data.append(littleEndian: Int16(clamped * 32767))
        }
        return data
    }
}

private extension Data {
    mutating func append(ascii text: String) {
        append(contentsOf: Array(text.utf8))
    }

    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        // Swift. prefix: inside a Data extension the bare name resolves to
        // Data's own withUnsafeBytes, which reads this value instead of writing it.
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
