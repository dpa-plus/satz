import AppKit
import Observation
import SatzKit

extension NSAttributedString.Key {
    /// Which recording a stretch of text came from.
    static let satzSegment = NSAttributedString.Key("plus.dpa.satz.segment")
    /// The placeholder "…" where a recording's text will land.
    static let satzMarker = NSAttributedString.Key("plus.dpa.satz.marker")
}

/// One dictation, from the first press of the shortcut to the paste.
///
/// The audio is never cut by satz: in tests a piece cut mid-sentence came back
/// with 18% wrong words, once in the wrong language. So everything said into
/// one spot is one recording. Text appears when the microphone pauses; going
/// on at the same spot extends that recording and sends all of it again, so
/// the model always hears the whole thing. Clicking somewhere else in the text
/// starts a new recording there, which is the user's choice of cut.
@MainActor
@Observable
final class Session {

    enum Phase: Equatable {
        case idle
        /// Opening the microphone, possibly behind the permission dialog.
        case starting
        case listening
        case paused
        /// The shortcut was pressed: the last parts are being sent, then pasted.
        case finishing
        /// Something could not be sent. The audio is kept for another try.
        case failed(String, canRetry: Bool)
        /// Just thrown away; "Rückgängig" is offered for a few seconds.
        case discarded
        /// Pasting was not possible, so the text waits on the clipboard.
        case clipboard
    }

    /// A stretch of audio said into one spot, and how much of it the text
    /// shown so far was made from.
    struct Segment {
        var audio: [Float] = []
        var transcribed = 0
        var failure: String?
    }

    private(set) var phase: Phase = .idle
    private(set) var levels = Array(repeating: Float(0), count: 12)
    /// Recordings on their way to the provider.
    private(set) var inFlight: Set<Int> = []
    /// Changes whenever the text does, so the card re-measures.
    private(set) var textVersion = 0

    /// Text or at least a placeholder to show.
    var hasText: Bool {
        _ = textVersion
        return text.length > 0
    }

    /// The card's text. Changed by the user in the text view, by satz in `edit`.
    @ObservationIgnored let text = NSTextStorage()
    /// Where the user last put the caret, nil until they do.
    @ObservationIgnored private(set) var caret: Int?
    /// True while satz edits `text`, so the text view does not take it for the user.
    @ObservationIgnored private(set) var isEditing = false

    @ObservationIgnored var onOpen: () -> Void = {}
    /// Test mode: receives the finished text instead of it being pasted.
    @ObservationIgnored var deliverOverride: ((String) -> Void)?
    @ObservationIgnored var onClose: () -> Void = {}

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let history: History
    @ObservationIgnored private let discarded: Discarded

    @ObservationIgnored private var segments: [Int: Segment] = [:]
    @ObservationIgnored private var activeID: Int?
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var recorder: AudioSource?
    /// Where the active recording's audio starts in `recorder`'s buffer.
    @ObservationIgnored private var liveStart = 0
    @ObservationIgnored private var sends: [Int: Task<Void, Never>] = [:]
    /// Stopping the microphone keeps it open for a short tail; these are those.
    @ObservationIgnored private var tails: [Task<Void, Never>] = []
    @ObservationIgnored private var finishing: Task<Void, Never>?
    @ObservationIgnored private var closingLater: Task<Void, Never>?
    /// Bumped whenever the whole session is thrown away, so late answers drop.
    @ObservationIgnored private var sessionToken = 0
    /// Bumped by every microphone start, so a start that resolves late drops.
    @ObservationIgnored private var startToken = 0
    @ObservationIgnored private var origin: NSRunningApplication?
    @ObservationIgnored private var escape: HotKey?

    init(preferences: Preferences, history: History, discarded: Discarded) {
        self.preferences = preferences
        self.history = history
        self.discarded = discarded
    }

    // MARK: - Shortcut

    /// The shortcut went down.
    func press() {
        switch (preferences.triggerMode, phase) {
        case (_, .idle), (_, .discarded), (_, .clipboard): begin()
        case (.tap, .listening), (.tap, .paused), (_, .failed): finish()
        case (.hold, .paused): resume()
        default: break
        }
    }

    /// The shortcut came up. Only meaningful while holding to talk.
    func release() {
        guard preferences.triggerMode == .hold else { return }
        switch phase {
        case .listening: finish()
        // Let go before the microphone even opened: nothing was said.
        case .starting: close()
        default: break
        }
    }

    // MARK: - Card buttons

    /// The microphone button: a pause to think, and back.
    func toggleMicrophone() {
        switch phase {
        case .listening: pause()
        case .paused: resume()
        default: break
        }
    }

    /// The × button and Escape. Recoverable: see `undoDiscard` and `restore`.
    func discard() {
        switch phase {
        case .idle: return
        case .discarded, .clipboard:
            close()
            return
        default: break
        }
        let snapshot = Discarded.Snapshot(
            text: NSAttributedString(attributedString: text),
            segments: segments.mapValues { segment in
                var kept = segment
                kept.failure = nil
                return kept
            },
            activeID: activeID,
            nextID: nextID,
            origin: origin,
            preview: plainText()
        )
        stopEverything()
        reset()
        let hasContent = !snapshot.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || snapshot.segments.values.contains { !$0.audio.isEmpty }
        guard hasContent else {
            close()
            return
        }
        discarded.keep(snapshot)
        phase = .discarded
        closeLater(after: .seconds(5))
    }

    /// "Rückgängig", while the card still says "Verworfen".
    func undoDiscard() {
        guard phase == .discarded, let snapshot = discarded.take() else { return }
        restore(snapshot)
    }

    /// Brings a discarded dictation back, paused, from the card or the menu.
    func restore(_ snapshot: Discarded.Snapshot) {
        guard phase == .idle || phase == .discarded || phase == .clipboard else { return }
        closingLater?.cancel()
        stopEverything()
        reset()
        edit { text.setAttributedString(snapshot.text) }
        segments = snapshot.segments
        activeID = snapshot.activeID
        nextID = snapshot.nextID
        origin = snapshot.origin ?? Self.frontmostOtherApp()
        if let activeID, markerRange(activeID) == nil {
            self.activeID = newSegment(at: text.length)
        }
        phase = .paused
        onOpen()
        // Anything that was on its way when it was thrown away goes again.
        for (id, segment) in segments where segment.audio.count > segment.transcribed {
            send(id)
        }
    }

    /// "Nochmal" after a failure.
    func retry() {
        guard case .failed(_, true) = phase else { return }
        finish()
    }

    // MARK: - Text view

    /// The user moved the caret. While listening that moves the insertion
    /// point: what was said so far goes where it was meant, the rest goes here.
    func userMovedCaret(to location: Int) {
        caret = location
        guard phase == .listening, let recorder, let id = activeID, !isAtMarker(location, of: id) else { return }
        let end = recorder.sampleCount
        append(recorder.samples(from: liveStart, to: end), to: id)
        liveStart = end
        activeID = newSegment(at: location)
        caret = nil
        send(id)
    }

    /// The user is about to change `range`. False refuses the change.
    func userWillEdit(_ range: NSRange) -> Bool {
        switch phase {
        case .finishing, .discarded, .clipboard, .idle: return false
        default: break
        }
        // The placeholders are satz's, not part of the text.
        guard !containsMarker(range) else { return false }
        for id in segments.keys where touches(range, segment: id) {
            freeze(id)
        }
        return true
    }

    func userDidEdit() {
        textVersion += 1
    }

    // MARK: - Steps

    private func begin() {
        closingLater?.cancel()
        stopEverything()
        reset()
        origin = Self.frontmostOtherApp()
        // Checked before recording: finding out there is no key once you have
        // finished speaking loses the whole message.
        guard Secrets.exists(for: preferences.provider) else {
            phase = .failed(Transcriber.Failure.noKey.short, canRetry: false)
            onOpen()
            closeLater(after: .seconds(5))
            return
        }
        guard !preferences.isEndpointMissing else {
            phase = .failed("Adresse fehlt", canRetry: false)
            onOpen()
            closeLater(after: .seconds(5))
            return
        }
        activeID = newSegment(at: 0)
        onOpen()
        startRecording()
    }

    private func startRecording() {
        startToken += 1
        let mine = startToken
        phase = .starting
        levels = Array(repeating: 0, count: levels.count)
        holdEscape()

        let recorder = AudioSources.make(inputDeviceUID: preferences.inputDeviceUID)
        recorder.onLevel = { [weak self] level in self?.push(level) }

        Task {
            do {
                try await recorder.start()
            } catch {
                guard mine == startToken else { return }
                releaseEscape()
                phase = .failed(error.localizedDescription, canRetry: false)
                return
            }
            // Thrown away while the permission dialog was up: close the
            // microphone that just opened rather than leave it running.
            guard mine == startToken, phase == .starting else {
                recorder.cancel()
                return
            }
            self.recorder = recorder
            liveStart = 0
            phase = .listening
        }
    }

    private func pause() {
        guard phase == .listening, let recorder, let id = activeID else { return }
        self.recorder = nil
        phase = .paused
        releaseEscape()
        levels = Array(repeating: 0, count: levels.count)
        let start = liveStart
        tails.append(Task {
            // The tail keeps the last word.
            let samples = await recorder.finishSamples() ?? []
            append(Array(samples.dropFirst(start)), to: id)
            send(id)
        })
    }

    private func resume() {
        guard phase == .paused else { return }
        if let caret, let id = activeID, !isAtMarker(caret, of: id) {
            activeID = newSegment(at: caret)
            // The old spot gets nothing more; its placeholder can go.
            removeMarkerIfDone(id)
        } else if activeID == nil || markerRange(activeID!) == nil {
            activeID = newSegment(at: caret ?? text.length)
        }
        caret = nil
        startRecording()
    }

    private func finish() {
        switch phase {
        case .listening, .paused, .failed: break
        default: return
        }
        phase = .finishing
        releaseEscape()
        let recorder = self.recorder
        self.recorder = nil
        let id = activeID
        let start = liveStart
        let pending = tails
        tails = []
        let token = sessionToken

        finishing = Task {
            for tail in pending { await tail.value }
            if let recorder, let id {
                let samples = await recorder.finishSamples() ?? []
                append(Array(samples.dropFirst(start)), to: id)
            }
            guard token == sessionToken else { return }
            for (id, segment) in segments where segment.audio.count > segment.transcribed || segment.failure != nil {
                send(id)
            }
            while let next = sends.values.first {
                await next.value
                guard token == sessionToken else { return }
            }
            if let failure = segments.values.compactMap(\.failure).first {
                phase = .failed(failure, canRetry: true)
                return
            }
            deliver()
        }
    }

    private func deliver() {
        let output = plainText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            reset()
            phase = .failed("Nichts gehört", canRetry: false)
            closeLater(after: .seconds(3))
            return
        }
        let origin = self.origin
        // Gone before pasting, so the keyboard is back with the app it belongs to.
        close()
        if let deliverOverride {
            deliverOverride(output)
            return
        }
        let outcome = Paster.deliver(output, into: origin)
        history.add(output, app: origin?.localizedName, pasted: outcome == .pasted)
        if case .clipboardOnly(let reason) = outcome {
            Log.note(reason)
            phase = .clipboard
            onOpen()
            closeLater(after: .seconds(3))
        }
    }

    // MARK: - Sending

    private func send(_ id: Int) {
        guard var segment = segments[id], segment.audio.count > segment.transcribed || segment.failure != nil,
              !segment.audio.isEmpty else { return }
        sends[id]?.cancel()
        segment.failure = nil
        segments[id] = segment

        let audio = segment.audio
        let covered = audio.count
        let settings = preferences.transcriberSettings
        let rules = preferences.replacements
        let provider = preferences.provider
        let token = sessionToken
        inFlight.insert(id)
        let started = Date()

        sends[id] = Task {
            let result: Result<String, Error>
            if let key = Secrets.read(for: provider), !key.isEmpty {
                let wav = await Task.detached { WAVEncoder.encode(samples: audio, sampleRate: 16_000) }.value
                do {
                    result = .success(try await Transcriber(settings: settings).transcribe(wav: wav, apiKey: key))
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(Transcriber.Failure.noKey)
            }
            guard !Task.isCancelled, token == sessionToken else { return }
            inFlight.remove(id)
            sends[id] = nil
            Log.note(String(format: "sent %.1f s of audio, answer after %.1f s", Double(covered) / 16_000, Date().timeIntervalSince(started)))
            switch result {
            case .success(let raw):
                apply(Replacements.apply(rules, to: raw), to: id, covering: covered)
            case .failure(let error):
                Log.note("transcription failed: \(error.localizedDescription)")
                // Kept: the final send at the shortcut tries it again.
                segments[id]?.failure = (error as? Transcriber.Failure)?.short ?? "Fehler"
            }
        }
    }

    /// Puts a recording's text where it belongs: over its previous text, or at
    /// its placeholder.
    private func apply(_ transcript: String, to id: Int, covering count: Int) {
        guard var segment = segments[id] else { return }
        let target: NSRange
        if let existing = segmentRange(id) {
            target = existing
        } else if let marker = markerRange(id) {
            target = NSRange(location: marker.location, length: 0)
        } else {
            target = NSRange(location: text.length, length: 0)
        }
        let marker = markerRange(id)
        let skip = marker.map { $0.location == NSMaxRange(target) ? $0.length : 0 } ?? 0
        let piece = TextFitting.fit(transcript, into: text.string as NSString, at: target, skipping: skip)
        var attributes = Self.textAttributes
        attributes[.satzSegment] = id
        edit { text.replaceCharacters(in: target, with: NSAttributedString(string: piece, attributes: attributes)) }
        segment.transcribed = count
        segments[id] = segment
        removeMarkerIfDone(id)
    }

    // MARK: - Segments

    private func newSegment(at location: Int) -> Int {
        let location = min(max(0, location), text.length)
        // A new spot inside another recording's text splits it, so that text
        // stops being replaceable as a whole.
        for id in segments.keys where isStrictlyInside(location, segment: id) {
            freeze(id)
        }
        let id = nextID
        nextID += 1
        segments[id] = Segment()
        edit { text.insert(Self.marker(for: id), at: location) }
        return id
    }

    /// The user edited this recording's text by hand, so a fresh transcript
    /// can no longer replace it. Its text becomes plain text; only the audio
    /// not yet transcribed is still sent, and lands at the placeholder.
    private func freeze(_ id: Int) {
        guard var segment = segments[id] else { return }
        if let range = segmentRange(id) {
            edit { text.removeAttribute(.satzSegment, range: range) }
        }
        segment.audio = Array(segment.audio.dropFirst(segment.transcribed))
        segment.transcribed = 0
        segments[id] = segment
        if sends[id] != nil {
            sends[id]?.cancel()
            sends[id] = nil
            inFlight.remove(id)
            if !(id == activeID && phase == .listening) { send(id) }
        }
    }

    private func append(_ samples: [Float], to id: Int) {
        guard !samples.isEmpty, segments[id] != nil else { return }
        segments[id]?.audio.append(contentsOf: samples)
    }

    private func removeMarkerIfDone(_ id: Int) {
        guard id != activeID, let segment = segments[id], segment.audio.count == segment.transcribed,
              let marker = markerRange(id) else { return }
        edit { text.deleteCharacters(in: marker) }
    }

    // MARK: - Text queries

    private func markerRange(_ id: Int) -> NSRange? {
        var found: NSRange?
        text.enumerateAttribute(.satzMarker, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            if value as? Int == id {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    private func segmentRange(_ id: Int) -> NSRange? {
        var found: NSRange?
        text.enumerateAttribute(.satzSegment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value as? Int == id else { return }
            found = found.map { NSUnionRange($0, range) } ?? range
        }
        return found
    }

    private func isAtMarker(_ location: Int, of id: Int) -> Bool {
        guard let marker = markerRange(id) else { return false }
        return location >= marker.location && location <= NSMaxRange(marker)
    }

    private func isStrictlyInside(_ location: Int, segment id: Int) -> Bool {
        guard let range = segmentRange(id) else { return false }
        return location > range.location && location < NSMaxRange(range)
    }

    /// Whether an edit at `range` changes this recording's text or lands
    /// between that text and its placeholder.
    private func touches(_ range: NSRange, segment id: Int) -> Bool {
        guard let textRange = segmentRange(id) else { return false }
        var region = textRange
        if let marker = markerRange(id) { region = NSUnionRange(region, marker) }
        if range.length > 0 {
            return NSIntersectionRange(range, textRange).length > 0
        }
        return range.location > region.location && range.location < NSMaxRange(region)
    }

    private func containsMarker(_ range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        var found = false
        text.enumerateAttribute(.satzMarker, in: range) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// The text as it will be pasted: everything but the placeholders.
    func plainText() -> String {
        var output = ""
        text.enumerateAttribute(.satzMarker, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value == nil { output += (text.string as NSString).substring(with: range) }
        }
        return output
    }

    // MARK: - Housekeeping

    private func edit(_ change: () -> Void) {
        isEditing = true
        text.beginEditing()
        change()
        text.endEditing()
        isEditing = false
        textVersion += 1
    }

    private func push(_ level: Float) {
        guard phase == .listening else { return }
        levels.removeFirst()
        levels.append(level)
    }

    private func stopEverything() {
        sessionToken += 1
        startToken += 1
        recorder?.cancel()
        recorder = nil
        for task in sends.values { task.cancel() }
        sends = [:]
        inFlight = []
        tails = []
        finishing?.cancel()
        finishing = nil
        releaseEscape()
        levels = Array(repeating: 0, count: levels.count)
    }

    private func reset() {
        edit { text.setAttributedString(NSAttributedString()) }
        segments = [:]
        activeID = nil
        caret = nil
        liveStart = 0
    }

    private func close() {
        closingLater?.cancel()
        stopEverything()
        reset()
        origin = nil
        phase = .idle
        onClose()
    }

    private func closeLater(after delay: Duration) {
        closingLater?.cancel()
        let shown = phase
        closingLater = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, phase == shown else { return }
            // A discarded text stays in the menu bar under "Zuletzt verworfen".
            close()
        }
    }

    // MARK: - Escape

    private func holdEscape() {
        guard escape == nil else { return }
        escape = try? HotKey(.escape, onPress: { [weak self] in self?.discard() })
    }

    private func releaseEscape() {
        escape = nil
    }

    // MARK: - Fixtures

    /// Puts the card into a fixed state, for snapshots.
    func stage(_ phase: Phase, text staged: String = "", marker: Bool = false, levels levelValues: [Float] = []) {
        edit {
            text.setAttributedString(NSAttributedString(string: staged, attributes: Self.textAttributes))
            if marker { text.append(Self.marker(for: 1)) }
        }
        self.phase = phase
        for (index, level) in zip(levels.indices, levelValues) {
            levels[index] = level
        }
    }

    // MARK: - Styling

    /// The card's text: Source Sans on petrol, the same in light and dark mode.
    static var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.12
        return [
            .font: NSFont(name: "SourceSans3-Roman_Regular", size: 15) ?? .systemFont(ofSize: 15),
            .foregroundColor: NSColor(Theme.dark.ink),
            .paragraphStyle: paragraph,
        ]
    }

    static func marker(for id: Int) -> NSAttributedString {
        var attributes = textAttributes
        attributes[.foregroundColor] = NSColor(Theme.dark.accent)
        attributes[.satzMarker] = id
        // With a space of its own, so it never sticks to the text before it.
        return NSAttributedString(string: " …", attributes: attributes)
    }

    /// The app the user is working in, never satz itself.
    static func frontmostOtherApp() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        return front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
    }
}

extension Transcriber.Failure {
    /// Two or three words, for the card and the menu.
    var short: String {
        switch self {
        case .noKey: "Kein Schlüssel"
        case .unauthorized: "Schlüssel abgelehnt"
        case .rateLimited: "Anbieter drosselt"
        case .offline: "Keine Verbindung"
        case .timedOut: "Zeitüberschreitung"
        case .server: "Fehler beim Anbieter"
        case .unreadableResponse: "Antwort unlesbar"
        }
    }
}
