import type { LocalState } from './localFiles'
import type { LocalEngine } from './localEngine'

/**
 * The message loop of satz's helper processes for local models (Electron
 * utilityProcesses, started by local.ts): one for Whisper (local-worker.ts),
 * one for sherpa-onnx (sherpa-worker.ts). Messages in: download, cancel,
 * measure, warmUp, unload, release, transcribe, dictationElsewhere. Messages
 * out: state, log, result, error, done.
 */
/** What a helper process hears from satz and answers on: Electron's parentPort, a stand-in in the tests. */
/* eslint-disable @typescript-eslint/no-explicit-any -- messages are plain objects */
export interface Port { on(event: 'message', listener: (event: { data: any }) => void): void; postMessage(message: unknown): void }

export function serve(make: (dir: string, log: (message: string) => void, setState: (id: string, state: LocalState) => void) => LocalEngine<unknown>,
  port: Port = (process as unknown as { parentPort: Port }).parentPort, dir = process.argv[2]) {
  // Electron's fetch for the model download: the system proxy and certificate
  // store, which Node's fetch ignores.
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { net } = require('electron')
    if (net?.fetch) globalThis.fetch = net.fetch.bind(net)
  } catch { /* not in Electron: Node's fetch */ }

  const engine = make(dir, message => port.postMessage({ type: 'log', message }), (id, state) => port.postMessage({ type: 'state', id, state }))

  /** The answer to a request, or its error. */
  const answer = <T>(request: number, work: Promise<T>, field: string) => work.then(
    value => port.postMessage({ type: 'result', request, [field]: value }),
    error => port.postMessage({ type: 'error', request, message: String(error?.message ?? error) }))

  port.on('message', ({ data }) => {
    switch (data.type) {
      case 'download': engine.download(data.id); break
      case 'cancel': engine.cancel(data.id); break
      case 'warmUp': engine.warmUp(data.id); break
      case 'dictationElsewhere': engine.dictationElsewhere(); break
      case 'unload': engine.unload().then(() => port.postMessage({ type: 'done', request: data.request })); break
      case 'release': engine.release(data.id).then(() => port.postMessage({ type: 'done', request: data.request })); break
      case 'measure': void answer(data.request, engine.measure(data.id, Float32Array.from(data.samples), data.vocabulary, data.spoken, data.told), 'ms'); break
      case 'transcribe': void answer(data.request, engine.transcribe(Float32Array.from(data.samples), data.id, data.vocabulary, data.spoken, data.told), 'text'); break
    }
  })
}
