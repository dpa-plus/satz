// Stands in for satz's main process, so the window's pages run in a plain
// browser: settings, history and the model menu with sample data. Changes
// stay in this page. Built by `node build.mjs --preview`; see preview/index.html.
// `?provider=local` opens with Local in use. Its cards: Turbo in use and
// measured, Parakeet V3 on the computer and measured, Whisper Small on it and
// never measured, Moonshine Base being measured; Large v3 downloading (it
// goes on to "getting ready", "measuring" and done, or Cancel stops it); the
// rest to download. Without it OpenRouter is in use (it has a key, the
// others none): pick another provider in the menu to see it without
// switching to it, or open with `?show=local` to start there.
// `&language=de` shows the German words, `&failed=1` a download that failed,
// `&model=sherpa/canary-180m` Canary as Local's model (with its "Spoken in"),
// `&fresh=1` nothing downloaded yet, `&slow=1` holds every state still for a picture.
import { germanErrors, localModelIds, type Speed } from '../src/core/localModels'
import { models as shipped } from '../src/core/models'
import { standardReplacements } from '../src/core/replacements'
import type { Provider } from '../src/core/transcriber'

const hour = 3600_000
const query = new URLSearchParams(location.search)
const asked = query.get('provider') as Provider | null
const language: 'de' | 'en' = query.get('language') === 'de' ? 'de' : 'en'
const prefs = {
  provider: (asked && asked in shipped ? asked : 'openrouter') as Provider, models: {} as Record<string, string>, customBaseURL: '', words: ['Kubernetes', 'Lena'], triggerMode: 'tap',
  language, spokenLanguage: null as 'de' | 'en' | null, toldLanguage: null as string | null, replacements: standardReplacements(language), usesReplacements: true,
  removesFillers: true, keepsOnClipboard: false, historyLimit: 50, pausesMedia: true,
}
let history = [
  { id: 'a', text: 'Thanks for the update. Thursday at two works for me, and I will bring the slides.', date: new Date(Date.now() - 0.1 * hour).toISOString(), pasted: true },
  { id: 'b', text: 'Write a function that reads every invoice in the Accounting folder and adds up the totals per customer.', date: new Date(Date.now() - 1 * hour).toISOString(), pasted: true },
  { id: 'c', text: 'Bitte schick mir die Unterlagen bis Freitag.', date: new Date(Date.now() - 3 * hour).toISOString(), pasted: false },
  { id: 'd', text: "The test is red, please don't merge yet.", date: new Date(Date.now() - 26 * hour).toISOString(), pasted: true },
]
const keys: Record<Provider, boolean> = { openrouter: true, openai: false, groq: false, custom: false, local: false }
const isProvider = (value: unknown): value is Provider => typeof value === 'string' && value in shipped

// The local models, as main.ts reports them.
type LocalState = { kind: string; fraction?: number; message?: string }
const machine = 'Intel(R) Core(TM) i7-1165G7 @ 2.80GHz, 8 cores'
const version = '0.4.1'
const measured = (secondsPer10: number): Speed => ({ secondsPer10, date: new Date().toISOString(), version, machine })
const local: Record<string, { state: LocalState; measuring: boolean; speed: Speed | null }> = {
  'onnx-community/whisper-large-v3-turbo': { state: { kind: 'ready' }, measuring: false, speed: measured(2.6) },
  'sherpa/parakeet-v3': { state: { kind: 'ready' }, measuring: false, speed: measured(0.35) },
  'onnx-community/whisper-small': { state: { kind: 'ready' }, measuring: false, speed: null },
  'sherpa/moonshine-base': { state: { kind: 'ready' }, measuring: true, speed: null },
  'sherpa/canary-180m': { state: { kind: query.get('model') === 'sherpa/canary-180m' ? 'ready' : 'missing' }, measuring: false, speed: measured(0.3) },
  'onnx-community/whisper-large-v3-ONNX': { state: { kind: 'downloading', fraction: 0.42 }, measuring: false, speed: null },
  'onnx-community/whisper-base': { state: query.has('failed') ? { kind: 'failed', message: 'fetch failed' } : { kind: 'missing' }, measuring: false, speed: null },
}
if (query.get('model')) prefs.models.local = query.get('model')!
if (query.has('fresh')) for (const key of Object.keys(local)) delete local[key]
/** Seconds per 10 s, about as an Intel laptop would measure them. */
const fakeSpeeds: [string, number][] = [['large-v3-ONNX', 5.4], ['medium', 2.3], ['base', 0.5], ['tiny', 0.3], ['distil', 2], ['moonshine', 0.2], ['parakeet', 0.4], ['sense', 0.15]]
const localModel = () => prefs.models.local || 'onnx-community/whisper-large-v3-turbo'
const entry = (id: string) => (local[id] ??= { state: { kind: 'missing' }, measuring: false, speed: null })
const timers = new Map<string, ReturnType<typeof setInterval>>()
/** What the real speed test leads to, a few seconds later. */
function fakeMeasure(id: string) {
  entry(id).measuring = true
  emit('local:changed')
  setTimeout(() => { Object.assign(entry(id), { measuring: false, speed: measured(fakeSpeeds.find(([part]) => id.includes(part))?.[1] ?? 0.5) }); emit('local:changed') }, 2500)
}
/** Counts up like the real download, gets ready, then measures. */
function fakeDownload(id: string, from = 0) {
  let fraction = from
  const timer = setInterval(() => {
    fraction += 0.04
    entry(id).state = fraction >= 1 ? { kind: 'preparing' } : { kind: 'downloading', fraction }
    emit('local:changed')
    if (fraction < 1) return
    clearInterval(timer)
    timers.delete(id)
    setTimeout(() => { entry(id).state = { kind: 'ready' }; fakeMeasure(id) }, 1500)
  }, query.has('slow') ? 60_000 : 400)
  timers.set(id, timer)
}
for (const [id, { state }] of Object.entries(local)) if (state.kind === 'downloading') fakeDownload(id, state.fraction)
// The one being measured finishes after a while, unless a picture is taken of it.
if (!query.has('slow')) setTimeout(() => { Object.assign(entry('sherpa/moonshine-base'), { measuring: false, speed: measured(0.2) }); emit('local:changed') }, 6000)

const listeners: Record<string, ((value: unknown) => void)[]> = {}
const emit = (channel: string, value?: unknown) => (listeners[channel] ?? []).forEach(listener => listener(value))
// What the page asked for, for a test to read: window.__calls.
const calls: unknown[][] = []
;(window as unknown as { __calls: unknown[][] }).__calls = calls
// The app asks before deleting; here the question is noted and answered yes.
window.confirm = (message?: string) => { calls.push(['confirm', message]); return true }

;(window as unknown as { satz: unknown }).satz = {
  send() {},
  on(channel: string, listener: (value: unknown) => void) { (listeners[channel] ??= []).push(listener) },
  async invoke(channel: string, ...args: unknown[]) {
    calls.push([channel, ...args])
    switch (channel) {
      case 'settings:get': {
        // The provider the page shows; dictations go to prefs.provider.
        const opened = query.get('show')
        const shown = isProvider(args[0]) ? args[0] : isProvider(opened) ? opened : prefs.provider
        return { prefs, shown, hasKey: keys[shown], keyboard: 'right Ctrl twice', wayland: false, platform: 'win32', history, startAtLogin: true,
          spokenLanguage: prefs.spokenLanguage ?? prefs.language, models: shipped[shown],
          local: { inUse: localModel(), models: localModelIds(localModel()).map(id => ({ id, ...entry(id) })), germanErrors: germanErrors(), machine, version } }
      }
      case 'local:download': entry(args[0] as string).state = { kind: 'downloading', fraction: 0 }; fakeDownload(args[0] as string); return
      case 'local:cancel': clearInterval(timers.get(args[0] as string)); timers.delete(args[0] as string); entry(args[0] as string).state = { kind: 'missing' }; emit('local:changed'); return
      case 'local:measure': fakeMeasure(args[0] as string); return
      case 'local:remove': entry(args[0] as string).state = { kind: 'missing' }; return
      case 'settings:update': Object.assign(prefs, args[0]); return prefs
      case 'settings:store-key': { const provider = args[1] === undefined ? prefs.provider : args[1]; if (!isProvider(provider) || provider === 'local') return false; keys[provider] = true; return true }
      case 'settings:clear-history': history = []; emit('history:changed'); return
      case 'settings:start-at-login': return args[0]
      case 'history:get': return { entries: history, limit: prefs.historyLimit, language: prefs.language }
      case 'history:remove': history = history.filter(entry => entry.id !== args[0]); emit('history:changed'); return
      case 'history:copy': return
      case 'history:set-limit': prefs.historyLimit = args[0] as number; history = prefs.historyLimit === 0 ? [] : history.slice(0, prefs.historyLimit); emit('history:changed'); return
      case 'history:open-settings': emit('window:page', 'settings'); return
      case 'history:open': emit('window:page', 'history'); return
      default: return undefined
    }
  },
}
