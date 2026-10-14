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
// `&model=sherpa/canary-180m` Canary as Local's model (with its "Spoken in"; also
// `sherpa/cohere-transcribe`, with its fourteen languages),
// `?show=microsoft` or `?show=google` start on the new providers (neither has a key),
// `&key=microsoft` gives one provider a key already,
// `&fresh=1` nothing downloaded yet, `&slow=1` holds every state still for a picture,
// `&noshortcut=1` right Ctrl cannot start a dictation (the hint under "Shortcut").
// Cleanup ("Aufräumen"): off, OpenRouter in use for it (with a key, Gemini 3.5
// Flash-Lite measured twice), Ollama answering with two models. `&cleanup=1`
// turns it on, `&level=custom` starts on the own prompt, `&cleanupShow=ollama`
// opens another cleanup provider, `&ollama=down` has Ollama not running,
// `&cleanupKey=0` takes OpenRouter's key away (the line under the switch).
// "Ausprobieren" answers after a second, Custom's tries are thrown out by the guard.
import { germanErrors, localModelIds, type Speed } from '../src/core/localModels'
import { models as shipped } from '../src/core/models'
import { standardReplacements } from '../src/core/replacements'
import type { Provider } from '../src/core/transcriber'
import { isCleanupLevel } from '../src/core/cleanup'
import { cleanupProviders, defaultCleanupProvider, isCleanupProvider, type CleanupProviderId } from '../src/core/cleanupProviders'

const hour = 3600_000
const query = new URLSearchParams(location.search)
const asked = query.get('provider') as Provider | null
const language: 'de' | 'en' = query.get('language') === 'de' ? 'de' : 'en'
const prefs = {
  provider: (asked && asked in shipped ? asked : 'openrouter') as Provider, models: {} as Record<string, string>, customBaseURL: '', microsoftRegion: 'northeurope', microsoftEndpoint: '', words: ['Kubernetes', 'Lena'], triggerMode: 'tap',
  language, spokenLanguage: null as 'de' | 'en' | null, toldLanguage: null as string | null, replacements: standardReplacements(language), usesReplacements: true,
  removesFillers: true, keepsOnClipboard: false, historyLimit: 50, pausesMedia: true,
  cleansText: query.has('cleanup'), cleanupLevel: isCleanupLevel(query.get('level')) ? query.get('level')! : 'light',
  cleanupPrompt: '', cleanupProvider: null as CleanupProviderId | null,
  cleanupModels: {} as Record<string, string>, cleanupAddresses: {} as Record<string, string>,
}
let history = [
  { id: 'a', text: 'Thanks for the update. Thursday at two works for me, and I will bring the slides.', date: new Date(Date.now() - 0.1 * hour).toISOString(), pasted: true },
  { id: 'b', text: 'Write a function that reads every invoice in the Accounting folder and adds up the totals per customer.', date: new Date(Date.now() - 1 * hour).toISOString(), pasted: true,
    original: 'um write a function that reads every invoice in the accounting folder and uh adds up the totals per customer', cleanup: 'ok' },
  { id: 'b2', text: 'ähm das deployment ist durch', date: new Date(Date.now() - 2 * hour).toISOString(), pasted: true, cleanup: language === 'de' ? 'Zu langsam' : 'Too slow' },
  { id: 'c', text: 'Bitte schick mir die Unterlagen bis Freitag.', date: new Date(Date.now() - 3 * hour).toISOString(), pasted: false },
  { id: 'd', text: "The test is red, please don't merge yet.", date: new Date(Date.now() - 26 * hour).toISOString(), pasted: true },
]
const keys: Record<Provider, boolean> = { openrouter: true, openai: false, groq: false, microsoft: false, google: false, custom: false, local: false }
for (const name of (query.get('key') ?? '').split(',')) if (name in keys) keys[name as Provider] = true
const isProvider = (value: unknown): value is Provider => typeof value === 'string' && value in shipped

// Cleanup's keys by account, measured runs, and what Ollama and LM Studio have.
const cleanupKeys: Record<string, boolean> = { openrouter: query.get('cleanupKey') !== '0' }
const runs = (seconds: number[]) => seconds.map(value => ({ seconds: value, date: new Date().toISOString() }))
const cleanupSamples: Record<string, Record<string, { seconds: number; date: string }[]>> = { openrouter: { 'google/gemini-3.5-flash-lite': runs([0.7, 0.9]) } }
const installed = (provider: CleanupProviderId) => provider === 'ollama'
  ? (query.get('ollama') === 'down' ? { state: 'down', models: [] } : { state: 'ok', models: ['qwen3.8:8b', 'gemma4:4b'] })
  : provider === 'lmstudio' ? { state: 'ok', models: ['qwen3.8-27b'] } : null
const cleanupInUse = () => prefs.cleanupProvider ?? defaultCleanupProvider(prefs.provider)
const cleanupHasKey = (provider: CleanupProviderId) => { const account = cleanupProviders[provider].account; return account ? cleanupKeys[account] === true : false }
let tryTimer: ReturnType<typeof setTimeout> | null = null
let tryDone: ((value: unknown) => void) | null = null
/** What a try answers here: the sample tidied, or the text with a capital and a full stop. */
function fakeTry(text: string, provider: CleanupProviderId) {
  if (cleanupProviders[provider].account && !cleanupProviders[provider].keyOptional && !cleanupHasKey(provider)) return { outcome: language === 'de' ? 'Schlüssel fehlt' : 'No key', rejected: false }
  const tidy = text.startsWith('ähm also') ? 'Ich wollte fragen, ob wir das Meeting am Dienstag machen können, und kannst du mir sagen, wer noch kommt?'
    : text.startsWith('um so') ? 'I wanted to ask if we can move the meeting to Tuesday, and can you tell me who else is coming?'
    : `${text.charAt(0).toUpperCase()}${text.slice(1).trim()}.`
  if (provider === 'custom') return { outcome: language === 'de' ? 'Antwort verworfen' : 'Answer rejected', answer: 'Sure! Here is the cleaned text you asked for.', rejected: true, seconds: 2.4 }
  const seconds = provider === 'ollama' ? 3.1 : 0.8
  return { outcome: 'ok', answer: tidy, rejected: false, seconds, ...(provider === 'ollama' ? {} : { dollars: 0.00036 }) }
}

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
  'sherpa/cohere-transcribe': { state: { kind: query.get('model') === 'sherpa/cohere-transcribe' ? 'ready' : 'missing' }, measuring: false, speed: measured(2.4) },
  'onnx-community/whisper-large-v3-ONNX': { state: { kind: 'downloading', fraction: 0.42 }, measuring: false, speed: null },
  'onnx-community/whisper-base': { state: query.has('failed') ? { kind: 'failed', message: 'fetch failed' } : { kind: 'missing' }, measuring: false, speed: null },
}
if (query.get('model')) prefs.models.local = query.get('model')!
if (query.has('fresh')) for (const key of Object.keys(local)) delete local[key]
/** Seconds per 10 s, about as an Intel laptop would measure them. */
const fakeSpeeds: [string, number][] = [['cohere', 2.4], ['qwen3', 0.9], ['canary-1b', 1.3], ['german', 0.35], ['large-v3-ONNX', 5.4], ['medium', 2.3], ['base', 0.5], ['tiny', 0.3], ['distil', 2], ['moonshine', 0.2], ['parakeet', 0.4], ['sense', 0.15]]
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
        const inUse = cleanupInUse()
        const cleanupShown = isCleanupProvider(args[1]) ? args[1] : isCleanupProvider(query.get('cleanupShow')) ? query.get('cleanupShow') as CleanupProviderId : inUse
        const cleanup = { inUse, shown: cleanupShown, hasKey: cleanupHasKey(cleanupShown), inUseHasKey: cleanupHasKey(inUse),
          prices: {}, samples: cleanupSamples[cleanupShown] ?? {}, installed: installed(cleanupShown), inUseInstalled: installed(inUse) }
        return { cleanup, prefs, shown, hasKey: keys[shown], keyboard: 'right Ctrl twice', shortcutWorks: !query.has('noshortcut'), wayland: false, platform: 'win32', history, startAtLogin: true,
          spokenLanguage: prefs.spokenLanguage ?? prefs.language, models: shipped[shown],
          local: { inUse: localModel(), models: localModelIds(localModel()).map(id => ({ id, ...entry(id) })), germanErrors: germanErrors(), machine, version } }
      }
      case 'local:download': entry(args[0] as string).state = { kind: 'downloading', fraction: 0 }; fakeDownload(args[0] as string); return
      case 'local:cancel': clearInterval(timers.get(args[0] as string)); timers.delete(args[0] as string); entry(args[0] as string).state = { kind: 'missing' }; emit('local:changed'); return
      case 'local:measure': fakeMeasure(args[0] as string); return
      case 'local:remove': entry(args[0] as string).state = { kind: 'missing' }; return
      case 'settings:update': Object.assign(prefs, args[0]); return prefs
      case 'settings:open-key-page': return isProvider(args[0]) && (args[0] === 'microsoft' || args[0] === 'google')
      case 'settings:store-key': { const provider = args[1] === undefined ? prefs.provider : args[1]; if (!isProvider(provider) || provider === 'local') return false; keys[provider] = true; return true }
      case 'cleanup:store-key': { if (!isCleanupProvider(args[1])) return false; const account = cleanupProviders[args[1]].account; if (!account) return false; cleanupKeys[account] = true; return true }
      case 'cleanup:open-key-page': return isCleanupProvider(args[0]) && cleanupProviders[args[0]].keyPage !== undefined
      case 'cleanup:try': {
        if (typeof args[0] !== 'string' || !isCleanupProvider(args[1])) return null
        const answer = fakeTry(args[0], args[1])
        return new Promise(resolve => { tryDone = resolve; tryTimer = setTimeout(() => { tryDone = null; resolve(answer) }, query.has('slow') ? 60_000 : 1000) })
      }
      case 'cleanup:cancel-try': if (tryTimer) clearTimeout(tryTimer); tryDone?.({ outcome: 'ok', rejected: false, cancelled: true }); tryDone = null; return
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
