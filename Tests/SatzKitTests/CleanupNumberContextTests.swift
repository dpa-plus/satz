import Foundation
import Testing
@testable import SatzKit

private struct NumberContextCase: Decodable, Sendable {
    let note: String, input: String, output: String
    let acceptLevels: [CleanupLevel]
    let vocabulary: [String]
}
private func numberContextCases() throws -> [NumberContextCase] {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/cleanup-number-context-cases.json")
    return try JSONDecoder().decode([NumberContextCase].self, from: Data(contentsOf: file))
}
private func numberContextJob(_ level: CleanupLevel, vocabulary: [String]) -> CleanupJob {
    CleanupJob(provider: .apple, model: CleanupCatalog.model(CleanupProvider.apple.defaultModel, for: .apple),
               address: "", key: nil, level: level, customPrompt: "Rewrite", vocabulary: vocabulary)
}
@Suite struct CleanupNumberContextTests {
    @Test(arguments: CleanupLevel.presets)
    func sharedNumericContextMatrix(level: CleanupLevel) throws {
        for item in try numberContextCases() {
            #expect(CleanupGuard.accepts(item.output, for: item.input, level: level, vocabulary: item.vocabulary)
                    == item.acceptLevels.contains(level), "\(level): \(item.note)")
        }
    }
    @Test(arguments: CleanupLevel.presets)
    func clientRetainsTheWholeOriginalWhenNumericContextChanges(level: CleanupLevel) async throws {
        for item in try numberContextCases() where item.acceptLevels.isEmpty {
            let result = await CleanupClient(apple: { _ in item.output }).run(numberContextJob(level, vocabulary: item.vocabulary), text: item.input)
            #expect(result.text == item.input, "\(level): \(item.note)")
            #expect(result.failure == .rejected, "\(level): \(item.note)")
        }
    }
    @Test func safeFormattingAndIntentionalCustomRewritingStillWork() async throws {
        for item in try numberContextCases() {
            for level in item.acceptLevels + [.custom] {
                let result = await CleanupClient(apple: { _ in item.output }).run(numberContextJob(level, vocabulary: item.vocabulary), text: item.input)
                #expect(result.text == item.output && result.failure == nil, "\(level): \(item.note)")
            }
        }
    }
}
