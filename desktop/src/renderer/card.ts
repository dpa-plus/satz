import { satz } from './bridge'
import { lostError, recordFor } from './microphone'

/**
 * The card: text on top, under it one row with the waveform up to the
 * buttons at the right. The window around it is fixed; the card grows to the
 * left and upward inside it, so the buttons never move from under the mouse.
 */
type Phase = { kind: string; message?: string; canRetry?: boolean; canRestore?: boolean; cleaning?: boolean; reason?: string; lost?: boolean }
interface State {
  phase: Phase
  runs: { text: string; seg: number; mark: number }[]
  levels: number[]
  showsText: boolean
  hasRealText: boolean
  bright: boolean
  language: 'de' | 'en'
}

const $ = (id: string) => document.getElementById(id)!
const card = $('card'), text = $('text'), rule = $('rule'), middle = $('middle')
const mic = $('mic') as HTMLButtonElement, eye = $('eye') as HTMLButtonElement, close = $('close') as HTMLButtonElement
let state: State | null = null
let lastText = ''

const icons = {
  mic: '<svg viewBox="0 0 16 16"><path fill="currentColor" d="M8 1a2.5 2.5 0 0 0-2.5 2.5v4a2.5 2.5 0 0 0 5 0v-4A2.5 2.5 0 0 0 8 1Zm-4.5 6.5a.75.75 0 0 1 1.5 0 3 3 0 0 0 6 0 .75.75 0 0 1 1.5 0 4.5 4.5 0 0 1-3.75 4.44V14h1.75a.75.75 0 0 1 0 1.5h-5a.75.75 0 0 1 0-1.5h1.75v-2.06A4.5 4.5 0 0 1 3.5 7.5Z"/></svg>',
  pause: '<svg viewBox="0 0 16 16"><path fill="currentColor" d="M4 2.5h3v11H4zM9 2.5h3v11H9z"/></svg>',
  eye: '<svg viewBox="0 0 16 16"><path fill="none" stroke="currentColor" stroke-width="1.4" d="M1 8s2.5-5 7-5 7 5 7 5-2.5 5-7 5-7-5-7-5Z"/><circle cx="8" cy="8" r="2" fill="currentColor"/></svg>',
  eyeOff: '<svg viewBox="0 0 16 16"><path fill="none" stroke="currentColor" stroke-width="1.4" d="M1 8s2.5-5 7-5 7 5 7 5-2.5 5-7 5-7-5-7-5Z M2 14 14 2"/></svg>',
  close: '<svg viewBox="0 0 16 16"><path stroke="currentColor" stroke-width="2" stroke-linecap="round" d="m4 4 8 8M12 4l-8 8"/></svg>',
  warning: '<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" d="M8 2 14.5 13.5h-13Z"/><path stroke="currentColor" stroke-width="1.6" stroke-linecap="round" d="M8 6.5v3"/><circle cx="8" cy="11.6" r=".9" fill="currentColor"/></svg>',
}

const words = (de: string, en: string) => (state?.language === 'de' ? de : en)

function render() {
  if (!state) return
  const { phase } = state
  const k = phase.kind
  const canHoldText = !['idle', 'discarded', 'clipboard', 'notCleaned'].includes(k)
  const showsText = state.showsText && state.hasRealText && canHoldText
  // Paused because the microphone went away: a status to read, not a wave.
  const lost = k === 'paused' && phase.lost === true
  const statusOnly = !showsText && (lost || !['idle', 'starting', 'listening', 'paused'].includes(k))

  // For screen readers: the language the card speaks.
  document.documentElement.lang = state.language
  card.classList.toggle('hidden', k === 'idle')
  card.classList.toggle('pill', !showsText && !statusOnly)
  card.classList.toggle('status', statusOnly)
  text.classList.toggle('folded', !showsText)
  rule.classList.toggle('folded', !showsText)

  // The text, with the placeholders in the accent colour, breathing.
  const joined = state.runs.map(r => r.text).join('')
  // Drawn anew only when the text changed: every pulse of the placeholder
  // also wiped a selection in the text.
  if (joined === lastText) {
    text.querySelectorAll('.marker').forEach(marker => marker.classList.toggle('dim', !state!.bright))
  } else {
    const fresh = joined.length > lastText.length
    text.replaceChildren(...state.runs.map(run => {
      const span = document.createElement('span')
      span.textContent = run.text
      if (run.mark) span.className = 'marker' + (state!.bright ? '' : ' dim')
      else if (fresh && run.seg && !lastText.includes(run.text)) span.className = 'fresh'
      return span
    }))
    if (joined !== lastText && (k === 'listening' || k === 'paused')) {
      const marker = text.querySelector('.marker') as HTMLElement | null
      ;(marker ?? text.lastElementChild as HTMLElement | null)?.scrollIntoView({ block: 'nearest' })
    }
    lastText = joined
  }

  // Left of the buttons: the wave, or what is going on.
  middle.replaceChildren()
  const label = (s: string) => { const el = document.createElement('span'); el.textContent = s; middle.append(el) }
  if (lost) {
    // Recorded so far is kept; Weitersprechen opens the microphone there is now.
    const warning = document.createElement('span'); warning.className = 'warning'; warning.innerHTML = icons.warning
    middle.append(warning); label(words('Mikrofon getrennt', 'Microphone lost'))
  } else if (['idle', 'starting', 'listening', 'paused'].includes(k)) {
    if (k === 'paused') label(words('Pausiert', 'Paused'))
    const wave = document.createElement('div')
    wave.className = 'wave' + (k === 'listening' ? '' : ' dim')
    const levels = showsText ? state.levels : state.levels.slice(-12)
    for (const level of levels) {
      const bar = document.createElement('i')
      bar.style.height = `${2.5 + 13.5 * (k === 'listening' ? Math.max(0, Math.min(1, level)) : 0)}px`
      wave.append(bar)
    }
    middle.append(wave)
  } else if (k === 'finishing') {
    const dots = document.createElement('div'); dots.className = 'dots'; dots.innerHTML = '<i></i><i></i><i></i>'
    middle.append(dots); label(phase.cleaning ? words('Räumt auf', 'Cleaning up') : words('Schreibt', 'Writing'))
  } else if (k === 'failed') {
    label(phase.message ?? '')
    if (phase.canRetry) {
      const retry = document.createElement('button'); retry.className = 'action retry'; retry.textContent = words('Nochmal', 'Retry')
      retry.dataset.action = 'retry'; middle.append(retry)
    }
    // A delivery that failed kept the text: it comes back right here.
    if (phase.canRestore) {
      const restore = document.createElement('button'); restore.className = 'action'; restore.textContent = words('Zurückholen', 'Restore')
      restore.dataset.action = 'restore'; middle.append(restore)
    }
  } else if (k === 'discarded') {
    label(words('Verworfen', 'Discarded'))
    const undo = document.createElement('button'); undo.className = 'action'; undo.textContent = words('Rückgängig', 'Undo')
    undo.dataset.action = 'undo'; middle.append(undo)
  } else if (k === 'clipboard') {
    label(words('Auf der Zwischenablage · Strg+V', 'On the clipboard · Ctrl+V'))
  } else if (k === 'notCleaned') {
    // Pasted as it was said; why is in the history and the log.
    const warning = document.createElement('span'); warning.className = 'warning'; warning.innerHTML = icons.warning
    middle.append(warning); label(words('Nicht aufgeräumt', 'Not cleaned up'))
  }

  const listening = k === 'listening'
  mic.innerHTML = listening ? icons.pause : icons.mic
  mic.classList.toggle('on', listening)
  mic.disabled = !(listening || k === 'paused')
  mic.title = listening ? words('Pause', 'Pause') : words('Weitersprechen', 'Continue')
  eye.innerHTML = state.showsText ? icons.eye : icons.eyeOff
  eye.title = state.showsText ? words('Text ausblenden', 'Hide text') : words('Text zeigen', 'Show text')
  close.innerHTML = icons.close
  close.title = words('Verwerfen', 'Discard')
}

satz.on('card:state', (value: State) => { state = value; render() })

/*
 * Buttons act when the mouse button comes up, and dragging starts when the
 * mouse moves with the button held. The card's window never takes the
 * keyboard from the app the user is typing in, and on Windows such a window
 * never receives the press itself, only the release.
 */
let dragging = false
const actions: [HTMLElement, string][] = [[mic, 'mic'], [eye, 'eye'], [close, 'close']]
document.addEventListener('mouseup', event => {
  // The main button only: a right-click on × threw the dictation away.
  if (event.button !== 0) return
  if (dragging) {
    dragging = false
    satz.send('card:drag', 'end')
    return
  }
  const target = event.target as HTMLElement
  for (const [button, action] of actions) {
    if (button.contains(target) && !(button as HTMLButtonElement).disabled) { satz.send('card:button', action); return }
  }
  const inline = target.closest('[data-action]') as HTMLElement | null
  if (inline) satz.send('card:button', inline.dataset.action)
}, true)

// Clicks pass through everywhere but the card: the window checks the pointer
// against this outline, sent whenever the card changes size or moves.
let lastRect = ''
function reportRect() {
  const r = card.getBoundingClientRect()
  const rect = { x: Math.round(r.left), y: Math.round(r.top), width: Math.round(r.width), height: Math.round(r.height) }
  const key = JSON.stringify(rect)
  if (key !== lastRect) { lastRect = key; satz.send('card:rect', rect) }
}
new ResizeObserver(reportRect).observe(card)
card.addEventListener('mouseenter', () => satz.send('card:pointer-inside'))
card.addEventListener('transitionend', reportRect)
setInterval(reportRect, 250)

// A click in the text moves where the next words go.
text.addEventListener('mouseup', event => {
  const position = (document as any).caretPositionFromPoint?.(event.clientX, event.clientY)
  const range = position ? null : document.caretRangeFromPoint?.(event.clientX, event.clientY)
  const node: Node | null = position?.offsetNode ?? range?.startContainer ?? null
  const offset: number = position?.offset ?? range?.startOffset ?? 0
  if (!node) return
  let total = 0
  for (const span of Array.from(text.children)) {
    if (span.contains(node)) { satz.send('card:caret', total + (node.nodeType === Node.TEXT_NODE ? offset : 0)); return }
    total += span.textContent?.length ?? 0
  }
  satz.send('card:caret', total)
})

// The row is the handle; the window moves with the mouse and stops at the wall.
const strip = $('strip')
strip.addEventListener('mousemove', event => {
  if (!(event.buttons & 1)) {
    if (dragging) { dragging = false; satz.send('card:drag', 'end') }
    return
  }
  if (!dragging) {
    if ((event.target as HTMLElement).closest('button')) return
    dragging = true
    satz.send('card:drag', 'start')
  }
  satz.send('card:drag', 'move')
})

// MARK: - Microphone

const worklet = `
class Tap extends AudioWorkletProcessor {
  constructor() { super(); this.buffer = []; this.size = 0 }
  process(inputs) {
    const channel = inputs[0] && inputs[0][0]
    if (channel) { this.buffer.push(new Float32Array(channel)); this.size += channel.length }
    if (this.size >= 800) {
      const out = new Float32Array(this.size); let o = 0
      for (const b of this.buffer) { out.set(b, o); o += b.length }
      this.port.postMessage(out, [out.buffer]); this.buffer = []; this.size = 0
    }
    return true
  }
}
registerProcessor('satz-tap', Tap)`

recordFor(satz, {
  getUserMedia: () => navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false } }),
  async openTap(onChunk, onFailed, signal) {
    const context = new AudioContext({ sampleRate: 16_000 })
    const url = URL.createObjectURL(new Blob([worklet], { type: 'application/javascript' }))
    // resume() may wait indefinitely; a stopped start still has to close its context.
    let abort = () => {}
    const cancelled = new Promise<never>((_resolve, reject) => {
      abort = () => reject(lostError())
      if (signal?.aborted) abort()
      else signal?.addEventListener('abort', abort, { once: true })
    })
    try {
      await Promise.race([(async () => {
        await context.audioWorklet.addModule(url)
        if (signal?.aborted) throw lostError()
        // A newly opened context can need resuming; a stopped context must
        // never be accepted as a microphone that is hearing the user.
        if (context.state === 'suspended') await context.resume()
        if (context.state !== 'running') throw lostError()
      })(), cancelled])
    } catch (error) {
      context.close().catch(() => {})
      throw error
    } finally {
      signal?.removeEventListener('abort', abort)
      URL.revokeObjectURL(url)
    }
    const node = new AudioWorkletNode(context, 'satz-tap')
    node.port.onmessage = message => onChunk(message.data as Float32Array)
    // The audio system can end the context by itself (its device went away,
    // a render error): from then on no audio comes, though the track lives.
    let closing = false
    const failed = () => { if (!closing) onFailed() }
    context.onstatechange = () => { if (context.state !== 'running') failed() }
    context.addEventListener('error', failed)
    node.onprocessorerror = failed
    return {
      connect: stream => { context.createMediaStreamSource(stream).connect(node) },
      close: () => { closing = true; node.port.onmessage = null; context.close().catch(() => {}) },
    }
  },
}, error => {
  const name = (error as Error)?.name
  // In the card's language, never Chromium's English.
  return name === 'NotFoundError' || name === 'OverconstrainedError' ? words('Kein Mikrofon', 'No microphone')
    : name === 'NotAllowedError' || name === 'SecurityError' ? words('Mikrofon nicht erlaubt', 'Microphone not allowed')
    : name === 'NotReadableError' || name === 'AbortError' ? words('Mikrofon belegt', 'Microphone in use')
    : name === 'MicrophoneLost' ? words('Mikrofon getrennt', 'Microphone lost')
    : words('Mikrofon geht nicht', 'Microphone not working')
})

satz.send('card:ready')
