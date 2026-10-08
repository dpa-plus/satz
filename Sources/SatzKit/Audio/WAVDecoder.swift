import Foundation

/// Reads a mono 16-bit PCM WAV back into samples: for the clip satz times a
/// local model with. The chunks are found by name, so a file with extra
/// chunks before its audio (some tools write a LIST) reads the same.
public enum WAVDecoder {

    /// Samples in -1...1 and the sample rate; nil for anything but mono 16-bit PCM.
    public static func decode(_ data: Data) -> (samples: [Float], sampleRate: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, ascii(bytes, 0) == "RIFF", ascii(bytes, 8) == "WAVE" else { return nil }
        var offset = 12
        var sampleRate: Int?
        while offset + 8 <= bytes.count {
            let id = ascii(bytes, offset)
            let size = Int(uint32(bytes, offset + 4))
            let body = offset + 8
            guard body + size <= bytes.count || id == "data" else { return nil }
            if id == "fmt " {
                guard size >= 16, uint16(bytes, body) == 1, uint16(bytes, body + 2) == 1, uint16(bytes, body + 14) == 16 else { return nil }
                sampleRate = Int(uint32(bytes, body + 4))
            } else if id == "data", let sampleRate {
                let end = min(body + size, bytes.count)
                var samples: [Float] = []
                samples.reserveCapacity((end - body) / 2)
                var index = body
                while index + 1 < end {
                    samples.append(Float(Int16(bitPattern: uint16(bytes, index))) / 32_767)
                    index += 2
                }
                return (samples, sampleRate)
            }
            // Chunks are padded to an even length.
            offset = body + size + (size & 1)
        }
        return nil
    }

    private static func ascii(_ bytes: [UInt8], _ at: Int) -> String {
        String(decoding: bytes[at ..< at + 4], as: UTF8.self)
    }

    private static func uint16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
