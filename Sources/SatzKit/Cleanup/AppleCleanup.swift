import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's language model on this Mac (Apple Intelligence, macOS 26): free,
/// and nothing leaves the computer. Mac only; Windows and Linux have nothing
/// like it.
///
/// A small model: in the test on 14.10.2026 it answered dictated questions or
/// translated in 4 of 12 tricky dictations at "Leicht", 3 of them caught by
/// the guard. The prompt and examples are the cloud models', given as a
/// transcript the way that test gave them (instructions, then each example
/// as a prompt and its response).
public enum AppleCleanup {

    public enum State: Equatable, Sendable {
        case available
        /// This Mac cannot run it at all.
        case notEligible
        /// Apple Intelligence is switched off in System Settings.
        case notEnabled
        /// Still downloading or preparing the model.
        case notReady
        /// Older than macOS 26, or built without FoundationModels.
        case unsupported

        /// What the settings say about it; nil when it can be used.
        public func message(in language: Language = .current) -> String? {
            let english = language == .english
            return switch self {
            case .available: nil
            case .notEligible: english ? "This Mac cannot run it." : "Dieser Mac kann es nicht."
            case .notEnabled: english ? "Turn on Apple Intelligence first" : "Erst Apple Intelligence einschalten"
            case .notReady: english ? "Apple Intelligence is still loading." : "Apple Intelligence lädt noch."
            case .unsupported: english ? "Needs macOS 26." : "Braucht macOS 26."
            }
        }
    }

    public static var state: State {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .notEligible
            case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
            case .unavailable(.modelNotReady): return .notReady
            case .unavailable: return .notEnabled
            }
        }
        #endif
        return .unsupported
    }

    public static var isAvailable: Bool { state == .available }

    /// Tokens the model can hold, question and answer together: 4096 before
    /// macOS 26.4 said otherwise.
    static var contextSize: Int {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.contextSize }
        #endif
        return 4096
    }

    /// Whether the prompt, the examples, the text and an answer as long as
    /// the text fit, with room to spare. Not sent otherwise: the model cuts
    /// off or fails halfway.
    static func fits(_ messages: CleanupPrompt.Messages, contextSize: Int = contextSize) -> Bool {
        let characters = CleanupTiming.characters(messages.system) + messages.turns.map { CleanupTiming.characters($0.content) }.reduce(0, +)
        return CleanupTiming.tokens(characters) * 2 <= contextSize - 300
    }

    /// The model's answer to the last turn, after the others as examples.
    static func respond(_ messages: CleanupPrompt.Messages) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard let last = messages.turns.last else { return "" }
            var entries: [Transcript.Entry] = [
                .instructions(Transcript.Instructions(segments: [.text(.init(content: messages.system))], toolDefinitions: [])),
            ]
            for turn in messages.turns.dropLast() {
                let segment = Transcript.Segment.text(.init(content: turn.content))
                switch turn.role {
                case .user: entries.append(.prompt(Transcript.Prompt(segments: [segment])))
                case .assistant: entries.append(.response(Transcript.Response(assetIDs: [], segments: [segment])))
                }
            }
            let session = LanguageModelSession(transcript: Transcript(entries: entries))
            do {
                // Greedy: the same text gives the same answer every time.
                return try await session.respond(to: last.content, options: GenerationOptions(samplingMode: .greedy)).content
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .guardrailViolation, .refusal: throw CleanupFailure.answerRefused
                case .assetsUnavailable: throw CleanupFailure.appleOff
                // Its tokens are not ours: `fits` can let a text through that is not.
                case .exceededContextWindowSize: throw CleanupFailure.tooLongForApple
                default: throw CleanupFailure.providerError
                }
            }
        }
        #endif
        throw CleanupFailure.appleOff
    }
}
