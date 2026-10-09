import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { localModel, type Speed } from '../core/localModels'

/** Where a local model stands, as the settings and the card show it. */
export type LocalState =
  | { kind: 'missing' }
  | { kind: 'downloading'; fraction: number }
  /** Downloaded, while the model is loaded once to see that it works. */
  | { kind: 'preparing' }
  | { kind: 'ready' }
  | { kind: 'failed'; message: string }

const fileName = (id: string) => id.replace(/\//g, '--')

/** Why a speed test stopped: a dictation was waiting behind it (the helper's error message). */
export const gaveWay = 'gave way to a dictation'

/** Written only once everything has arrived: an interrupted download leaves files that look like a model and are not. */
export const markerPath = (dir: string, id: string) => path.join(dir, `${fileName(id)}.ready`)

/** Beside the marker, not in the model's folder: the number stays when the model goes, so it still helps to choose. */
export const speedPath = (dir: string, id: string) => path.join(dir, `${fileName(id)}.speed.json`)

/**
 * A Hugging Face id, "owner/name": what satz downloads into, and later moves
 * to the Trash, as `dir/<id>`. Anything else (`..`, more slashes) could name
 * a folder outside satz's own.
 */
export const isModelId = (id: unknown): id is string =>
  typeof id === 'string' && /^[\w.-]+\/[\w.-]+$/.test(id) && !id.split('/').some(part => /^\.+$/.test(part))

/** The files a Whisper model loads (encoder at 8 bits, decoder at 4), as transformers.js names them. */
const whisperFiles = ['onnx/encoder_model_quantized.onnx', 'onnx/decoder_model_merged_q4.onnx', 'tokenizer.json']

/** What has to be in a model's folder: Whisper's three files, or every file of a sherpa-onnx model. */
const modelFiles = (id: string) => localModel(id)?.sherpa?.files.map(file => file.name) ?? whisperFiles

/**
 * Downloaded and still there. The marker alone said "on this computer" after
 * the folder was cleaned up, and every dictation then failed with "Error".
 */
export function isDownloaded(dir: string, id: string): boolean {
  if (!fs.existsSync(markerPath(dir, id))) return false
  if (modelFiles(id).every(file => fs.existsSync(path.join(dir, id, file)))) return true
  fs.rmSync(markerPath(dir, id), { force: true })
  return false
}

export function readSpeed(dir: string, id: string): Speed | null {
  try {
    const speed = JSON.parse(fs.readFileSync(speedPath(dir, id), 'utf8')) as Speed
    return speed.secondsPer10 > 0 && Number.isFinite(speed.secondsPer10) ? speed : null
  } catch { return null }
}

export function writeSpeed(dir: string, id: string, speed: Speed) {
  fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(speedPath(dir, id), JSON.stringify(speed, null, 2))
}

/** The processor and its cores: a number measured on another computer is shown with its date. */
export function machineName(): string {
  const cpus = os.cpus()
  return `${cpus[0]?.model.trim() || os.arch()}, ${cpus.length} cores`
}
