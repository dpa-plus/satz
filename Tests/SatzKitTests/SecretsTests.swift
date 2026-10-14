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

    @Test func microsoftAndGoogleEachKeepAKeyOfTheirOwn() throws {
        try Secrets.store("azure-key-1", for: .microsoft)
        try Secrets.store("AIza-key-2", for: .google)
        #expect(Secrets.read(for: .microsoft) == "azure-key-1" && Secrets.read(for: .google) == "AIza-key-2")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("microsoft").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("google").path))
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("google").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func aKeyIsAnAccountsFileSharedByEveryUse() throws {
        // OpenRouter transcribes and cleans up with the one key.
        try Secrets.store("sk-or-shared", for: .openRouter)
        #expect(Secrets.read(account: CleanupProvider.openRouter.keyAccount!.name) == "sk-or-shared")
        // A cleanup provider's own key is a file of its own, 0600 too.
        try Secrets.store("sk-ant-test", account: "anthropic")
        #expect(Secrets.exists(account: "anthropic") && Secrets.read(account: "anthropic") == "sk-ant-test")
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("anthropic").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        Secrets.remove(account: "anthropic")
        #expect(!Secrets.exists(account: "anthropic"))
    }

    @Test func removingForgetsIt() throws {
        try Secrets.store("sk-test", for: .custom)
        Secrets.remove(for: .custom)
        #expect(Secrets.read(for: .custom) == nil)
    }
}
#endif
