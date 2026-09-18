import Foundation
import Testing
@testable import SatzKit

private func string(_ data: Data, at offset: Int, count: Int) -> String {
    String(decoding: data[offset ..< offset + count], as: UTF8.self)
}

private func uint32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset ..< offset + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
}

private func uint16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset + 1]) << 8 | UInt16(data[offset])
}

private func int16(_ data: Data, at offset: Int) -> Int16 {
    let low = UInt16(data[offset])
    let high = UInt16(data[offset + 1])
    return Int16(bitPattern: high << 8 | low)
}

@Test func headerDescribesTheAudioThatFollows() {
    let data = WAVEncoder.encode(samples: [0, 0, 0, 0], sampleRate: 16_000)

    #expect(string(data, at: 0, count: 4) == "RIFF")
    #expect(string(data, at: 8, count: 4) == "WAVE")
    #expect(string(data, at: 12, count: 4) == "fmt ")
    #expect(string(data, at: 36, count: 4) == "data")

    #expect(data.count == 44 + 8)            // 4 samples, 2 bytes each
    #expect(uint32(data, at: 4) == 36 + 8)   // RIFF size excludes the first 8 bytes
    #expect(uint32(data, at: 24) == 16_000)  // sample rate
    #expect(uint32(data, at: 28) == 32_000)  // byte rate: 16k * 1 channel * 2 bytes
    #expect(uint32(data, at: 40) == 8)       // data size

    // Without these a wrong bit depth or channel count still passes, and the
    // server decodes the audio as noise.
    #expect(uint16(data, at: 20) == 1)       // format tag: uncompressed PCM
    #expect(uint16(data, at: 22) == 1)       // channels: mono
    #expect(uint16(data, at: 32) == 2)       // block align: 1 channel * 2 bytes
    #expect(uint16(data, at: 34) == 16)      // bits per sample
}

@Test func fullScaleSamplesSurviveTheConversion() {
    let data = WAVEncoder.encode(samples: [0, 1, -1], sampleRate: 16_000)

    #expect(int16(data, at: 44) == 0)
    #expect(int16(data, at: 46) == 32767)
    #expect(int16(data, at: 48) == -32767)
}

@Test func samplesBeyondFullScaleAreClampedRatherThanWrapped() {
    // A wrap would turn a loud sample into a loud sample of the opposite sign,
    // which is audible as a click. Clamping is the only acceptable behaviour.
    let data = WAVEncoder.encode(samples: [2.5, -2.5], sampleRate: 16_000)

    #expect(int16(data, at: 44) == 32767)
    #expect(int16(data, at: 46) == -32767)
}

@Test func silenceStillProducesAPlayableFile() {
    let data = WAVEncoder.encode(samples: [], sampleRate: 16_000)

    #expect(data.count == 44)
    #expect(uint32(data, at: 40) == 0)
}
