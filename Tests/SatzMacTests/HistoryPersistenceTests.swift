import AppKit
import SatzKit
import Testing
@testable import SatzMac

@Suite(.serialized) @MainActor
struct HistoryPersistenceTests {
    @Test func aFailedSaveRetainsWordsAndClearsItsWarningWhenSavingWorksAgain() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("satz-history-recovery-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: folder) }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let parent = folder.appendingPathComponent("blocked")
        try Data("synthetic blocker".utf8).write(to: parent)
        let file = parent.appendingPathComponent("history.json")
        let history = History(file: file)
        history.add("Cleaned synthetic words.", app: nil, pasted: true, original: "original synthetic words", cleanup: "ok")
        #expect(history.storageFailure == .saving)
        #expect(history.storageWarningTitle != nil && history.storageWarningDetail != nil)
        #expect(history.entries.first?.original == "original synthetic words")
        try manager.removeItem(at: parent)
        history.add("Second synthetic words.", app: nil, pasted: false)
        #expect(history.storageFailure == nil)
        let reloaded = History(file: file)
        #expect(reloaded.entries.map(\.text) == ["Second synthetic words.", "Cleaned synthetic words."])
        #expect(reloaded.entries.last?.original == "original synthetic words")
        #expect((try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func removalFailureWarnsUntilTheChangedHistoryIsSaved() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("satz-history-remove-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let history = History(file: file)
        history.add("Synthetic first.", app: nil, pasted: true)
        history.add("Synthetic second.", app: nil, pasted: true)
        let removed = try #require(history.entries.first)
        try manager.moveItem(at: file, to: folder.appendingPathComponent("previous.json"))
        try manager.createDirectory(at: file, withIntermediateDirectories: true)
        history.remove(removed)
        #expect(history.entries.map(\.text) == ["Synthetic first."])
        #expect(history.storageFailure == .saving)
        #expect(try manager.contentsOfDirectory(atPath: folder.path).filter {
            $0.hasPrefix(".history.json.") && $0.hasSuffix(".new")
        }.isEmpty)
        try manager.removeItem(at: file)
        history.limit = History.keepAll
        #expect(history.storageFailure == nil)
        #expect(History(file: file).entries.map(\.text) == ["Synthetic first."])
    }

    @Test func clearFailureIsVisibleWhileHistoryIsOffAndMissingFileClearsIt() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("satz-history-delete-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        try manager.createDirectory(at: file, withIntermediateDirectories: true)
        let marker = file.appendingPathComponent("synthetic-marker")
        try Data("synthetic contents".utf8).write(to: marker)
        let history = History(file: file)
        history.add("Synthetic unsaved words.", app: nil, pasted: true)
        history.limit = 0
        #expect(history.entries.isEmpty)
        #expect(history.storageFailure == .deleting)
        #expect(manager.fileExists(atPath: marker.path))
        history.add("Ignored while off.", app: nil, pasted: true)
        #expect(history.storageFailure == .deleting)
        #expect(history.entries.isEmpty)
        // Remove only this test's fixture; clearing a missing history is success.
        if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
        history.clear()
        #expect(history.storageFailure == nil)
        #expect(!manager.fileExists(atPath: file.path))
    }

    @Test func historyOffAndMemoryOnlyAreIntentionalAndDoNotWarn() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("satz-history-off-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let history = History(file: file)
        history.add("Synthetic saved words.", app: nil, pasted: true)
        history.limit = 0
        #expect(history.storageFailure == nil && !manager.fileExists(atPath: file.path))
        history.add("Ignored while off.", app: nil, pasted: true)
        #expect(history.entries.isEmpty && history.storageFailure == nil)
        #expect(!manager.fileExists(atPath: file.path))
        let memory = History()
        memory.add("Synthetic memory words.", app: nil, pasted: true)
        #expect(memory.entries.count == 1 && memory.storageFailure == nil)
    }

    @Test func permissionFailuresPreserveTheSavedFileAndClearTheirWarningAfterRecovery() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("satz-history-permissions-\(UUID().uuidString)")
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? manager.removeItem(at: folder)
        }
        let file = folder.appendingPathComponent("history.json")
        let history = History(file: file)
        history.add("Previously saved synthetic words.", app: nil, pasted: true)
        let previous = try Data(contentsOf: file)
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        history.add("Unsaved synthetic words.", app: nil, pasted: true)
        #expect(history.storageFailure == .saving && history.entries.count == 2)
        #expect(try Data(contentsOf: file) == previous)
        history.clear()
        #expect(history.storageFailure == .deleting && history.entries.isEmpty)
        #expect(try Data(contentsOf: file) == previous)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        history.clear()
        #expect(history.storageFailure == nil && !manager.fileExists(atPath: file.path))
    }

    @Test func historyOffAtStartupRetriesDeletionWithoutTouchingAnUnexpectedDirectory() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("satz-history-off-startup-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: folder) }
        let blocked = folder.appendingPathComponent("blocked.json")
        try manager.createDirectory(at: blocked, withIntermediateDirectories: true)
        let marker = blocked.appendingPathComponent("synthetic-marker")
        try Data("synthetic contents".utf8).write(to: marker)
        let blockedOff = History(file: blocked, limit: 0)
        #expect(blockedOff.storageFailure == .deleting && blockedOff.entries.isEmpty)
        #expect(manager.fileExists(atPath: marker.path))
        let saved = folder.appendingPathComponent("saved.json")
        History(file: saved).add("Previously saved synthetic words.", app: nil, pasted: true)
        let savedOff = History(file: saved, limit: 0)
        #expect(savedOff.storageFailure == nil && savedOff.entries.isEmpty)
        #expect(!manager.fileExists(atPath: saved.path))
        let missing = folder.appendingPathComponent("missing/history.json")
        let missingOff = History(file: missing, limit: 0)
        #expect(missingOff.storageFailure == nil && missingOff.entries.isEmpty)
        #expect(!manager.fileExists(atPath: missing.path))
    }

    @Test func aHistoryRenameFailureShowsANonRetryWarningAfterOneInsertion() async throws {
        _ = NSApplication.shared
        let oldLanguage = Language.current
        defer { Language.current = oldLanguage }
        for language in [Language.german, .english] {
            Language.current = language
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("satz-history-warning-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("history.json")
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            let history = History(file: file)
            let preferences = Preferences(defaults: nil)
            preferences.cleansText = true
            let discarded = Discarded()
            let session = Session(preferences: preferences, history: history, discarded: discarded)
            session.takesEscape = false
            var insertions = 0, cleanups = 0, warnings = 0
            session.cleaner = { text in cleanups += 1; return CleanupResult(text: text, cleaned: text) }
            session.pasteText = { _, _, _, _, _, _ in insertions += 1; return .pasted }
            session.onOpen = { warnings += 1 }
            session.stage(.paused, text: "Synthetic saved words.")
            session.press()
            for _ in 0..<100 where insertions == 0 { try? await Task.sleep(for: .milliseconds(10)) }
            let message = language == .german ? "Verlauf nicht gespeichert" : "History not saved"
            #expect(session.phase == .failed(message, canRetry: false))
            #expect(warnings == 1)
            #expect(!session.hasRealText)
            #expect(discarded.last == nil)
            #expect(history.entries.first?.text == "Synthetic saved words.")
            session.retry()
            await Task.yield()
            #expect(insertions == 1)
            #expect(cleanups == 1)
            #expect(history.entries.count == 1)
            #expect(history.storageWarningTitle == message)
            #expect(history.storageWarningDetail?.contains(folder.path) == false)
            session.discard()
        }
    }

    @Test func clipboardFallbackKeepsPriorityOverTheHistoryWarning() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("satz-history-clipboard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let history = History(file: file)
        let session = Session(preferences: Preferences(defaults: nil), history: history, discarded: Discarded())
        session.takesEscape = false
        var attempts = 0
        session.pasteText = { _, _, _, _, _, _ in attempts += 1; return .clipboardOnly("Synthetic fallback") }
        session.stage(.paused, text: "Synthetic clipboard words.")
        session.press()
        for _ in 0..<100 where attempts == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(session.phase == .clipboard)
        #expect(history.storageFailure == .saving && history.storageWarningTitle != nil)
        #expect(history.entries.first?.pasted == false)
        session.retry()
        await Task.yield()
        #expect(attempts == 1)
        session.discard()
    }

    @Test func aHistoryFailureCannotReplaceANewerActiveDraft() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("satz-history-active-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let history = History(file: file)
        let session = Session(preferences: Preferences(defaults: nil), history: history, discarded: Discarded())
        session.takesEscape = false
        var attempts = 0
        session.pasteText = { _, _, _, _, _, _ in
            attempts += 1
            session.discard()
            session.stage(.listening, text: "New synthetic draft.")
            return .pasted
        }
        session.stage(.paused, text: "Completed synthetic words.")
        session.press()
        for _ in 0..<100 where attempts == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(session.phase == .listening && session.plainText() == "New synthetic draft.")
        #expect(history.storageFailure == .saving && history.storageWarningTitle != nil)
        #expect(history.entries.count == 1 && history.entries.first?.pasted == true)
        session.discard()
    }

    @Test func savingTheNextDictationClearsTheOldWarning() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("satz-history-next-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let history = History(file: file)
        let session = Session(preferences: Preferences(defaults: nil), history: history, discarded: Discarded())
        session.takesEscape = false
        var attempts = 0
        session.pasteText = { _, _, _, _, _, _ in attempts += 1; return .pasted }
        session.stage(.paused, text: "First synthetic words.")
        session.press()
        for _ in 0..<100 where attempts == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(history.storageFailure == .saving)
        try FileManager.default.removeItem(at: file)
        session.stage(.paused, text: "Second synthetic words.")
        session.press()
        for _ in 0..<100 where attempts < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(history.storageFailure == nil && history.storageWarningTitle == nil)
        #expect(session.phase == .idle && attempts == 2)
        #expect(History(file: file).entries.map(\.text) == ["Second synthetic words.", "First synthetic words."])
    }

    @Test func historyOffDoesNotShowASaveWarningAfterInsertion() async {
        _ = NSApplication.shared
        let history = History(limit: 0)
        let session = Session(preferences: Preferences(defaults: nil), history: history, discarded: Discarded())
        session.takesEscape = false
        var attempts = 0, warnings = 0
        session.pasteText = { _, _, _, _, _, _ in attempts += 1; return .pasted }
        session.onOpen = { warnings += 1 }
        session.stage(.paused, text: "Synthetic unretained words.")
        session.press()
        for _ in 0..<100 where attempts == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(session.phase == .idle && warnings == 0)
        #expect(history.storageFailure == nil && history.entries.isEmpty)
    }

    @Test func theHistoryWarningDoesNotBlockAQueuedNewDictation() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("satz-history-queued-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let history = History(file: file)
        let preferences = Preferences(defaults: nil)
        preferences.provider = .custom
        preferences.model = ""
        let session = Session(preferences: preferences, history: history, discarded: Discarded())
        session.takesEscape = false
        var attempts = 0, starts = 0
        session.captureFocus = { _ in starts += 1; return (nil, nil) }
        session.pasteText = { _, _, _, _, _, _ in attempts += 1; session.press(); return .pasted }
        session.stage(.paused, text: "Synthetic completed words.")
        session.press()
        for _ in 0..<100 where attempts == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(starts == 1 && attempts == 1)
        #expect(session.phase != .failed(history.storageWarningTitle ?? "", canRetry: false))
        #expect(history.storageFailure == .saving)
        session.discard()
    }
}
