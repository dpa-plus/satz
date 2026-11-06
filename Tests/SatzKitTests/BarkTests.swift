import Foundation
import Testing
@testable import SatzKit

@Test func barkCanBeChosenWithoutWhisperSupportAndOnlyHearsEnglish() throws {
    let sections = LocalCatalog.sections(supported: [], hasApple: false, current: LocalCatalog.parakeetUltra) { _ in false }
    let bark = try #require(sections.available.first { $0 == "bark-3.0-pro" })
    let model = try #require(LocalCatalog.model(bark))
    #expect(model.engine == .fluidAudio)
    #expect(model.isEnglishOnly)
    #expect(!model.languages.hearsGerman)
    #expect(model.told(choice: "de", spoken: .german) == nil)
    #expect(!LocalCatalog.whisperIDs.contains(bark))
    #expect(!LocalCatalog.mayDownload(bark, in: .test(stateFile: "/tmp/bark-test.json", modelsFolder: nil)))
    #expect(LocalCatalog.mayDownload(bark, in: .test(stateFile: "/tmp/bark-test.json", modelsFolder: "/tmp/bark-models")))
}
