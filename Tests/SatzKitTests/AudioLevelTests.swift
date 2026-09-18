import Testing
@testable import SatzKit

private func level(_ samples: [Float], noiseFloor: Float = -55) -> Float {
    samples.withUnsafeBufferPointer { AudioRecorder.level(of: $0, noiseFloor: noiseFloor) }
}

@Test func silenceReadsAsNothing() {
    #expect(level([0, 0, 0, 0]) == 0)
    #expect(level([]) == 0)
}

@Test func fullScaleReadsAsFull() {
    #expect(level([1, -1, 1, -1]) == 1)
}

@Test func roomToneStaysBelowTheNoiseFloor() {
    // Roughly -80 dB. The bars should not twitch while nobody is speaking.
    #expect(level([0.0001, -0.0001]) == 0)
}

@Test func louderSpeechDrawsTallerBars() {
    let quiet = level([0.02, -0.02])
    let loud = level([0.4, -0.4])

    #expect(quiet > 0)
    #expect(loud > quiet)
    #expect(loud <= 1)
}

@Test func levelStaysInRangeForAnyInput() {
    // Clipped input from a hot microphone must not push the bars past full.
    #expect(level([9, -9]) == 1)
}
