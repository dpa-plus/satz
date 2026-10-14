import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { localModel, whisperFiles, type Speed } from '../core/localModels'

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

/** What has to be in a model's folder: Whisper's three files, or every file of a sherpa-onnx model. */
const modelFiles = (id: string) => localModel(id)?.sherpa?.files.map(file => file.name) ?? whisperFiles

/**
 * Downloaded and still there. The marker alone said "on this computer" after
 * the folder was cleaned up, and every dictation then failed with "Error".
 * @param tidy the marker of a model whose files are gone goes too; false
 *   where the folder is not satz's to change (a test copy on the user's models).
 */
export function isDownloaded(dir: string, id: string, tidy = true): boolean {
  if (!fs.existsSync(markerPath(dir, id))) return false
  if (modelFiles(id).every(file => fs.existsSync(path.join(dir, id, file)))) return true
  if (tidy) fs.rmSync(markerPath(dir, id), { force: true })
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

/** A file transformers.js is still writing: `<file>.tmp.<pid of the writer>.<random>`, renamed to `<file>` once complete. */
const tempFile = /\.tmp\.(\d+)\.[0-9a-z]+$/

/** Whether a process with this id is running (one we may not signal still is). */
function isRunning(pid: number): boolean {
  try { process.kill(pid, 0); return true } catch (error) { return (error as NodeJS.ErrnoException).code === 'EPERM' }
}

/**
 * Removes the half files of downloads that stopped when satz did. A new
 * download writes under a new name, so what satz left when it quit or
 * crashed in the middle of a Whisper file (hundreds of MB) stayed beside the
 * model for good. Only those whose writer is gone: a second satz (a test
 * copy sharing the folder) may be downloading into it right now.
 * @returns the paths removed
 */
export function removeStaleTemps(dir: string): string[] {
  let entries: fs.Dirent[]
  try { entries = fs.readdirSync(dir, { recursive: true, withFileTypes: true }) } catch { return [] }
  const removed: string[] = []
  for (const entry of entries) {
    const writer = entry.isFile() ? tempFile.exec(entry.name)?.[1] : undefined
    if (writer === undefined || isRunning(Number(writer))) continue
    const file = path.join(entry.parentPath, entry.name)
    try { fs.rmSync(file, { force: true }); removed.push(file) } catch { /* in use: the next start */ }
  }
  return removed
}
