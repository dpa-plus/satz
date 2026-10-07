import Testing
@testable import SatzKit

@Test func theWordListIsKeptOnlyWhenItCostsNoWords() {
    let plain = "Schreib mir eine Funktion. Thanks for the update, Thursday works for me."
    #expect(WordCheck.keepEveryWord(prompted: "Schreib mir eine Funktion.", plain: plain).usedPrompt == false)
    #expect(WordCheck.keepEveryWord(prompted: plain, plain: plain).usedPrompt)
    #expect(WordCheck.keepEveryWord(prompted: "Schreib mir eine Funktion. Thanks for the update Thursday works for me", plain: plain).usedPrompt)
}
