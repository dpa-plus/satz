// Stands in for satz's main process, so the window's pages run in a plain
// browser: settings, history and the model menu with sample data. Changes
// stay in this page. Built by `node build.mjs --preview`; see preview/index.html.
import { downloadSize, models as shipped } from '../src/core/models'
import { standardReplacements } from '../src/core/replacements'
import type { Provider } from '../src/core/transcriber'

const hour = 3600_000
const prefs = {
  provider: 'openrouter' as Provider, models: {} as Record<string, string>, customBaseURL: '', words: ['Kubernetes', 'Lena'], triggerMode: 'tap',
  language: 'en' as 'de' | 'en', spokenLanguage: null as 'de' | 'en' | null, replacements: standardReplacements('en'), usesReplacements: true,
  removesFillers: true, keepsOnClipboard: false, historyLimit: 50, pausesMedia: true,
}
let history = [
  { id: 'a', text: 'Thanks for the update. Thursday at two works for me, and I will bring the slides.', date: new Date(Date.now() - 0.1 * hour).toISOString(), pasted: true },
  { id: 'b', text: 'Write a function that reads every invoice in the Accounting folder and adds up the totals per customer.', date: new Date(Date.now() - 1 * hour).toISOString(), pasted: true },
  { id: 'c', text: 'Bitte schick mir die Unterlagen bis Freitag.', date: new Date(Date.now() - 3 * hour).toISOString(), pasted: false },
  { id: 'd', text: "The test is red, please don't merge yet.", date: new Date(Date.now() - 26 * hour).toISOString(), pasted: true },
]
let hasKey = true
// The local model: missing until "Download", which counts up like the real one.
let localState: { kind: string; fraction?: number } = { kind: 'missing' }
const localModel = () => prefs.models.local || 'onnx-community/whisper-large-v3-turbo'
function fakeDownload() {
  let fraction = 0
  const timer = setInterval(() => {
    fraction += 0.1
    localState = fraction >= 1 ? { kind: 'ready' } : { kind: 'downloading', fraction }
    emit('local:changed')
    if (fraction >= 1) clearInterval(timer)
  }, 300)
}
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
      case 'settings:get':
        return { prefs, hasKey, keyboard: 'right Ctrl twice', wayland: false, platform: 'win32', history, startAtLogin: true,
          spokenLanguage: prefs.spokenLanguage ?? prefs.language, models: shipped[prefs.provider],
          local: { state: localState, size: downloadSize[localModel()] ?? null } }
      case 'local:download': localState = { kind: 'downloading', fraction: 0 }; fakeDownload(); return
      case 'local:remove': localState = { kind: 'missing' }; return
      case 'settings:update': Object.assign(prefs, args[0]); return prefs
      case 'settings:store-key': hasKey = true; return true
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
