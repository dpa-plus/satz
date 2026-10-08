import { WhisperEngine } from './whisperEngine'

/**
 * satz's helper process for Whisper (an Electron utilityProcess, started by
 * local.ts). Messages in: download, warmUp, unload, transcribe. Messages out:
 * state, log, result, error, done.
 */
const port = (process as unknown as { parentPort: { on(event: 'message', listener: (event: { data: any }) => void): void; postMessage(message: unknown): void } }).parentPort
const dir = process.argv[2]
const engine = new WhisperEngine(dir, message => port.postMessage({ type: 'log', message }), (id, state) => port.postMessage({ type: 'state', id, state }))

port.on('message', ({ data }) => {
  switch (data.type) {
    case 'download': engine.download(data.id); break
    case 'warmUp': engine.warmUp(data.id); break
    case 'unload': engine.unload().then(() => port.postMessage({ type: 'done', request: data.request })); break
    case 'transcribe':
      engine.transcribe(Float32Array.from(data.samples), data.id, data.vocabulary, data.spoken).then(
        text => port.postMessage({ type: 'result', request: data.request, text }),
        error => port.postMessage({ type: 'error', request: data.request, message: String(error?.message ?? error) }))
      break
  }
})
