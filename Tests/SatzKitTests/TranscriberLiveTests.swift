import Foundation
import Testing
@testable import SatzKit

/// Talks to a real transcription endpoint. Skipped unless a key is supplied,
/// so `make test` stays offline and free:
///
///     SATZ_TEST_API_KEY=sk-... make test
///     SATZ_TEST_BASE_URL=https://openrouter.ai/api/v1 SATZ_TEST_MODEL=openai/gpt-transcribe ...
///
/// It uploads one second of silence. The transcript is expected to be empty;
/// what is being proved is that the request we build is one the server accepts.
private let liveKey = ProcessInfo.processInfo.environment["SATZ_TEST_API_KEY"]

@Test(.enabled(if: liveKey != nil))
func aRealServerAcceptsTheRequestWeBuild() async throws {
    let environment = ProcessInfo.processInfo.environment
    var settings = Transcriber.Settings()
    if let base = environment["SATZ_TEST_BASE_URL"], let url = URL(string: base) {
        settings.baseURL = url
    }
    if let model = environment["SATZ_TEST_MODEL"] {
        settings.model = model
    }

    let silence = WAVEncoder.encode(
        samples: Array(repeating: 0, count: 16_000),
        sampleRate: 16_000
    )
    let text = try await Transcriber(settings: settings)
        .transcribe(wav: silence, apiKey: try #require(liveKey))

    #expect(text.isEmpty || !text.isEmpty)  // reaching here at all is the assertion
}
