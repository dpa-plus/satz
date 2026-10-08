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
    /// Enough history to fill the full card's waveform; the pill shows the end.
    private(set) var levels = Array(repeating: Float(0), count: 32)
    /// Recordings on their way to the provider.
    private(set) var inFlight: Set<Int> = []
    /// Changes whenever the text does, so the card re-measures.
    private(set) var textVersion = 0
    /// Counts only satz's own changes to the text, not the user's typing.
    @ObservationIgnored private(set) var satzEdits = 0

    /// Text or at least a placeholder to show.
    var hasText: Bool {
        _ = textVersion
        return text.length > 0
    }

    /// Text that is more than placeholders.
    var hasRealText: Bool {
        _ = textVersion
        return !plainText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Anything a closing card would throw away: text, audio, a microphone
    /// still in its tail, or an answer still on its way.
    private var hasWork: Bool {
        hasRealText || segments.values.contains { !$0.audio.isEmpty } || !stopping.isEmpty || !sends.isEmpty
    }

    /// The card's text. Changed by the user in the text view, by satz in `edit`.
    @ObservationIgnored let text = NSTextStorage()
    /// Where the user last put the caret, nil until they do.
    @ObservationIgnored private(set) var caret: Int?
    /// True while satz edits `text`, so the text view does not take it for the user.
    @ObservationIgnored private(set) var isEditing = false

    @ObservationIgnored var onOpen: () -> Void = {}
    /// The microphone starts: a new dictation, or more after a pause. The card
    /// also opens for messages, which are not a reason to pause the music.
    @ObservationIgnored var onRecord: () -> Void = {}
    /// Test mode: receives the finished text instead of it being pasted.
    @ObservationIgnored var deliverOverride: ((String) -> Void)?
    @ObservationIgnored var onClose: () -> Void = {}
    /// Escape discards while recording; off for a test copy.
    @ObservationIgnored var takesEscape = true

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
    /// How much audio each running send carries, so the same bytes are not
    /// uploaded twice.
    @ObservationIgnored private var sendCovers: [Int: Int] = [:]
    /// Recordings whose last stretch is still in the microphone's tail.
    @ObservationIgnored private var tailing: Set<Int> = []
    /// Stopping the microphone keeps it open for a short tail; these are those.
    @ObservationIgnored private var tails: [Task<Void, Never>] = []
    /// Microphones that are stopping but have not handed over their audio
    /// yet, so a discard in that moment can still keep what they hold.
    @ObservationIgnored private var stopping: [Held] = []

    /// Audio still in a microphone that belongs to a recording.
    private struct Held {
        let id: Int
        let recorder: AudioSource
        let start: Int
        /// Where a new microphone took over, when the user went on talking
        /// before this one's tail was over.
        var end: Int?
    }
    @ObservationIgnored private var finishing: Task<Void, Never>?
    @ObservationIgnored private var closingLater: Task<Void, Never>?
    /// Bumped whenever the whole session is thrown away, so late answers drop.
    @ObservationIgnored private var sessionToken = 0
    /// Bumped by every microphone start, so a start that resolves late drops.
    @ObservationIgnored private var startToken = 0
    /// The shortcut was pressed to finish while the microphone was still opening.
    @ObservationIgnored private var finishWhenOpen = false
    /// The shortcut was pressed while the last dictation was being written.
    @ObservationIgnored private var startWhenDone = false
    /// Set by the app, for Escape while the menu bar panel is open.
    @ObservationIgnored var menuIsOpen: () -> Bool = { false }
    @ObservationIgnored var closeMenu: () -> Void = {}
    @ObservationIgnored private var origin: NSRunningApplication?
    @ObservationIgnored private var escape: HotKey?
    @ObservationIgnored private var breathing: Task<Void, Never>?

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
        case (.tap, .listening), (.tap, .paused): finish()
        // Pressed again while the microphone is still opening (a slow
        // Bluetooth headset takes a second): kept, and done once it is open.
        // Ignored, the dictation ran on until the next press.
        case (.tap, .starting): finishWhenOpen = true
        case (_, .failed(_, let canRetry)):
            // Nothing kept to send ("Kein Schlüssel", "Nichts gehört"): the
            // shortcut starts over instead of failing the same way again.
            // Text on the card counts: starting over wiped it, hand
            // corrections and all, after a microphone failed on resume.
            if canRetry || hasWork { finish() } else { begin() }
        // The next dictation, started while this one is still being written:
        // it begins as soon as this one is out. Ignored, the words said
        // meanwhile were never recorded.
        case (.tap, .finishing): startWhenDone.toggle()
        case (.hold, .paused): resume()
        default: break
        }
    }

    /// The shortcut came up. Only meaningful while holding to talk.
    func release() {
        guard preferences.triggerMode == .hold else { return }
        switch phase {
        case .listening: finish()
        // Let go before the microphone even opened: nothing was said. With
        // earlier text in the card, that text stays, paused; closing threw
        // the whole dictation away.
        case .starting:
            if hasRealText || segments.values.contains(where: { !$0.audio.isEmpty }) || !stopping.isEmpty {
                startToken += 1
                releaseEscape()
                phase = .paused
            } else {
                close()
            }
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
        // What was said is kept too, also the part still in the microphone:
        // while listening, everything since the last pause is only there.
        var kept = segments.mapValues { segment in
            var kept = segment
            kept.failure = nil
            return kept
        }
        var held = stopping
        if let recorder, let activeID { held.append(Held(id: activeID, recorder: recorder, start: liveStart)) }
        for piece in held where kept[piece.id] != nil {
            kept[piece.id]?.audio += piece.recorder.samples(from: piece.start, to: piece.end ?? piece.recorder.sampleCount)
        }
        let snapshot = Discarded.Snapshot(
            text: NSAttributedString(attributedString: text),
            segments: kept,
            activeID: activeID,
            nextID: nextID,
            origin: origin,
            preview: plainText()
        )
        Log.note("discarded while \(phase)")
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
        restore(snapshot, keepingOrigin: true)
    }

    /// Whether a discarded dictation can come back now: not over one that is
    /// still going.
    var canRestore: Bool {
        phase == .idle || phase == .discarded || phase == .clipboard
    }

    /// Brings a discarded dictation back, paused, from the card or the menu.
    /// - Parameter keepingOrigin: the card's own Undo goes back to where it
    ///   was started; "Zurückholen" from the menu pastes where the user is now.
    func restore(_ snapshot: Discarded.Snapshot, keepingOrigin: Bool = false) {
        guard canRestore else { return }
        closingLater?.cancel()
        stopEverything()
        reset()
        edit { text.setAttributedString(snapshot.text) }
        segments = snapshot.segments
        activeID = snapshot.activeID
        nextID = snapshot.nextID
        origin = keepingOrigin ? snapshot.origin ?? Self.frontmostOtherApp() : Self.frontmostOtherApp() ?? snapshot.origin
        if let activeID, markerRange(activeID) == nil {
            self.activeID = newSegment(at: text.length)
        }
        phase = .paused
        onOpen()
        breathe()
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

    /// The user moved the caret. A click while listening moves the insertion
    /// point: what was said so far goes where it was meant, the rest goes
    /// here. Any move counts for where to go on after a pause.
    func userMovedCaret(to location: Int, byClick: Bool = true) {
        caret = location
        guard byClick, phase == .listening, let recorder, let id = activeID, !isAtMarker(location, of: id) else { return }
        let end = recorder.sampleCount
        append(recorder.samples(from: liveStart, to: end), to: id)
        liveStart = end
        activeID = newSegment(at: location)
        caret = nil
        send(id)
        // Two clicks inside one audio buffer leave nothing to send.
        removeMarkerIfDone(id)
    }

    /// The user is about to change `range`. False refuses the change.
    func userWillEdit(_ range: NSRange) -> Bool {
        switch phase {
        case .finishing, .discarded, .clipboard, .idle: return false
        default: break
        }
        // The placeholders are satz's, not part of the text, and typing
        // inside one would split it in two.
        guard !containsMarker(range), !isInsideMarker(range.location) else { return false }
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
        // Checked before recording: finding out there is no key, or no model,
        // once you have finished speaking loses the whole message.
        if let missing = missingForProvider() {
            phase = .failed(missing, canRetry: false)
            onOpen()
            closeLater(after: .seconds(5))
            return
        }
        // Whisper takes seconds to load; it does that while you speak.
        if !preferences.provider.needsKey {
            LocalModels.shared.warmUp(preferences.model, language: preferences.spokenLanguage)
        }
        guard !preferences.isEndpointMissing else {
            phase = .failed(de("Adresse fehlt", en: "Address missing"), canRetry: false)
            onOpen()
            closeLater(after: .seconds(5))
            return
        }
        activeID = newSegment(at: 0)
        Log.note("dictation started, for \(origin?.localizedName ?? "?")")
        onOpen()
        breathe()
        startRecording()
    }

    /// What keeps the provider from working, in two or three words.
    private func missingForProvider() -> String? {
        let provider = preferences.provider
        if provider.needsKey {
            return Secrets.exists(for: provider) ? nil : Transcriber.Failure.noKey.short
        }
        switch LocalModels.shared.state(of: preferences.model, language: preferences.spokenLanguage) {
        case .ready: return nil
        case .downloading, .preparing: return de("Modell lädt noch", en: "Model still loading")
        default: return de("Modell fehlt", en: "Model missing")
        }
    }

    private func startRecording() {
        startToken += 1
        let mine = startToken
        finishWhenOpen = false
        phase = .starting
        onRecord()
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
                // Anything worth keeping stays, so the card stays for the
                // shortcut or ×; text still on its way arrives on it.
                if !hasWork { closeLater(after: .seconds(5)) }
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
            // A microphone still in its tail from a pause stops counting here,
            // or the moment both were open would be in the text twice.
            for index in stopping.indices where stopping[index].end == nil {
                stopping[index].end = stopping[index].recorder.sampleCount
            }
            phase = .listening
            if finishWhenOpen {
                finishWhenOpen = false
                finish()
            }
        }
    }

    private func pause() {
        guard phase == .listening, let recorder, let id = activeID else { return }
        self.recorder = nil
        phase = .paused
        releaseEscape()
        levels = Array(repeating: 0, count: levels.count)
        let start = liveStart
        let token = sessionToken
        tailing.insert(id)
        stopping.append(Held(id: id, recorder: recorder, start: start))
        tails.append(Task {
            // The tail keeps the last word.
            let samples = await recorder.finishSamples() ?? []
            guard token == sessionToken else { return }
            let end = stopping.first { $0.recorder === recorder }?.end ?? samples.count
            stopping.removeAll { $0.recorder === recorder }
            tailing.remove(id)
            append(Array(samples[min(start, end, samples.count) ..< min(end, samples.count)]), to: id)
            send(id)
            removeMarkerIfDone(id)
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
        if let recorder, let id { stopping.append(Held(id: id, recorder: recorder, start: start)) }

        finishing = Task {
            for tail in pending { await tail.value }
            if let recorder, let id {
                let samples = await recorder.finishSamples() ?? []
                guard token == sessionToken else { return }
                stopping.removeAll { $0.recorder === recorder }
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
        // Read before close() resets it.
        let startNext = startWhenDone
        defer { if startNext { begin() } }
        // Spaces only: a line break at either end was said ("neue Zeile"),
        // and a list dictated item by item needs it.
        let output = plainText().trimmingCharacters(in: .whitespaces)
        guard !output.isEmpty else {
            let seconds = Double(segments.values.map(\.audio.count).reduce(0, +)) / 16_000
            Log.note(String(format: "nothing heard in %.1f s of audio", seconds))
            reset()
            phase = .failed(de("Nichts gehört", en: "Nothing heard"), canRetry: false)
            closeLater(after: .seconds(3))
            return
        }
        let origin = self.origin
        // The card had the keyboard if the user clicked into its text.
        let cardHadKeyboard = NSApp.keyWindow != nil
        // Gone before pasting, so the keyboard is back with the app it belongs to.
        close()
        if let deliverOverride {
            deliverOverride(output)
            // Test mode keeps its own history file, so this never reaches the user's.
            history.add(output, app: origin?.localizedName, pasted: true)
            return
        }
        guard cardHadKeyboard else {
            paste(output, into: origin)
            return
        }
        // The keyboard has to get back to the other app before ⌘V, or the
        // keystroke lands nowhere and the clipboard is then restored over it.
        origin?.activate()
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            paste(output, into: origin)
        }
    }

    private func paste(_ output: String, into origin: NSRunningApplication?) {
        // Which app is in front at the moment of ⌘V tells whether a paste
        // that did not arrive went to the wrong place or nowhere. Never the text.
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let outcome = Paster.deliver(output, into: origin, keepsOnClipboard: preferences.keepsOnClipboard)
        Log.note("paste: \(outcome == .pasted ? "sent ⌘V" : "clipboard only") into \(origin?.localizedName ?? "?"), front was \(front), \(output.count) characters")
        history.add(output, app: origin?.localizedName, pasted: outcome == .pasted)
        if case .clipboardOnly(let reason) = outcome {
            Log.note(reason)
            // A new dictation started in the moment before: it stays.
            guard phase == .idle else { return }
            phase = .clipboard
            onOpen()
            closeLater(after: .seconds(3))
        }
    }

    // MARK: - Sending

    private func send(_ id: Int) {
        guard var segment = segments[id], segment.audio.count > segment.transcribed || segment.failure != nil,
              !segment.audio.isEmpty else { return }
        // Already on its way with exactly this audio: let it arrive.
        if sends[id] != nil, sendCovers[id] == segment.audio.count, segment.failure == nil { return }
        sends[id]?.cancel()
        segment.failure = nil
        segments[id] = segment

        let audio = segment.audio
        let covered = audio.count
        let settings = preferences.transcriberSettings
        let rules = preferences.activeReplacements
        let provider = preferences.provider
        let model = preferences.model
        let spoken = preferences.spokenLanguage
        let token = sessionToken
        inFlight.insert(id)
        sendCovers[id] = covered
        let started = Date()

        sends[id] = Task {
            let result: Result<String, Error>
            if !provider.needsKey {
                do {
                    result = .success(try await LocalModels.shared.transcribe(audio, model: model, language: spoken, vocabulary: settings.vocabulary))
                } catch {
                    result = .failure(error)
                }
            } else if let key = Secrets.read(for: provider), !key.isEmpty {
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
            sendCovers[id] = nil
            Log.note(String(format: "sent %.1f s of audio, answer after %.1f s", Double(covered) / 16_000, Date().timeIntervalSince(started)))
            switch result {
            case .success(let raw):
                let transcript = Replacements.apply(rules, to: raw)
                // Nothing back for audio with speech in it is a failure, not
                // silence: applied, it wiped the text this spot already had,
                // and "Nichts gehört" then threw the audio away.
                if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, SpeechGate.hasSpeech(audio) {
                    Log.note(String(format: "empty answer for %.1f s of speech, kept for another try", Double(covered) / 16_000))
                    segments[id]?.failure = de("Nichts verstanden", en: "Not understood")
                } else {
                    apply(transcript, to: id, covering: covered)
                }
            case .failure(let error):
                Log.note("transcription failed: \(error.localizedDescription)")
                // Kept: the final send at the shortcut tries it again.
                // Said as precisely as it is known: a bare "Fehler" left the
                // user retrying something that could not work.
                segments[id]?.failure = (error as? Transcriber.Failure)?.short ?? (error as? LocalModels.Failure)?.short
                    ?? (provider.needsKey ? de("Fehler", en: "Error") : de("Modell-Fehler", en: "Model error"))
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
        moveCaret(replacing: target, with: (piece as NSString).length)
        segment.transcribed = count
        segments[id] = segment
        removeMarkerIfDone(id)
        fadeIn(id)
    }

    /// New text arrives in the accent colour and settles into the text colour
    /// over a third of a second, instead of popping in.
    private func fadeIn(_ id: Int) {
        let token = sessionToken
        Task {
            let from = NSColor(Theme.dark.accent), to = NSColor(Theme.dark.ink)
            for step in 0 ... 8 {
                guard token == sessionToken, let range = segmentRange(id) else { return }
                let color = from.blended(withFraction: CGFloat(step) / 8, of: to) ?? to
                text.addAttribute(.foregroundColor, value: color, range: range)
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    /// The "…" placeholders breathe while the card is open, so it reads as
    /// working rather than stuck.
    private func breathe() {
        guard breathing == nil else { return }
        breathing = Task {
            var bright = true
            while !Task.isCancelled, phase != .idle {
                bright.toggle()
                let color = NSColor(Theme.dark.accent).withAlphaComponent(bright ? 1 : 0.35)
                text.enumerateAttribute(.satzMarker, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                    if value != nil { text.addAttribute(.foregroundColor, value: color, range: range) }
                }
                try? await Task.sleep(for: .milliseconds(600))
            }
            breathing = nil
        }
    }

    // MARK: - Segments

    private func newSegment(at location: Int) -> Int {
        var location = wordEdge(near: min(max(0, location), text.length))
        // Never inside another placeholder: right after it instead.
        if let marker = markerContaining(location) { location = NSMaxRange(marker) }
        // A new spot inside another recording's text splits it, so that text
        // stops being replaceable as a whole.
        for id in segments.keys where isStrictlyInside(location, segment: id) {
            freeze(id)
        }
        let id = nextID
        nextID += 1
        segments[id] = Segment()
        let marker = Self.marker(for: id)
        edit { text.insert(marker, at: location) }
        moveCaret(replacing: NSRange(location: location, length: 0), with: marker.length)
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
            sendCovers[id] = nil
            inFlight.remove(id)
            if !(id == activeID && phase == .listening) { send(id) }
        }
    }

    private func append(_ samples: [Float], to id: Int) {
        guard !samples.isEmpty, segments[id] != nil else { return }
        segments[id]?.audio.append(contentsOf: samples)
    }

    private func removeMarkerIfDone(_ id: Int) {
        guard id != activeID, !tailing.contains(id), let segment = segments[id], segment.audio.count == segment.transcribed,
              let marker = markerRange(id) else { return }
        edit { text.deleteCharacters(in: marker) }
        moveCaret(replacing: marker, with: 0)
    }

    /// Keeps where the user put the caret on the same spot in the text while
    /// satz changes the text around it. Text arriving before it pushes it
    /// along; a click right after a pause, before the words came in, ended up
    /// in the middle of them.
    private func moveCaret(replacing range: NSRange, with length: Int) {
        guard let caret else { return }
        if caret >= NSMaxRange(range) {
            self.caret = caret + length - range.length
        } else if caret > range.location {
            // A click inside text that is being replaced stays where it was:
            // moved to the end, it landed on the recording's own placeholder
            // and the next words went there instead of to the click.
            self.caret = min(caret, range.location + length)
        }
    }

    // MARK: - Text queries

    /// A click lands between two letters as easily as between two words, and
    /// speech put there split the word: "Schrei … b". The nearer end of the
    /// word instead.
    private func wordEdge(near location: Int) -> Int {
        let string = text.string as NSString
        func isWordCharacter(_ index: Int) -> Bool {
            guard index >= 0, index < string.length, let scalar = Unicode.Scalar(string.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        guard isWordCharacter(location - 1), isWordCharacter(location) else { return location }
        var start = location
        while isWordCharacter(start - 1) { start -= 1 }
        var end = location
        while isWordCharacter(end) { end += 1 }
        return location - start <= end - location ? start : end
    }

    /// The placeholder where the next words will go, for the card to keep in view.
    var activeMarkerRange: NSRange? {
        activeID.flatMap(markerRange)
    }

    private func markerRange(_ id: Int) -> NSRange? {
        var found: NSRange?
        text.enumerateAttribute(.satzMarker, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value as? Int == id else { return }
            found = found.map { NSUnionRange($0, range) } ?? range
        }
        return found
    }

    /// The placeholder `location` falls strictly inside, if any.
    private func markerContaining(_ location: Int) -> NSRange? {
        guard location > 0, location < text.length,
              let id = text.attribute(.satzMarker, at: location, effectiveRange: nil) as? Int,
              let marker = markerRange(id), location > marker.location else { return nil }
        return marker
    }

    private func isInsideMarker(_ location: Int) -> Bool {
        markerContaining(location) != nil
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
        satzEdits += 1
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
        sendCovers = [:]
        inFlight = []
        tails = []
        tailing = []
        stopping = []
        finishing?.cancel()
        finishing = nil
        releaseEscape()
        levels = Array(repeating: 0, count: levels.count)
    }

    private func reset() {
        startWhenDone = false
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
            // An answer that arrived meanwhile stays on the card.
            if case .failed = phase, hasWork { return }
            // A discarded text stays in the menu bar under "Zuletzt verworfen".
            close()
        }
    }

    // MARK: - Escape

    private func holdEscape() {
        guard takesEscape, escape == nil else { return }
        // With satz's menu open, Escape closes the menu, as everywhere else.
        escape = try? HotKey(.escape, onPress: { [weak self] in
            if self?.menuIsOpen() == true { self?.closeMenu() } else { self?.discard() }
        })
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
        guard !levelValues.isEmpty else { return }
        for index in levels.indices {
            levels[index] = levelValues[index % levelValues.count]
        }
    }

    /// After another colour family is picked: the text already in the card
    /// takes the new colours too.
    func recolor() {
        let all = NSRange(location: 0, length: text.length)
        isEditing = true
        text.beginEditing()
        text.addAttribute(.foregroundColor, value: NSColor(Theme.dark.ink), range: all)
        text.enumerateAttribute(.satzMarker, in: all) { value, range, _ in
            if value != nil { text.addAttribute(.foregroundColor, value: NSColor(Theme.dark.accent), range: range) }
        }
        text.endEditing()
        isEditing = false
        textVersion += 1
    }

    // MARK: - Styling

    /// The card's text: Source Sans on petrol, the same in light and dark mode.
    static var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.1
        return [
            .font: NSFont(name: "SourceSans3-Roman_Regular", size: 14) ?? .systemFont(ofSize: 14),
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
        case .noKey: de("Kein Schlüssel", en: "No key")
        case .unauthorized: de("Schlüssel abgelehnt", en: "Key rejected")
        case .rateLimited: de("Anbieter drosselt", en: "Provider busy")
        case .offline: de("Keine Verbindung", en: "No connection")
        case .timedOut: de("Zeitüberschreitung", en: "Timed out")
        case .server: de("Fehler beim Anbieter", en: "Provider error")
        case .unreadableResponse: de("Antwort unlesbar", en: "Unreadable answer")
        }
    }
}
