import fs from 'node:fs'
import path from 'node:path'

/** Where a local model stands, as the settings and the card show it. */
export type LocalState =
  | { kind: 'missing' }
  | { kind: 'downloading'; fraction: number }
  /** Downloaded, while ONNX Runtime builds the model for this computer. */
  | { kind: 'preparing' }
  | { kind: 'ready' }
  | { kind: 'failed'; message: string }

/** Written only once everything has arrived: an interrupted download leaves files that look like a model and are not. */
export const markerPath = (dir: string, id: string) => path.join(dir, `${id.replace(/\//g, '--')}.ready`)

/** The files the model loads (encoder at 8 bits, decoder at 4), as transformers.js names them. */
const modelFiles = ['onnx/encoder_model_quantized.onnx', 'onnx/decoder_model_merged_q4.onnx', 'tokenizer.json']

/**
 * Downloaded and still there. The marker alone said "on this computer" after
 * the folder was cleaned up, and every dictation then failed with "Error".
 */
export function isDownloaded(dir: string, id: string): boolean {
  if (!fs.existsSync(markerPath(dir, id))) return false
  if (modelFiles.every(file => fs.existsSync(path.join(dir, id, file)))) return true
  fs.rmSync(markerPath(dir, id), { force: true })
  return false
}
