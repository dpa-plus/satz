import Foundation
import Testing
@testable import SatzKit

private func text(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}

@Test func fieldsAreWrappedInTheBoundary() {
    let body = MultipartBody(boundary: "BOUND")
    let encoded = text(body.encode(fields: [("model", "gpt-transcribe")], file: nil))

    #expect(encoded.hasPrefix("--BOUND\r\n"))
    #expect(encoded.contains("Content-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
    #expect(encoded.hasSuffix("--BOUND--\r\n"))
}

@Test func linesEndWithCarriageReturnLineFeed() {
    // A bare LF is accepted by some servers and rejected by others, and the
    // rejection arrives as an opaque 400.
    let body = MultipartBody(boundary: "BOUND")
    let encoded = text(body.encode(fields: [("a", "b")], file: nil))

    for line in encoded.split(separator: "\r\n", omittingEmptySubsequences: false) {
        #expect(!line.contains("\n"))
    }
}

@Test func theFilePartCarriesItsFilenameAndType() {
    let body = MultipartBody(boundary: "BOUND")
    let encoded = text(body.encode(
        fields: [],
        file: ("file", "speech.wav", "audio/wav", Data("RIFF".utf8))
    ))

    #expect(encoded.contains("name=\"file\"; filename=\"speech.wav\""))
    #expect(encoded.contains("Content-Type: audio/wav"))
    #expect(encoded.contains("\r\n\r\nRIFF\r\n"))
}

@Test func binaryAudioSurvivesUnchanged() {
    // The bytes must not be re-encoded on the way through: a WAV containing a
    // 0x0A would otherwise be corrupted by any line handling.
    let audio = Data([0x00, 0x0A, 0x0D, 0xFF, 0x80])
    let body = MultipartBody(boundary: "BOUND")
    let encoded = body.encode(fields: [], file: ("file", "a.wav", "audio/wav", audio))

    #expect(encoded.range(of: audio) != nil)
}

@Test func fieldOrderIsPreserved() {
    let body = MultipartBody(boundary: "BOUND")
    let encoded = text(body.encode(
        fields: [("model", "m"), ("prompt", "p")],
        file: nil
    ))
    let model = encoded.range(of: "name=\"model\"")
    let prompt = encoded.range(of: "name=\"prompt\"")

    #expect(model != nil && prompt != nil)
    #expect(model!.lowerBound < prompt!.lowerBound)
}
