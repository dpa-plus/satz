import { de } from './language'
import { Doc, type Range } from './doc'
import { applyReplacements, type Replacement } from './replacements'
import { hasSpeech } from './speech'
import { fit } from './textFitting'
import { TranscriptionFailure } from './transcriber'

/**
 * One dictation, from the shortcut to the paste. A port of the Mac app's
 * Session.swift, including its fixes: audio still in the microphone survives a
 * discard, the caret follows satz's own edits, a quick hold-mode tap after a
 * pause keeps the text, the tail of a pause never doubles audio, speech never
 * lands inside a word.
 *
 * Audio is never cut automatically: each insertion spot is one recording, a
 * pause sends the recording so far, and finishing sends the whole of it again.
 */
export type Phase =
  | { kind: 'idle' }
  | { kind: 'starting' }
  | { kind: 'listening' }
  | { kind: 'paused' }
  /** `cleaning`: the text is with the cleanup model ("Räumt auf"). */
  | { kind: 'finishing'; cleaning?: boolean }
  /** `canRestore`: the text is kept as a snapshot and the card can bring it back (a delivery that threw). */
  | { kind: 'failed'; message: string; canRetry: boolean; canRestore?: boolean }
  | { kind: 'discarded' }
  | { kind: 'clipboard' }
  /** Pasted as it was said: the cleanup failed (the reason is in the history and the log). */
  | { kind: 'notCleaned'; reason: string }

/** What a dictation's cleanup did, for the history: the text before it, and "ok" or why it failed. */
export interface CleanupOutcome { original: string; outcome: string }

/** What records: the microphone, or a file in test mode. */
export interface AudioSource {
  start(): Promise<void>
  readonly sampleCount: number
  samples(from: number, to: number): Float32Array
  /** Stops after a short tail that keeps the last word; everything since start. */
  finishSamples(): Promise<Float32Array | null>
  cancel(): void
  onLevel?: (level: number) => void
}

export interface SessionDeps {
  makeSource(): AudioSource
  /** The transcript of 16 kHz mono samples. Throws TranscriptionFailure. */
  transcribe(samples: Float32Array): Promise<string>
  replacements(): Replacement[]
  /** What keeps the provider from working, in two or three words: no key,
   *  or a local model not downloaded yet. null when it is ready. */
  missing(): string | null
  endpointMissing(): boolean
  triggerMode(): 'tap' | 'hold'
  /** Pastes; false with a reason when the text only reached the clipboard. `cleanup` when cleanup was on. */
  deliver(text: string, cleanup?: CleanupOutcome): Promise<{ pasted: boolean; reason?: string }>
  /** Cleanup is on: the text goes to the cleanup model before it is pasted. */
  cleansText?(): boolean
  /** The cleaned text, or the original with the reason it stayed so ('ok' otherwise). Never throws. */
  cleanup?(text: string): Promise<{ text: string; outcome: 'ok' | string }>
  log?(message: string): void
  /** Sample rate of everything the sources produce. */
  sampleRate?: number
  /** Whether a recording has speech in it; core/speech.ts's gate unless a test (audio made of letters) gives its own. */
  hasSpeech?(samples: Float32Array): boolean
}

/** `futile`: asking again with this audio fails the same way (the provider's upload limit), so no Retry. */
interface Segment { audio: Float32Array; transcribed: number; failure?: string; futile?: boolean }
interface Held { id: number; source: AudioSource; start: number; end?: number }

export interface Snapshot {
  doc: Doc
  segments: Map<number, Segment>
  activeID: number | null
  nextID: number
  preview: string
}

const concat = (a: Float32Array, b: Float32Array) => {
  if (b.length === 0) return a
  const out = new Float32Array(a.length + b.length)
  out.set(a); out.set(b, a.length)
  return out
}

export const MARKER = ' …'

export class Session {
  phase: Phase = { kind: 'idle' }
  /** Enough history to fill the full card's waveform; the pill shows the end. */
  levels: number[] = new Array(32).fill(0)
  readonly doc = new Doc()
  /** The last dictation thrown away, for Rückgängig and the tray's restore. */
  discarded: Snapshot | null = null

  onChange: () => void = () => {}
  onOpen: () => void = () => {}
  /** The microphone starts: a new dictation, or more after a pause. The card
   *  also opens for messages, which are not a reason to pause the music. */
  onRecord: () => void = () => {}
  /** A dictation begins: where the text will go is noted now. */
  onBegin: () => void = () => {}
  onClose: () => void = () => {}

  private segments = new Map<number, Segment>()
  private activeID: number | null = null
  private nextID = 1
  private source: AudioSource | null = null
  private liveStart = 0
  private caret: number | null = null
  private sends = new Map<number, { promise: Promise<void>; covers: number; gen: number }>()
  private sendGen = 0
  private tailing = new Set<number>()
  private tails: Promise<void>[] = []
  private stopping: Held[] = []
  private sessionToken = 0
  private startToken = 0
  /**
   * Counts the dictations begun (and restored): a queued start belongs to the
   * delivery that read it and is dropped when another dictation began since.
   */
  private generation = 0
  /** The shortcut was pressed to finish while the microphone was still opening. */
  private finishWhenOpen = false
  /** The shortcut was pressed while the last dictation was being written. */
  private startWhenDone = false
  /** The shortcut is down now (hold to talk): a queued start waits for it. */
  private keyHeld = false
  private closeTimer: ReturnType<typeof setTimeout> | null = null
  private breathTimer: ReturnType<typeof setInterval> | null = null
  breathBright = true

  constructor(private deps: SessionDeps) {}

  private get rate() { return this.deps.sampleRate ?? 16_000 }
  private hears(samples: Float32Array) { return this.deps.hasSpeech ? this.deps.hasSpeech(samples) : hasSpeech(samples, this.rate) }
  private changed() { this.onChange() }
  private log(message: string) { this.deps.log?.(message) }

  // MARK: - State for the card

  get hasRealText() { return this.doc.plain().trim() !== '' }
  /** Anything a closing card would throw away: text, audio, a microphone in its tail, an answer on its way. */
  private get hasWork() {
    return this.hasRealText || [...this.segments.values()].some(s => s.audio.length > 0) || this.stopping.length > 0 || this.sends.size > 0
  }
  get inFlight() { return this.sends.size }
  get canRestore() {
    const p = this.phase
    return ['idle', 'discarded', 'clipboard', 'notCleaned'].includes(p.kind) || (p.kind === 'failed' && p.canRestore === true)
  }
  plainText() { return this.doc.plain() }

  // MARK: - Shortcut

  /** The shortcut went down. */
  press() {
    this.keyHeld = true
    const mode = this.deps.triggerMode(), p = this.phase
    if (p.kind === 'idle' || p.kind === 'discarded' || p.kind === 'clipboard' || p.kind === 'notCleaned') return this.begin()
    if (mode === 'tap' && (p.kind === 'listening' || p.kind === 'paused')) return this.finish()
    // Pressed again while the microphone is still opening (a slow Bluetooth
    // headset): kept, and done once it is open. Ignored, it ran on.
    if (mode === 'tap' && p.kind === 'starting') { this.finishWhenOpen = true; return }
    if (p.kind === 'failed') {
      // Nothing kept to send ("Kein Schlüssel", "Nichts gehört"): start over.
      // Text on the card counts: starting over wiped it after a microphone
      // failed on resume.
      if (p.canRetry || this.hasWork) return this.finish()
      return this.begin()
    }
    // The next dictation, started while this one is still being written: it
    // begins once this one is out. Ignored, the words said meanwhile were lost.
    // Holding to talk, the key is down when it is asked for, and release()
    // takes it back if the key comes up before this dictation is out.
    if (p.kind === 'finishing') { this.startWhenDone = mode === 'hold' ? true : !this.startWhenDone; return }
    if (mode === 'hold' && p.kind === 'paused') return this.resume()
  }

  /**
   * "satz --toggle" from a desktop shortcut (Wayland, or no keyboard hook):
   * start and finish like a tap, whatever the trigger mode. In hold mode a
   * press never finished, and the dictation could only be thrown away.
   */
  toggle() {
    const p = this.phase.kind
    if (p === 'listening' || p === 'paused') return this.finish()
    if (p === 'starting') { this.finishWhenOpen = true; return }
    if (p === 'finishing') { this.startWhenDone = !this.startWhenDone; return }
    if (p === 'failed') return this.press()
    this.begin()
  }

  /** The shortcut came up. Only meaningful while holding to talk. */
  release() {
    this.keyHeld = false
    if (this.deps.triggerMode() !== 'hold') return
    if (this.phase.kind === 'listening') return this.finish()
    // Let go before the last dictation was out: there is nothing to hold for,
    // and a recording started now would run on with the key up.
    if (this.phase.kind === 'finishing') { this.startWhenDone = false; return }
    if (this.phase.kind === 'starting') {
      // Let go before the microphone opened. Earlier text stays, paused.
      if (this.hasRealText || [...this.segments.values()].some(s => s.audio.length > 0) || this.stopping.length > 0) {
        this.startToken++
        this.phase = { kind: 'paused' }
        this.changed()
      } else {
        this.close()
      }
    }
  }

  // MARK: - Card buttons

  toggleMicrophone() {
    if (this.phase.kind === 'listening') this.pause()
    else if (this.phase.kind === 'paused') this.resume()
  }

  /** × and Escape. Recoverable: see undoDiscard and restore. */
  discard() {
    const p = this.phase.kind
    if (p === 'idle') return
    if (p === 'discarded' || p === 'clipboard' || p === 'notCleaned') return this.close()
    this.log(`discarded while ${p}`)
    // What was said is kept too, also the part still in the microphone.
    const kept = new Map<number, Segment>()
    for (const [id, s] of this.segments) kept.set(id, { audio: s.audio, transcribed: s.transcribed })
    const held = [...this.stopping]
    if (this.source && this.activeID) held.push({ id: this.activeID, source: this.source, start: this.liveStart })
    for (const piece of held) {
      const segment = kept.get(piece.id)
      if (segment) segment.audio = concat(segment.audio, piece.source.samples(piece.start, piece.end ?? piece.source.sampleCount))
    }
    const snapshot: Snapshot = { doc: this.doc.clone(), segments: kept, activeID: this.activeID, nextID: this.nextID, preview: this.doc.plain() }
    this.stopEverything()
    this.reset()
    const hasContent = snapshot.preview.trim() !== '' || [...kept.values()].some(s => s.audio.length > 0)
    if (!hasContent) return this.close()
    this.discarded = snapshot
    this.phase = { kind: 'discarded' }
    this.changed()
    this.closeLater(5000)
  }

  /** "Rückgängig", while the card says "Verworfen". */
  undoDiscard() {
    if (this.phase.kind !== 'discarded' || !this.discarded) return
    const snapshot = this.discarded
    this.discarded = null
    this.restore(snapshot)
  }

  /** The tray's restore: only takes the snapshot when it can come back. */
  restoreLast() {
    if (!this.canRestore || !this.discarded) return
    const snapshot = this.discarded
    this.discarded = null
    this.restore(snapshot)
  }

  restore(snapshot: Snapshot) {
    if (!this.canRestore) return
    this.generation++
    this.cancelClose()
    this.stopEverything()
    this.reset()
    this.doc.setFrom(snapshot.doc)
    this.segments = new Map(snapshot.segments)
    this.activeID = snapshot.activeID
    this.nextID = snapshot.nextID
    if (this.activeID && !this.doc.rangeOf('mark', this.activeID)) this.activeID = this.newSegment(this.doc.length)
    this.phase = { kind: 'paused' }
    this.onOpen()
    this.breathe()
    this.changed()
    // Anything that was on its way when it was thrown away goes again.
    for (const [id, s] of this.segments) if (s.audio.length > s.transcribed) this.send(id)
  }

  /** "Nochmal" after a failure. */
  retry() {
    if (this.phase.kind === 'failed' && this.phase.canRetry) this.finish()
  }

  // MARK: - Clicks in the text

  /** A click while listening moves where speech goes; any click counts for after a pause. */
  userMovedCaret(location: number) {
    this.caret = location
    if (this.phase.kind !== 'listening' || !this.source || !this.activeID || this.isAtMarker(location, this.activeID)) return
    const id = this.activeID
    const end = this.source.sampleCount
    this.append(this.source.samples(this.liveStart, end), id)
    this.liveStart = end
    this.activeID = this.newSegment(location)
    this.caret = null
    this.send(id)
    this.removeMarkerIfDone(id)
    this.changed()
  }

  // MARK: - Steps

  private begin() {
    this.generation++
    this.cancelClose()
    this.stopEverything()
    this.reset()
    // Checked before recording: finding out once you have finished speaking
    // loses the whole message.
    const missing = this.deps.missing()
    if (missing) {
      this.phase = { kind: 'failed', message: missing, canRetry: false }
      this.onOpen(); this.changed(); this.closeLater(5000)
      return
    }
    if (this.deps.endpointMissing()) {
      this.phase = { kind: 'failed', message: de('Adresse fehlt', 'Address missing'), canRetry: false }
      this.onOpen(); this.changed(); this.closeLater(5000)
      return
    }
    this.activeID = this.newSegment(0)
    this.log('dictation started')
    this.onBegin()
    this.onOpen()
    this.breathe()
    this.startRecording()
  }

  private startRecording() {
    const mine = ++this.startToken
    this.finishWhenOpen = false
    this.phase = { kind: 'starting' }
    this.onRecord()
    this.levels = this.levels.map(() => 0)
    this.changed()
    const source = this.deps.makeSource()
    source.onLevel = level => this.push(level)
    source.start().then(() => {
      // Thrown away while starting: close the microphone that just opened.
      if (mine !== this.startToken || this.phase.kind !== 'starting') { source.cancel(); return }
      this.source = source
      this.liveStart = 0
      // A microphone still in its tail from a pause stops counting here.
      for (const held of this.stopping) if (held.end === undefined) held.end = held.source.sampleCount
      this.phase = { kind: 'listening' }
      this.changed()
      if (this.finishWhenOpen) { this.finishWhenOpen = false; this.finish() }
    }, error => {
      if (mine !== this.startToken) return
      this.phase = { kind: 'failed', message: String((error as Error)?.message ?? error), canRetry: false }
      // Anything worth keeping stays for the shortcut or ×; an answer still
      // on its way arrives on it.
      if (!this.hasWork) this.closeLater(5000)
      this.changed()
    })
  }

  private pause() {
    const source = this.source, id = this.activeID
    if (this.phase.kind !== 'listening' || !source || !id) return
    this.source = null
    this.phase = { kind: 'paused' }
    this.levels = this.levels.map(() => 0)
    const start = this.liveStart, token = this.sessionToken
    this.tailing.add(id)
    const held: Held = { id, source, start }
    this.stopping.push(held)
    this.changed()
    this.tails.push((async () => {
      const samples = (await source.finishSamples()) ?? new Float32Array(0)
      if (token !== this.sessionToken) return
      const end = Math.min(held.end ?? samples.length, samples.length)
      this.stopping = this.stopping.filter(h => h !== held)
      this.tailing.delete(id)
      this.append(samples.subarray(Math.min(start, end), end), id)
      this.send(id)
      this.removeMarkerIfDone(id)
      this.changed()
    })())
  }

  private resume() {
    if (this.phase.kind !== 'paused') return
    if (this.caret !== null && this.activeID && !this.isAtMarker(this.caret, this.activeID)) {
      const old = this.activeID
      this.activeID = this.newSegment(this.caret)
      this.removeMarkerIfDone(old)
    } else if (!this.activeID || !this.doc.rangeOf('mark', this.activeID)) {
      this.activeID = this.newSegment(this.caret ?? this.doc.length)
    }
    this.caret = null
    this.startRecording()
  }

  private finish() {
    const p = this.phase.kind
    if (p !== 'listening' && p !== 'paused' && p !== 'failed') return
    this.phase = { kind: 'finishing' }
    this.changed()
    const source = this.source, id = this.activeID, start = this.liveStart, pending = this.tails, token = this.sessionToken
    this.source = null
    this.tails = []
    const held: Held | null = source && id ? { id, source, start } : null
    if (held) this.stopping.push(held)
    ;(async () => {
      for (const tail of pending) await tail
      if (held && source && id) {
        const samples = (await source.finishSamples()) ?? new Float32Array(0)
        if (token !== this.sessionToken) return
        this.stopping = this.stopping.filter(h => h !== held)
        this.append(samples.subarray(Math.min(start, samples.length)), id)
      }
      if (token !== this.sessionToken) return
      for (const [segmentID, s] of this.segments) if (s.audio.length > s.transcribed || s.failure) this.send(segmentID)
      while (this.sends.size > 0) {
        await [...this.sends.values()][0].promise
        if (token !== this.sessionToken) return
      }
      const failed = [...this.segments.values()].find(s => s.failure)
      if (failed) {
        this.phase = { kind: 'failed', message: failed.failure!, canRetry: !failed.futile }
        this.changed()
        return
      }
      await this.deliver()
    })()
  }

  private async deliver() {
    // Spaces only: a line break at either end was said ("neue Zeile").
    const output = this.doc.plain().replace(/^ +| +$/g, '')
    const token = this.sessionToken
    // Off, nothing waits: the text goes out as it always did.
    const cleaned = output !== '' && this.deps.cleanup && this.deps.cleansText?.() ? await this.cleanUp(output) : null
    // Thrown away while it was being cleaned up: the late answer is dropped,
    // and so is a start queued before (the shortcut after × is a new one).
    if (token !== this.sessionToken) return
    // Read after the cleanup, which the shortcut may have queued the next
    // dictation behind, and before close() resets it.
    const startNext = this.startWhenDone
    const generation = this.generation
    try {
      await this.deliverText(output, cleaned)
    } finally {
      // The card is gone while the text is pasted, so the next dictation may
      // already have been started by hand; starting the queued one now would
      // cancel its microphone and wipe what was said.
      // Holding to talk, a key let go while the text was pasted (the card
      // already closed, so release() could not take the start back) means
      // no new dictation: it would run on with the key up.
      if (startNext && generation === this.generation && (this.deps.triggerMode() !== 'hold' || this.keyHeld)) this.begin()
    }
  }

  /**
   * The text through the cleanup model, while the card says "Räumt auf".
   * The card behaves as while writing: × throws it away (and keeps the text
   * restorable), the shortcut queues the next dictation.
   */
  private async cleanUp(output: string): Promise<{ text: string; cleanup: CleanupOutcome }> {
    this.phase = { kind: 'finishing', cleaning: true }
    this.changed()
    let result: { text: string; outcome: string }
    try {
      result = await this.deps.cleanup!(output)
    } catch (error) {
      // Never lose the words: whatever went wrong, the original goes out.
      this.log(`cleanup failed: ${(error as Error)?.name ?? 'error'}`)
      result = { text: output, outcome: de('Anbieter-Fehler', 'Provider error') }
    }
    const text = result.outcome === 'ok' && result.text.trim() !== '' ? result.text : output
    return { text, cleanup: { original: output, outcome: result.outcome } }
  }

  private async deliverText(output: string, cleaned: { text: string; cleanup: CleanupOutcome } | null) {
    if (output === '') {
      const seconds = [...this.segments.values()].reduce((sum, s) => sum + s.audio.length, 0) / this.rate
      this.log(`nothing heard in ${seconds.toFixed(1)} s of audio`)
      this.reset()
      this.phase = { kind: 'failed', message: de('Nichts gehört', 'Nothing heard'), canRetry: false }
      this.changed()
      this.closeLater(3000)
      return
    }
    // Kept until it is out: a clipboard that refused the text lost the dictation.
    const snapshot: Snapshot = { doc: this.doc.clone(), segments: new Map(this.segments), activeID: this.activeID, nextID: this.nextID, preview: output }
    // Gone before pasting, so the keyboard is back with the app it belongs to.
    this.close()
    let outcome: { pasted: boolean; reason?: string }
    try {
      outcome = cleaned ? await this.deps.deliver(cleaned.text, cleaned.cleanup) : await this.deps.deliver(output)
    } catch (error) {
      this.log(`delivery failed: ${(error as Error)?.message ?? error}`)
      this.discarded = snapshot
      if (this.phase.kind !== 'idle') return
      // The text is safe in `discarded`: the card offers it back right here
      // (the tray's entry is there too), and closes like every other failure.
      this.phase = { kind: 'failed', message: de('Nicht eingefügt', 'Not pasted'), canRetry: false, canRestore: true }
      this.onOpen()
      this.changed()
      this.closeLater(5000)
      return
    }
    if (!outcome.pasted) {
      this.log(outcome.reason ?? 'clipboard only')
      // A new dictation started in the meantime: it stays.
      if (this.phase.kind !== 'idle') return
      // The text waiting on the clipboard matters more than why it was not cleaned up.
      this.phase = { kind: 'clipboard' }
      this.onOpen()
      this.changed()
      this.closeLater(4000)
      return
    }
    if (cleaned && cleaned.cleanup.outcome !== 'ok') {
      if (this.phase.kind !== 'idle') return
      this.phase = { kind: 'notCleaned', reason: cleaned.cleanup.outcome }
      this.onOpen()
      this.changed()
      this.closeLater(3000)
    }
  }

  // MARK: - Sending

  private send(id: number) {
    const segment = this.segments.get(id)
    if (!segment || segment.audio.length === 0 || !(segment.audio.length > segment.transcribed || segment.failure)) return
    const running = this.sends.get(id)
    // Already on its way with exactly this audio: let it arrive.
    if (running && running.covers === segment.audio.length && !segment.failure) return
    // Silence goes nowhere: a provider answers it with something made up
    // ("Vielen Dank."), and the room's sound is nobody else's business. It
    // counts as sent and said nothing, so a dictation of only silence ends in
    // "Nichts gehört" without a request.
    if (!this.hears(segment.audio)) {
      this.log(`no speech in ${(segment.audio.length / this.rate).toFixed(1)} s of audio, not sent`)
      segment.failure = undefined
      segment.futile = undefined
      this.apply('', id, segment.audio.length)
      this.changed()
      return
    }
    segment.failure = undefined
    segment.futile = undefined
    const audio = segment.audio, covered = audio.length, token = this.sessionToken, gen = ++this.sendGen
    const rules = this.deps.replacements()
    const started = Date.now()
    const promise = (async () => {
      let raw: string | null = null, failure: string | null = null, futile = false
      try {
        raw = await this.deps.transcribe(audio)
      } catch (error) {
        failure = error instanceof TranscriptionFailure ? error.short : de('Fehler', 'Error')
        futile = error instanceof TranscriptionFailure && error.kind === 'tooLarge'
        this.log(`transcription failed: ${(error as Error).message}`)
      }
      if (token !== this.sessionToken || this.sends.get(id)?.gen !== gen) return
      this.sends.delete(id)
      this.log(`sent ${(covered / this.rate).toFixed(1)} s of audio, answer after ${((Date.now() - started) / 1000).toFixed(1)} s`)
      if (raw !== null) {
        const transcript = applyReplacements(rules, raw)
        // Nothing back for audio with speech in it is a failure, not silence:
        // applied, it wiped this spot's text, and "Nichts gehört" then threw
        // the audio away.
        if (transcript.trim() === '' && this.hears(audio)) {
          this.log(`empty answer for ${(covered / this.rate).toFixed(1)} s of speech, kept for another try`)
          const s = this.segments.get(id); if (s) s.failure = de('Nichts verstanden', 'Not understood')
        } else this.apply(transcript, id, covered)
      } else { const s = this.segments.get(id); if (s) { s.failure = failure ?? undefined; s.futile = futile } }
      this.changed()
    })()
    this.sends.set(id, { promise, covers: covered, gen })
    this.changed()
  }

  /** A recording's text goes over its previous text, or at its placeholder. */
  private apply(transcript: string, id: number, count: number) {
    const segment = this.segments.get(id)
    if (!segment) return
    const existing = this.doc.rangeOf('seg', id)
    const marker = this.doc.rangeOf('mark', id)
    const target: Range = existing ?? (marker ? { location: marker.location, length: 0 } : { location: this.doc.length, length: 0 })
    const skip = marker && marker.location === target.location + target.length ? marker.length : 0
    const piece = fit(transcript, this.doc.text(), target, skip)
    this.doc.replace(target, piece, { seg: id })
    this.moveCaret(target, piece.length)
    segment.transcribed = count
    this.removeMarkerIfDone(id)
  }

  // MARK: - Segments

  private newSegment(at: number) {
    let location = this.wordEdge(Math.min(Math.max(0, at), this.doc.length))
    // Never inside another placeholder: right after it instead.
    const inside = this.markerContaining(location)
    if (inside) location = inside.location + inside.length
    // A new spot inside another recording's text splits it.
    for (const id of this.segments.keys()) if (this.isStrictlyInside(location, id)) this.freeze(id)
    const id = this.nextID++
    this.segments.set(id, { audio: new Float32Array(0), transcribed: 0 })
    this.doc.insert(location, MARKER, { mark: id })
    this.moveCaret({ location, length: 0 }, MARKER.length)
    return id
  }

  /** Its text becomes plain text; only audio not yet transcribed is still sent. */
  private freeze(id: number) {
    const segment = this.segments.get(id)
    if (!segment) return
    const range = this.doc.rangeOf('seg', id)
    if (range) this.doc.clearSeg(range)
    segment.audio = segment.audio.subarray(segment.transcribed)
    segment.transcribed = 0
    if (this.sends.has(id)) {
      this.sends.delete(id)
      if (!(id === this.activeID && this.phase.kind === 'listening')) this.send(id)
    }
  }

  private append(samples: Float32Array, id: number) {
    const segment = this.segments.get(id)
    if (samples.length === 0 || !segment) return
    segment.audio = concat(segment.audio, samples)
  }

  private removeMarkerIfDone(id: number) {
    const segment = this.segments.get(id)
    const marker = this.doc.rangeOf('mark', id)
    if (id === this.activeID || this.tailing.has(id) || !segment || segment.audio.length !== segment.transcribed || !marker) return
    this.doc.delete(marker)
    this.moveCaret(marker, 0)
  }

  /** Keeps the user's caret on the same spot while satz changes the text around it. */
  private moveCaret(range: Range, length: number) {
    if (this.caret === null) return
    if (this.caret >= range.location + range.length) this.caret += length - range.length
    // A click inside text being replaced stays where it was: moved to the end,
    // it landed on the recording's own placeholder.
    else if (this.caret > range.location) this.caret = Math.min(this.caret, range.location + length)
  }

  /** A click between two letters goes to the nearer end of the word. */
  private wordEdge(location: number) {
    const text = this.doc.text()
    const word = (i: number) => i >= 0 && i < text.length && /[\p{L}\p{N}]/u.test(text[i])
    if (!word(location - 1) || !word(location)) return location
    let start = location, end = location
    while (word(start - 1)) start--
    while (word(end)) end++
    return location - start <= end - location ? start : end
  }

  private markerContaining(location: number): Range | null {
    if (location <= 0 || location >= this.doc.length) return null
    const id = this.doc.markAt(location)
    if (!id) return null
    const marker = this.doc.rangeOf('mark', id)
    return marker && location > marker.location ? marker : null
  }

  private isAtMarker(location: number, id: number) {
    const marker = this.doc.rangeOf('mark', id)
    return !!marker && location >= marker.location && location <= marker.location + marker.length
  }

  private isStrictlyInside(location: number, id: number) {
    const range = this.doc.rangeOf('seg', id)
    return !!range && location > range.location && location < range.location + range.length
  }

  // MARK: - Housekeeping

  private push(level: number) {
    if (this.phase.kind !== 'listening') return
    this.levels = [...this.levels.slice(1), level]
    this.changed()
  }

  private breathe() {
    if (this.breathTimer) return
    this.breathTimer = setInterval(() => {
      if (this.phase.kind === 'idle') { clearInterval(this.breathTimer!); this.breathTimer = null; return }
      this.breathBright = !this.breathBright
      this.changed()
    }, 600)
  }

  private stopEverything() {
    this.sessionToken++
    this.startToken++
    this.source?.cancel()
    this.source = null
    this.sends.clear()
    this.tails = []
    this.tailing.clear()
    this.stopping = []
    this.levels = this.levels.map(() => 0)
  }

  private reset() {
    this.startWhenDone = false
    this.doc.clear()
    this.segments.clear()
    this.activeID = null
    this.caret = null
    this.liveStart = 0
  }

  private close() {
    this.cancelClose()
    this.stopEverything()
    this.reset()
    this.phase = { kind: 'idle' }
    this.changed()
    this.onClose()
  }

  private closeLater(ms: number) {
    this.cancelClose()
    const shown = this.phase.kind
    this.closeTimer = setTimeout(() => {
      this.closeTimer = null
      // An answer that arrived meanwhile stays on the card.
      if (this.phase.kind === 'failed' && this.hasWork) return
      if (this.phase.kind === shown) this.close()
    }, ms)
  }

  private cancelClose() {
    if (this.closeTimer) clearTimeout(this.closeTimer)
    this.closeTimer = null
  }

  /** Stops timers, for tests and quitting. */
  dispose() {
    this.cancelClose()
    if (this.breathTimer) clearInterval(this.breathTimer)
    this.breathTimer = null
    this.stopEverything()
  }
}
