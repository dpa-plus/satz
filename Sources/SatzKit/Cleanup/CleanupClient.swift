import Foundation

/// Sends one text to be cleaned up and decides what gets pasted.
///
/// Never loses the words: every way this can go wrong (no key, an error, too
/// slow, an answer that is not the dictation any more) gives back the
/// original, with the reason.
public struct CleanupClient: Sendable {

    private let session: URLSession
    /// Tests wait less.
    private let timeoutOverride: TimeInterval?
    /// Tests stand in for Apple's model; nil asks the real one.
    private let apple: (@Sendable (CleanupPrompt.Messages) async throws -> String)?

    public init(session: URLSession = .shared, timeout: TimeInterval? = nil,
                apple: (@Sendable (CleanupPrompt.Messages) async throws -> String)? = nil) {
        self.session = session
        timeoutOverride = timeout
        self.apple = apple
    }

    public func run(_ job: CleanupJob, text original: String) async -> CleanupResult {
        var result = await outcome(job, text: original)
        result.provider = job.provider
        result.model = job.model.id
        return result
    }

    private func outcome(_ job: CleanupJob, text original: String) async -> CleanupResult {
        // Line breaks at either end were said; the model gets the text
        // without them, and they come back after (`CleanupPrompt.clean`).
        let core = original.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing to clean ("…", "?"): pasted as it is, nothing sent.
        guard CleanupPrompt.hasContent(core) else { return CleanupResult(text: original) }
        if let missing = job.missing { return CleanupResult(text: original, failure: missing) }
        // A test copy sends nothing to a provider that costs money. After the
        // checks above, in the order Windows and Linux have them.
        if job.onlyThisComputer, !job.staysOnThisComputer {
            return CleanupResult(text: original, failure: .notReachable,
                                 detail: "test mode sends nothing to \(job.provider.rawValue), only to this computer")
        }
        let timeout = timeoutOverride ?? CleanupTiming.timeout(for: core, level: job.level, runsHere: job.runsHere,
                                                               catalogSeconds: job.model.seconds)
        let started = Date()
        do {
            let answer = try await Self.within(timeout) { [self] in try await ask(job, text: core, timeout: timeout) }
            let seconds = Date().timeIntervalSince(started)
            let dollars = answer.cost ?? Self.cost(of: answer, model: job.model)
            if answer.refused { return CleanupResult(text: original, failure: .answerRefused, seconds: seconds, dollars: dollars) }
            let cleaned = CleanupPrompt.clean(answer: answer.text ?? "", original: original)
            guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return CleanupResult(text: original, failure: .empty, seconds: seconds, dollars: dollars)
            }
            if answer.truncated {
                return CleanupResult(text: original, failure: .cutOff, cleaned: cleaned, seconds: seconds, dollars: dollars)
            }
            guard CleanupGuard.accepts(cleaned, for: core, level: job.level, vocabulary: job.vocabulary) else {
                return CleanupResult(text: original, failure: .rejected, cleaned: cleaned, seconds: seconds, dollars: dollars)
            }
            return CleanupResult(text: cleaned, cleaned: cleaned, seconds: seconds, dollars: dollars)
        } catch let failure as Failed {
            return CleanupResult(text: original, failure: failure.failure, seconds: Date().timeIntervalSince(started), detail: failure.detail)
        } catch let failure as CleanupFailure {
            return CleanupResult(text: original, failure: failure, seconds: Date().timeIntervalSince(started))
        } catch let error as URLError {
            return CleanupResult(text: original, failure: .from(error), seconds: Date().timeIntervalSince(started),
                                 detail: "network \(error.code.rawValue)")
        } catch {
            return CleanupResult(text: original, failure: .notReachable, seconds: Date().timeIntervalSince(started))
        }
    }

    /// A failure with what may be logged about it.
    struct Failed: Error {
        let failure: CleanupFailure
        let detail: String?
    }

    private func ask(_ job: CleanupJob, text: String, timeout: TimeInterval) async throws -> CleanupRequest.Answer {
        if job.provider == .apple {
            let messages = CleanupPrompt.messages(job.level, text: text, vocabulary: job.vocabulary, customPrompt: job.customPrompt)
            guard let apple else {
                guard AppleCleanup.isAvailable else { throw CleanupFailure.appleOff }
                guard AppleCleanup.fits(messages) else { throw CleanupFailure.tooLongForApple }
                return CleanupRequest.Answer(text: try await AppleCleanup.respond(messages))
            }
            return CleanupRequest.Answer(text: try await apple(messages))
        }
        guard let (first, body) = CleanupRequest.make(job, text: text) else { throw CleanupFailure.noAddress }
        var request = first
        request.timeoutInterval = timeout
        var (data, status) = try await send(request)
        // Once more without an extra the provider says it does not take.
        if status == 400, let said = CleanupRequest.message(in: data),
           let changed = CleanupRequest.retried(body, job: job, message: said, text: text), let base = job.baseURL {
            request = CleanupRequest.request(job, base: base, body: changed)
            request.timeoutInterval = timeout
            (data, status) = try await send(request)
        }
        guard (200 ..< 300).contains(status) else {
            let said = CleanupRequest.message(in: data).map { ": \($0)" } ?? ""
            throw Failed(failure: .from(status: status, body: data), detail: "status \(status)\(said)")
        }
        guard let answer = CleanupRequest.parse(data, family: job.provider.family) else {
            throw Failed(failure: .providerError, detail: "status \(status): unreadable answer")
        }
        return answer
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The tokens counted, at the model's price per million.
    static func cost(of answer: CleanupRequest.Answer, model: CleanupModel) -> Double? {
        guard let tokensIn = answer.inputTokens, let tokensOut = answer.outputTokens,
              let priceIn = model.input, let priceOut = model.output else { return nil }
        return (Double(tokensIn) * priceIn + Double(tokensOut) * priceOut) / 1_000_000
    }

    /// The work, or "Zu langsam" once the time is up, whichever comes first.
    /// A request's own timeout restarts with every byte; this one does not.
    static func within<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CleanupFailure.tooSlow
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CleanupFailure.tooSlow }
            return first
        }
    }
}
