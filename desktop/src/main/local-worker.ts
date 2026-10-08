import { WhisperEngine } from './whisperEngine'

/**
 * satz's helper process for Whisper (an Electron utilityProcess, started by
 * local.ts). Messages in: download, measure, warmUp, unload, release,
 * transcribe. Messages out: state, log, result, error, done.
 */
// Electron's fetch for the model download: the system proxy and certificate
// store, which Node's fetch ignores.
try {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { net } = require('electron')
  if (net?.fetch) globalThis.fetch = net.fetch.bind(net)
} catch { /* not in Electron: Node's fetch */ }

const port = (process as unknown as { parentPort: { on(event: 'message', listener: (event: { data: any }) => void): void; postMessage(message: unknown): void } }).parentPort
const dir = process.argv[2]
const engine = new WhisperEngine(dir, message => port.postMessage({ type: 'log', message }), (id, state) => port.postMessage({ type: 'state', id, state }))

/** The answer to a request, or its error. */
const answer = <T>(request: number, work: Promise<T>, field: string) => work.then(
  value => port.postMessage({ type: 'result', request, [field]: value }),
  error => port.postMessage({ type: 'error', request, message: String(error?.message ?? error) }))

port.on('message', ({ data }) => {
  switch (data.type) {
    case 'download': engine.download(data.id); break
    case 'warmUp': engine.warmUp(data.id); break
    case 'unload': engine.unload().then(() => port.postMessage({ type: 'done', request: data.request })); break
    case 'release': engine.release(data.id).then(() => port.postMessage({ type: 'done', request: data.request })); break
    case 'measure': void answer(data.request, engine.measure(data.id, Float32Array.from(data.samples), data.vocabulary, data.spoken), 'ms'); break
    case 'transcribe': void answer(data.request, engine.transcribe(Float32Array.from(data.samples), data.id, data.vocabulary, data.spoken), 'text'); break
  }
})
