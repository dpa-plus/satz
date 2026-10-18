import Foundation
import Testing
@testable import SatzKit

@Test func ultraIsOfferedWithoutWhisperSupportAndDoesNotForceGerman() throws {
    let model = try #require(LocalCatalog.offered(supported: [], hasApple: false).first { $0.id == "parakeet-ultra" })
    #expect(!LocalCatalog.whisperIDs.contains(model.id))
    #expect(model.told(choice: "de", spoken: .german) == nil)
    #expect(model.languages.codes.contains("de") && model.languages.codes.contains("en"))
    #expect(!LocalCatalog.mayDownload(model.id, in: .test(stateFile: "/tmp/state.json", modelsFolder: nil)))
}
