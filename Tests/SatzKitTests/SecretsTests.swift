#if os(macOS)
import Foundation
import Testing
@testable import SatzKit

@Suite(.serialized)
struct SecretsTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("satz-secrets-\(UUID().uuidString)")

    init() {
        Secrets.directory = folder
    }

    @Test func aStoredKeyComesBack() throws {
        try Secrets.store("sk-or-test", for: .openRouter)
        #expect(Secrets.read(for: .openRouter) == "sk-or-test")
        #expect(Secrets.exists(for: .openRouter))
        #expect(!Secrets.exists(for: .groq))
    }

    @Test func storingAgainReplacesTheKey() throws {
        try Secrets.store("a-much-longer-first-key", for: .openAI)
        try Secrets.store("short", for: .openAI)
        #expect(Secrets.read(for: .openAI) == "short")
    }

    @Test func onlyTheUserCanReadIt() throws {
        try Secrets.store("sk-test", for: .groq)
        let file = folder.appendingPathComponent(Provider.groq.keychainAccount)
        let filePermissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let folderPermissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(filePermissions == 0o600)
        #expect(folderPermissions == 0o700)
    }

    @Test func removingForgetsIt() throws {
        try Secrets.store("sk-test", for: .custom)
        Secrets.remove(for: .custom)
        #expect(Secrets.read(for: .custom) == nil)
    }
}
#endif
