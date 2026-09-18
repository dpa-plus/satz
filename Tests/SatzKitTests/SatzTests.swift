import Testing
@testable import SatzKit

@Test func versionIsPresent() {
    #expect(!Satz.version.isEmpty)
}
